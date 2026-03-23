#!/bin/bash
# FlowMind Post-Read Tracker
# After every Read tool use, logs the file into session_reads.
# session_reads  = "opened this session" (shallow)
# analyzed_files = "deeply understood by a FlowMind subagent" (written by kg-update.sh, not this hook)
#
# Ownership: this hook is the ONLY writer of session_reads.
# All semantic analysis (files/folders/flows/analyzed_files) is written by kg-update.sh.
# Removed: unsafe write-coalescing that discarded reads from memory on exit.
# Added:   fcntl file locking to prevent lost-update races with kg-init.sh / kg-update.sh.

set -euo pipefail

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
KG_FILE="$PROJECT_ROOT/.claude/flowmind-knowledge-graph.json"
KG_LOCK="$PROJECT_ROOT/.claude/flowmind-kg.lock"

# Extract file path from tool input — raw string only
RAW_FILE_PATH=$(echo "${CLAUDE_TOOL_INPUT:-}" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    val = d.get('file_path', '')
    print(str(val) if val is not None else '')
except Exception:
    print('')
" 2>/dev/null || echo "")

if [ -z "$RAW_FILE_PATH" ]; then
  exit 0
fi

if [ ! -f "$KG_FILE" ]; then
  exit 0
fi

CURRENT_COMMIT=$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

KG_FILE="$KG_FILE" \
KG_LOCK="$KG_LOCK" \
RAW_FILE_PATH="$RAW_FILE_PATH" \
PROJECT_ROOT="$PROJECT_ROOT" \
TIMESTAMP="$TIMESTAMP" \
CURRENT_COMMIT="$CURRENT_COMMIT" \
python3 << 'PYEOF'
import json, os, sys, tempfile, fcntl

kg_file      = os.environ["KG_FILE"]
kg_lock      = os.environ["KG_LOCK"]
raw_path     = os.environ["RAW_FILE_PATH"]
project_root = os.environ["PROJECT_ROOT"]
timestamp    = os.environ["TIMESTAMP"]
commit       = os.environ["CURRENT_COMMIT"]

# Normalize to repo-relative canonical path
try:
    if os.path.isabs(raw_path) and project_root:
        file_path = os.path.relpath(raw_path, project_root)
    else:
        file_path = raw_path
    file_path = os.path.normpath(file_path)
except Exception:
    file_path = raw_path

def validate_kg(kg):
    """Minimal schema check before writing."""
    assert isinstance(kg.get("session_reads"), list),      "session_reads must be a list"
    assert isinstance(kg.get("analyzed_files"), dict),     "analyzed_files must be a dict"
    assert isinstance(kg.get("folders"), dict),            "folders must be a dict"
    assert isinstance(kg.get("files"), dict),              "files must be a dict"
    assert isinstance(kg.get("flows"), dict),              "flows must be a dict"
    assert isinstance(kg.get("dependency_edges"), list),   "dependency_edges must be a list"

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

# Acquire exclusive lock before read-modify-write
lock_fd = open(kg_lock, "w")
try:
    fcntl.flock(lock_fd, fcntl.LOCK_EX)

    try:
        with open(kg_file) as f:
            kg = json.load(f)
    except Exception as e:
        print(f"FlowMind WARNING: Could not read KG: {e}", file=sys.stderr)
        sys.exit(0)

    reads = kg.setdefault("session_reads", [])

    # Check for staleness even if already tracked
    already = any(r.get("path") == file_path for r in reads)
    analyzed = kg.get("analyzed_files", {})
    if file_path in analyzed:
        analyzed_commit = analyzed[file_path].get("commit", "unknown")
        if analyzed_commit != commit and analyzed_commit != "unknown" and commit != "unknown":
            print(f"⚠️  FlowMind STALE: '{file_path}' analyzed at {analyzed_commit}, repo now at {commit}.")
            print(f"   Re-analyze if this file is critical to your task.")

    if already:
        sys.exit(0)

    # Always write — no coalescing that discards reads
    reads.append({
        "path": file_path,
        "read_at": timestamp,
        "commit": commit,
        "depth": "opened"
    })

    # Cap at 500 entries
    if len(reads) > 500:
        reads = reads[-500:]

    kg["session_reads"] = reads
    kg["last_updated"] = timestamp

    try:
        validate_kg(kg)
    except AssertionError as e:
        print(f"FlowMind WARNING: KG validation failed, skipping write: {e}", file=sys.stderr)
        sys.exit(0)

    try:
        atomic_write(kg_file, kg)
    except Exception as e:
        print(f"FlowMind WARNING: KG write failed for '{file_path}': {e}", file=sys.stderr)

finally:
    fcntl.flock(lock_fd, fcntl.LOCK_UN)
    lock_fd.close()
PYEOF

exit 0
