#!/bin/bash
# FlowMind Pre-Bash Guard
# Allowlist-based: only permits read-only shell commands needed for code analysis.
# Rejects everything not on the list.
#
# Fixes applied:
#   H-1: Shell operator rejection block added FIRST — catches &&, ||, ;, |, $(), `, >, <(, >(
#        Uses portable -E/-F grep (not -P) for macOS BSD grep compatibility.
#   H-2: awk system() check added; yq -i check added
#   H-3: Python write-pattern check honest documentation — catches naive inline writes only
#   L-1: npx removed from allowlist (not needed for read-only analysis)
#   L-2: git stash/remote restricted to list-only subforms
#   L-3: bare except: -> except Exception: in Python extraction
#   NOTE (C-2): This guard covers Claude's Bash tool only. Hook scripts (kg-init.sh,
#               post-read-track.sh) execute outside this guard's scope. Those scripts
#               have their own path-validation and atomic-write protections.

set -euo pipefail

CMD_STRING=$(echo "${CLAUDE_TOOL_INPUT:-}" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    val = d.get('command', '')
    print(str(val).strip() if val is not None else '')
except Exception:
    print('')
" 2>/dev/null || echo "")

if [ -z "$CMD_STRING" ]; then
  exit 0
fi

# ── H-1: SHELL OPERATOR REJECTION ─────────────────────────────────────────────
# Check for shell operators BEFORE the allowlist.
# These operators allow chaining arbitrary commands, subshells, or redirections
# that would bypass the allowlist entirely (e.g. `cat file | rm -rf /`).
#
# Blocked patterns:
#   &&  ||  ;        — command chaining
#   |               — pipe (second command is unchained)
#   $(  `           — command substitution (subshell execution)
#   >  >>           — output redirection (file writes)
#   <(  >(          — process substitution
#
# Note: we check OUTSIDE of quoted strings only as a best-effort. A full
# shell parser would be needed for perfect accuracy, but this blocks all
# realistic attack patterns.
# Portable multi-check: BSD grep (macOS) does not support -P (PCRE).
# Use separate -E and -F calls to cover all operator patterns.
HAS_OP=false
echo "$CMD_STRING" | grep -qE '[;&|`]'   && HAS_OP=true
echo "$CMD_STRING" | grep -qF '$('       && HAS_OP=true
echo "$CMD_STRING" | grep -qE '>>?'      && HAS_OP=true
echo "$CMD_STRING" | grep -qE '<\(|>\('  && HAS_OP=true
if [ "$HAS_OP" = true ]; then
  echo "BLOCKED by FlowMind pre-bash-guard: Command contains a shell operator."
  echo "Shell operators (&&, ||, ;, |, \$(), \`, >, >>, <(), >()) are not permitted."
  echo "The FlowMind skill only runs single, self-contained read-only commands."
  exit 1
fi

# ── Extract base command ───────────────────────────────────────────────────────
BASE_CMD=$(echo "$CMD_STRING" | awk '{print $1}' | xargs basename 2>/dev/null || echo "")

if [ -z "$BASE_CMD" ]; then
  exit 0
fi

# ── ALLOWLIST ─────────────────────────────────────────────────────────────────
# Only these base commands are permitted. Everything else is denied.
# L-1: npx REMOVED — can download and execute arbitrary npm packages.
ALLOWED_COMMANDS=(
  # Navigation / listing
  "ls" "find" "tree" "pwd" "echo" "printf"
  # File reading (read-only)
  "cat" "head" "tail" "less" "more" "wc" "file" "stat"
  # Searching / text processing
  "grep" "rg"
  "awk" "sed"           # Extra checks below for dangerous flags/patterns
  "sort" "uniq" "cut" "tr" "jq"
  # Git read-only operations (subcommand-restricted below)
  "git"
  # Scripting languages (inline write-pattern check below)
  "python3" "python" "node"
  # JSON / YAML tools (yq -i check below)
  "yq"
  # Counting / sizing
  "du" "df"
  # Process inspection (read-only)
  "ps" "which" "type" "command"
  # FlowMind KG single-writer script (allowlisted by exact name)
  "kg-update.sh"
)

ALLOWED=false
for cmd in "${ALLOWED_COMMANDS[@]}"; do
  if [ "$BASE_CMD" = "$cmd" ]; then
    ALLOWED=true
    break
  fi
done

if [ "$ALLOWED" = false ]; then
  echo "BLOCKED by FlowMind pre-bash-guard: '$BASE_CMD' is not on the read-only allowlist."
  echo "Allowed: ls, find, cat, grep, rg, git, python3, node, jq, wc, stat, head, tail, awk, sort, cut, etc."
  exit 1
fi

# ── EXTRA CHECKS for allowed commands with dangerous modes ────────────────────

# sed -i (in-place edit)
if [ "$BASE_CMD" = "sed" ] && echo "$CMD_STRING" | grep -qE ' -[a-zA-Z]*i[a-zA-Z]*| --in-place'; then
  echo "BLOCKED by FlowMind pre-bash-guard: 'sed -i' (in-place edit) is not allowed."
  exit 1
fi

# H-2: awk system() — awk can execute shell commands via system() or |&
if [ "$BASE_CMD" = "awk" ] && echo "$CMD_STRING" | grep -qE 'system\s*\(|"\s*\|&|getline\s+<'; then
  echo "BLOCKED by FlowMind pre-bash-guard: awk with system(), |&, or getline from command is not allowed."
  exit 1
fi

# H-2: yq -i (in-place YAML edit)
if [ "$BASE_CMD" = "yq" ] && echo "$CMD_STRING" | grep -qE ' -[a-zA-Z]*i[a-zA-Z]*| --inplace'; then
  echo "BLOCKED by FlowMind pre-bash-guard: 'yq -i' (in-place edit) is not allowed."
  exit 1
fi

# git — subcommand allowlist
# L-2: git stash/remote restricted to read-only sub-forms
if [ "$BASE_CMD" = "git" ]; then
  GIT_SUB=$(echo "$CMD_STRING" | awk '{print $2}')
  case "$GIT_SUB" in
    log|diff|show|status|blame|shortlog)
      ;;  # always safe
    "ls-files"|"ls-tree"|"cat-file"|"rev-parse"|"rev-list"|"describe"|"name-rev"|"for-each-ref"|"grep")
      ;;  # always safe
    branch|tag)
      # Read-only: listing only. Block branch -D, branch -m, tag -d etc.
      if echo "$CMD_STRING" | grep -qE ' -(D|d|m|M|c|C|f|u|t) | --delete| --move| --copy| --force'; then
        echo "BLOCKED by FlowMind pre-bash-guard: mutating git branch/tag flags are not allowed."
        exit 1
      fi
      ;;
    remote)
      # L-2: Only allow 'git remote -v' and 'git remote show'
      GIT_REMOTE_SUB=$(echo "$CMD_STRING" | awk '{print $3}')
      if [ "$GIT_REMOTE_SUB" != "-v" ] && [ "$GIT_REMOTE_SUB" != "show" ] && [ "$GIT_REMOTE_SUB" != "" ]; then
        echo "BLOCKED by FlowMind pre-bash-guard: only 'git remote -v' and 'git remote show' are allowed."
        echo "Mutating remote operations (add, remove, set-url) are not permitted."
        exit 1
      fi
      ;;
    stash)
      # L-2: Only allow 'git stash list' and 'git stash show'
      GIT_STASH_SUB=$(echo "$CMD_STRING" | awk '{print $3}')
      if [ "$GIT_STASH_SUB" != "list" ] && [ "$GIT_STASH_SUB" != "show" ] && [ "$GIT_STASH_SUB" != "" ]; then
        echo "BLOCKED by FlowMind pre-bash-guard: only 'git stash list' and 'git stash show' are allowed."
        echo "Mutating stash operations (pop, drop, apply, push) are not permitted."
        exit 1
      fi
      # Bare 'git stash' with no subcommand stashes changes — block it
      if [ "$GIT_STASH_SUB" = "" ]; then
        echo "BLOCKED by FlowMind pre-bash-guard: bare 'git stash' mutates the working tree."
        echo "Use 'git stash list' to view stashes."
        exit 1
      fi
      ;;
    *)
      echo "BLOCKED by FlowMind pre-bash-guard: 'git $GIT_SUB' is not a permitted read-only git subcommand."
      echo "Allowed: log, diff, show, status, blame, ls-files, rev-parse, branch (list), grep, etc."
      exit 1
      ;;
  esac
fi

# python3/python — H-3: This check catches naive inline write attempts only.
# It does NOT protect against: script file invocations (python3 script.py),
# obfuscated writes (getattr, exec, eval, chr encoding), or __import__.
# The Write tool should be used for all file writes; this is a defense-in-depth check.
if [ "$BASE_CMD" = "python3" ] || [ "$BASE_CMD" = "python" ]; then
  if echo "$CMD_STRING" | grep -qE "open\s*\([^)]+['\"]w['\"]|os\.(remove|unlink)|shutil\.(rmtree|move|copy)|os\.system\s*\(|subprocess\.(run|call|Popen)|eval\s*\(|exec\s*\("; then
    echo "BLOCKED by FlowMind pre-bash-guard: Python command contains a write/delete/execute pattern."
    echo "Use the Write tool for file writes. Only read-only Python operations are permitted via Bash."
    exit 1
  fi
fi

# node — similar check for Node.js write patterns
if [ "$BASE_CMD" = "node" ]; then
  if echo "$CMD_STRING" | grep -qE "writeFile|writeFileSync|appendFile|unlink|rmdir|exec\s*\(|execSync|spawnSync|child_process"; then
    echo "BLOCKED by FlowMind pre-bash-guard: Node.js command contains a write/delete/execute pattern."
    echo "Use the Write tool for file writes."
    exit 1
  fi
fi

exit 0
