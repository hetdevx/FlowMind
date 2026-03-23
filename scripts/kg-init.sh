#!/bin/bash
# FlowMind Knowledge Graph Initializer
# Runs on SessionStart. Creates or loads the KG, checks staleness, resets session_reads.
# Uses file locking to coordinate with post-read-track.sh and kg-update.sh.
# Corrupt KG: first Python block exits 1 on parse failure; bash skips the update block.

set -euo pipefail

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"

if [ -z "$PROJECT_ROOT" ] || [ ! -d "$PROJECT_ROOT" ]; then
  echo "FlowMind ERROR: PROJECT_ROOT is not a valid directory: '$PROJECT_ROOT'" >&2
  exit 1
fi

KG_DIR="$PROJECT_ROOT/.claude"
KG_FILE="$KG_DIR/flowmind-knowledge-graph.json"
KG_LOCK="$KG_DIR/flowmind-kg.lock"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

mkdir -p "$KG_DIR"

IS_GIT_REPO=false
CURRENT_BRANCH="unknown"
CURRENT_COMMIT="unknown"

if git -C "$PROJECT_ROOT" rev-parse --git-dir > /dev/null 2>&1; then
  IS_GIT_REPO=true
  CURRENT_BRANCH=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
  CURRENT_COMMIT=$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
fi

if [ "$IS_GIT_REPO" = false ]; then
  echo "FlowMind WARNING: Not a git repository — staleness detection DISABLED."
  echo "  Re-run ingestion manually whenever files change."
fi

if [ -f "$KG_FILE" ]; then
  echo "=== FlowMind Knowledge Graph: Loaded ==="

  # Read-only display block — no lock needed, no writes
  KG_FILE="$KG_FILE" \
  CURRENT_BRANCH="$CURRENT_BRANCH" \
  CURRENT_COMMIT="$CURRENT_COMMIT" \
  IS_GIT_REPO="$IS_GIT_REPO" \
  python3 << 'PYEOF'
import json, sys, os

kg_file    = os.environ["KG_FILE"]
cur_branch = os.environ["CURRENT_BRANCH"]
cur_commit = os.environ["CURRENT_COMMIT"]
is_git     = os.environ["IS_GIT_REPO"] == "true"

try:
    with open(kg_file) as f:
        kg = json.load(f)
except Exception as e:
    # Exit 1 so the bash script knows not to attempt the update block
    print(f"FlowMind ERROR: Cannot parse KG: {e}", file=sys.stderr)
    print(f"Delete {kg_file} and restart to create a fresh KG.", file=sys.stderr)
    sys.exit(1)

folders  = list(kg.get("folders", {}).keys())
files_kg = list(kg.get("files", {}).keys())
flows    = list(kg.get("flows", {}).keys())
analyzed = kg.get("analyzed_files", {})
reads    = kg.get("session_reads", [])
last     = kg.get("last_updated", "unknown")
kg_branch = kg.get("git", {}).get("branch", "unknown")
kg_commit = kg.get("git", {}).get("commit", "unknown")

print(f"Last updated : {last}")
print(f"KG branch    : {kg_branch}  |  Current : {cur_branch}")
print(f"KG commit    : {kg_commit}  |  Current : {cur_commit}")
print(f"Folders known: {len(folders)}")
print(f"Files known  : {len(files_kg)} total, {len(analyzed)} deeply analyzed")
print(f"Flows known  : {', '.join(flows) if flows else 'none'}")
print(f"Session reads: {len(reads)} (will be archived + reset)")
print(f"KG file      : {kg_file}")

if not is_git:
    print("\n⚠️  NO GIT: staleness detection disabled.")
else:
    warnings = []
    if kg_branch != cur_branch and kg_branch != "unknown":
        warnings.append(f"BRANCH CHANGED: KG built on '{kg_branch}', now on '{cur_branch}'.")
    elif kg_commit != cur_commit and kg_commit != "unknown":
        warnings.append(f"COMMITS DIFFER: KG at {kg_commit}, now at {cur_commit}.")

    if warnings:
        print("\n⚠️  STALENESS WARNINGS:")
        for w in warnings:
            print(f"   {w}")
        print(f"\nACTION: Re-read files before citing. Run: git diff {kg_commit}..HEAD --name-only")
    else:
        print("\n✓ KG is fresh. Cached data in 'analyzed_files' is trustworthy.")
PYEOF

  # Capture exit code without aborting the script (set -e active)
  PARSE_OK=$?

  # Only update metadata if KG parsed successfully — prevents double-error on corrupt KG
  if [ "$PARSE_OK" -eq 0 ]; then
    KG_FILE="$KG_FILE" \
    KG_LOCK="$KG_LOCK" \
    TIMESTAMP="$TIMESTAMP" \
    CURRENT_BRANCH="$CURRENT_BRANCH" \
    CURRENT_COMMIT="$CURRENT_COMMIT" \
    python3 << 'PYEOF2'
import json, os, sys, tempfile, fcntl

kg_file   = os.environ["KG_FILE"]
kg_lock   = os.environ["KG_LOCK"]
timestamp = os.environ["TIMESTAMP"]
branch    = os.environ["CURRENT_BRANCH"]
commit    = os.environ["CURRENT_COMMIT"]

def validate_kg(kg):
    assert isinstance(kg.get("session_reads"), list)
    assert isinstance(kg.get("analyzed_files"), dict)
    assert isinstance(kg.get("folders"), dict)
    assert isinstance(kg.get("files"), dict)
    assert isinstance(kg.get("flows"), dict)
    assert isinstance(kg.get("dependency_edges"), list)

def atomic_write(kg_file, kg):
    kg_dir = os.path.dirname(kg_file)
    tmp_fd, tmp_path = tempfile.mkstemp(dir=kg_dir, suffix=".tmp")
    try:
        with os.fdopen(tmp_fd, "w") as f:
            json.dump(kg, f, indent=2)
        os.replace(tmp_path, kg_file)
    except Exception:
        try:
            os.unlink(tmp_path)
        except Exception:
            pass
        raise

lock_fd = open(kg_lock, "w")
try:
    fcntl.flock(lock_fd, fcntl.LOCK_EX)

    try:
        with open(kg_file) as f:
            kg = json.load(f)
    except Exception as e:
        print(f"FlowMind WARNING: KG re-read under lock failed: {e}", file=sys.stderr)
        sys.exit(0)

    # Archive and reset session_reads
    kg["last_session_reads"] = kg.get("session_reads", [])
    kg["session_reads"] = []
    kg["last_session_start"] = timestamp
    kg["git"] = {"branch": branch, "commit": commit}

    try:
        validate_kg(kg)
        atomic_write(kg_file, kg)
        print("✓ KG updated: session_reads reset, git metadata refreshed.")
    except (AssertionError, Exception) as e:
        print(f"FlowMind WARNING: KG update failed: {e}", file=sys.stderr)

finally:
    fcntl.flock(lock_fd, fcntl.LOCK_UN)
    lock_fd.close()
PYEOF2
  else
    echo "FlowMind: Skipping metadata update — KG is corrupt. Fix or delete the file above." >&2
  fi

else
  # First time — create fresh KG
  KG_FILE="$KG_FILE" \
  KG_DIR="$KG_DIR" \
  KG_LOCK="$KG_LOCK" \
  TIMESTAMP="$TIMESTAMP" \
  CURRENT_BRANCH="$CURRENT_BRANCH" \
  CURRENT_COMMIT="$CURRENT_COMMIT" \
  PROJECT_ROOT="$PROJECT_ROOT" \
  python3 << 'PYEOF3'
import json, os, sys, tempfile, fcntl

kg_file      = os.environ["KG_FILE"]
kg_dir       = os.environ["KG_DIR"]
kg_lock      = os.environ["KG_LOCK"]
timestamp    = os.environ["TIMESTAMP"]
branch       = os.environ["CURRENT_BRANCH"]
commit       = os.environ["CURRENT_COMMIT"]
project_root = os.environ["PROJECT_ROOT"]

kg = {
    "schema_version": "2",
    "created_at": timestamp,
    "last_updated": timestamp,
    "last_session_start": timestamp,
    "repo_root": project_root,
    "git": {"branch": branch, "commit": commit},
    "session_reads": [],
    "last_session_reads": [],
    "analyzed_files": {},
    "folders": {},
    "files": {},
    "flows": {},
    "dependency_edges": []
}

lock_fd = open(kg_lock, "w")
try:
    fcntl.flock(lock_fd, fcntl.LOCK_EX)
    tmp_fd, tmp_path = tempfile.mkstemp(dir=kg_dir, suffix=".tmp")
    try:
        with os.fdopen(tmp_fd, "w") as f:
            json.dump(kg, f, indent=2)
        os.replace(tmp_path, kg_file)
    except Exception:
        try:
            os.unlink(tmp_path)
        except Exception:
            pass
        raise
finally:
    fcntl.flock(lock_fd, fcntl.LOCK_UN)
    lock_fd.close()
PYEOF3

  echo "=== FlowMind Knowledge Graph: Initialized ==="
  echo "Branch  : $CURRENT_BRANCH | Commit: $CURRENT_COMMIT"
  echo "Created : $KG_FILE"
  echo "Run 'understand this codebase' to begin ingestion."
fi

exit 0
