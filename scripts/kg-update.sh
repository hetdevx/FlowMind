#!/bin/bash
# FlowMind Knowledge Graph Updater
# Single writer for semantic KG data: files, folders, flows, analyzed_files, dependency_edges.
# Called by Claude via the Bash tool (never directly by hooks).
# Hooks own: session_reads, last_session_reads, git metadata.
# This script owns: files, folders, flows, analyzed_files, dependency_edges, last_updated.
#
# Usage:
#   kg-update.sh --merge '<json_patch>'
#
# The JSON patch is a partial KG object. Only the following top-level keys are merged:
#   files, folders, flows, analyzed_files, dependency_edges
# All other keys (git, session_reads, etc.) are read-only here and left untouched.
#
# Example:
#   kg-update.sh --merge '{"files": {"src/foo.ts": {"responsibility": "...", ...}}}'
#
# The patch is DEEP-MERGED into the existing KG (dict keys are added/updated, not replaced).
# dependency_edges is appended (not replaced): new edges from the patch are added,
# duplicates (same from+to+type) are deduplicated.

set -euo pipefail

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"

if [ -z "$PROJECT_ROOT" ] || [ ! -d "$PROJECT_ROOT" ]; then
  echo "FlowMind ERROR: PROJECT_ROOT is not a valid directory: '$PROJECT_ROOT'" >&2
  exit 1
fi

KG_FILE="$PROJECT_ROOT/.claude/flowmind-knowledge-graph.json"
KG_LOCK="$PROJECT_ROOT/.claude/flowmind-kg.lock"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

if [ ! -f "$KG_FILE" ]; then
  echo "FlowMind ERROR: KG not found at $KG_FILE" >&2
  echo "Run 'understand this codebase' to initialize the knowledge graph first." >&2
  exit 1
fi

# ── Argument parsing ──────────────────────────────────────────────────────────
PATCH_JSON=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --merge)
      PATCH_JSON="$2"
      shift 2
      ;;
    *)
      echo "FlowMind ERROR: Unknown argument: $1" >&2
      echo "Usage: kg-update.sh --merge '<json_patch>'" >&2
      exit 1
      ;;
  esac
done

if [ -z "$PATCH_JSON" ]; then
  echo "FlowMind ERROR: --merge argument is required." >&2
  echo "Usage: kg-update.sh --merge '<json_patch>'" >&2
  exit 1
fi

# ── Python: validate patch, acquire lock, deep-merge, validate, atomic-write ──
KG_FILE="$KG_FILE" \
KG_LOCK="$KG_LOCK" \
PATCH_JSON="$PATCH_JSON" \
TIMESTAMP="$TIMESTAMP" \
PROJECT_ROOT="$PROJECT_ROOT" \
python3 << 'PYEOF'
import json, os, sys, tempfile, fcntl

kg_file      = os.environ["KG_FILE"]
kg_lock      = os.environ["KG_LOCK"]
patch_raw    = os.environ["PATCH_JSON"]
timestamp    = os.environ["TIMESTAMP"]
project_root = os.environ["PROJECT_ROOT"]

# ── Allowed patch keys (hooks own everything else) ────────────────────────────
ALLOWED_PATCH_KEYS = {"files", "folders", "flows", "analyzed_files", "dependency_edges"}

# ── Validate patch JSON ───────────────────────────────────────────────────────
try:
    patch = json.loads(patch_raw)
except Exception as e:
    print(f"FlowMind ERROR: --merge value is not valid JSON: {e}", file=sys.stderr)
    sys.exit(1)

if not isinstance(patch, dict):
    print("FlowMind ERROR: --merge value must be a JSON object (dict).", file=sys.stderr)
    sys.exit(1)

disallowed = set(patch.keys()) - ALLOWED_PATCH_KEYS
if disallowed:
    print(f"FlowMind ERROR: Patch contains disallowed keys: {sorted(disallowed)}", file=sys.stderr)
    print(f"  Only these keys may be updated: {sorted(ALLOWED_PATCH_KEYS)}", file=sys.stderr)
    sys.exit(1)

# ── Normalize all paths in patch to repo-relative canonical form ──────────────
def normalize_path(raw, project_root):
    """Convert absolute or relative path to repo-relative normalized form."""
    try:
        if os.path.isabs(raw) and project_root:
            rel = os.path.relpath(raw, project_root)
        else:
            rel = raw
        return os.path.normpath(rel)
    except Exception:
        return raw

def normalize_dict_keys(d, project_root):
    """Return a new dict with all keys normalized as repo-relative paths."""
    return {normalize_path(k, project_root): v for k, v in d.items()}

for key in ("files", "folders", "analyzed_files"):
    if key in patch and isinstance(patch[key], dict):
        patch[key] = normalize_dict_keys(patch[key], project_root)

# ── KG validation ─────────────────────────────────────────────────────────────
def validate_kg(kg):
    assert isinstance(kg.get("session_reads"), list),     "session_reads must be a list"
    assert isinstance(kg.get("analyzed_files"), dict),    "analyzed_files must be a dict"
    assert isinstance(kg.get("folders"), dict),           "folders must be a dict"
    assert isinstance(kg.get("files"), dict),             "files must be a dict"
    assert isinstance(kg.get("flows"), dict),             "flows must be a dict"
    assert isinstance(kg.get("dependency_edges"), list),  "dependency_edges must be a list"

# ── Atomic write ──────────────────────────────────────────────────────────────
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

# ── Deep merge helper ─────────────────────────────────────────────────────────
def deep_merge(base, patch):
    """Recursively merge patch into base. Returns mutated base."""
    for k, v in patch.items():
        if k in base and isinstance(base[k], dict) and isinstance(v, dict):
            deep_merge(base[k], v)
        else:
            base[k] = v
    return base

# ── Acquire exclusive lock, read, merge, validate, write ─────────────────────
lock_fd = open(kg_lock, "w")
try:
    fcntl.flock(lock_fd, fcntl.LOCK_EX)

    try:
        with open(kg_file) as f:
            kg = json.load(f)
    except Exception as e:
        print(f"FlowMind ERROR: Cannot read KG under lock: {e}", file=sys.stderr)
        sys.exit(1)

    # Merge allowed keys
    for key in ALLOWED_PATCH_KEYS:
        if key not in patch:
            continue
        if key == "dependency_edges":
            # Append and deduplicate edges
            existing_edges = kg.get("dependency_edges", [])
            new_edges = patch["dependency_edges"]
            if not isinstance(new_edges, list):
                print(f"FlowMind ERROR: dependency_edges patch must be a list.", file=sys.stderr)
                sys.exit(1)
            # Deduplicate on (from, to, type)
            edge_keys = {(e.get("from"), e.get("to"), e.get("type")) for e in existing_edges}
            for edge in new_edges:
                key_t = (edge.get("from"), edge.get("to"), edge.get("type"))
                if key_t not in edge_keys:
                    existing_edges.append(edge)
                    edge_keys.add(key_t)
            kg["dependency_edges"] = existing_edges
        else:
            # Deep merge dict keys
            if key not in kg:
                kg[key] = {}
            deep_merge(kg[key], patch[key])

    kg["last_updated"] = timestamp

    try:
        validate_kg(kg)
    except AssertionError as e:
        print(f"FlowMind ERROR: KG validation failed after merge: {e}", file=sys.stderr)
        sys.exit(1)

    try:
        atomic_write(kg_file, kg)
    except Exception as e:
        print(f"FlowMind ERROR: KG write failed: {e}", file=sys.stderr)
        sys.exit(1)

    # Summary of what was written
    updated_keys = [k for k in patch if k in ALLOWED_PATCH_KEYS]
    counts = {}
    for k in updated_keys:
        v = patch[k]
        if isinstance(v, dict):
            counts[k] = f"{len(v)} entries"
        elif isinstance(v, list):
            counts[k] = f"{len(v)} items"
    summary = ", ".join(f"{k}: {counts[k]}" for k in counts) if counts else "no changes"
    print(f"✓ KG updated: {summary}")

finally:
    fcntl.flock(lock_fd, fcntl.LOCK_UN)
    lock_fd.close()
PYEOF

exit 0
