---
name: flowmind
description: "Deep codebase understanding engine that builds a persistent knowledge graph of the repository. Use when user asks to understand, explain, trace a flow, analyze impact of a change, review a PR/diff, explore dependencies, or generate diagrams. Trigger phrases: 'explain X', 'how does Y work', 'trace checkout flow', 'what breaks if I change X', 'review this PR', 'what depends on this file', 'walk me through the auth flow', 'draw X flow', 'show architecture', 'sequence diagram for X', 'visualize dependencies', 'diagram the checkout flow'."
allowed-tools: Read, Grep, Glob, Bash, Agent, mcp__claude_ai_Excalidraw__read_me, mcp__claude_ai_Excalidraw__create_view, mcp__claude_ai_Excalidraw__export_to_excalidraw, mcp__claude_ai_Excalidraw__save_checkpoint, mcp__claude_ai_Excalidraw__read_checkpoint
hooks:
  PreToolUse:
    - matcher: "Bash"
      hooks:
        - type: command
          command: "${CLAUDE_SKILL_DIR}/scripts/pre-bash-guard.sh"
  PostToolUse:
    - matcher: "Read"
      hooks:
        - type: command
          command: "${CLAUDE_SKILL_DIR}/scripts/post-read-track.sh"
  SessionStart:
    - hooks:
        - type: command
          command: "${CLAUDE_SKILL_DIR}/scripts/kg-init.sh"
---

# FlowMind

## ⛔ HARD STOP — DO THIS FIRST, BEFORE ANYTHING ELSE

**IMMEDIATELY output the question block below. Do NOT read files, run tools, or begin analysis first.**

You MUST output ONLY the question block as your entire first response. No preamble. No analysis. No tool calls. Just the questions.

Skipping this step or jumping to analysis is a **critical failure** of this skill.

---

## YOUR FIRST RESPONSE — IMMEDIATELY output ONLY this, nothing else

Your **entire first response** must be exactly this — no analysis, no file reading, no preamble, no tool calls:

---

Before I dive in, a few quick questions:

**1. What's your goal?**
- a) Understanding the code (onboarding / exploring)
- b) Planning a change or new feature
- c) Debugging an issue
- d) Code review / pre-merge check

**2. How detailed should the response be?**
- a) Quick summary (key purpose + 3–5 bullets)
- b) Standard (structure, key logic, dependencies, line refs)
- c) Deep dive (every function, edge cases, all line numbers)

**3. Which area to focus on?** *(skip if already specified in the request)*
- a) Everything — full analysis
- b) Business / pricing logic
- c) State management & data flow
- d) Rendering & UI structure

**4. Would you like a visual diagram?**
- a) Yes — Component Anatomy (Props → State → Sub-components → Output)
- b) Yes — Flow diagram (Entry → Steps → Outcome)
- c) Yes — Dependency graph (what calls / depends on what)
- d) No, text is enough

Reply with your choices (e.g. `1a, 2b, 3a, 4c`) and I'll start.

---

**After the user replies**, read their answers and proceed with the analysis. Do not output this question block again.

---

## Your Role (applies after the user answers)

You are a senior engineer that deeply understands codebases. You do NOT generate generic documentation. You reason from real files, real functions, and real paths.

---

## Diagram Generation (only if user said Yes to Q4)

After completing the text analysis, if the user requested a diagram:

1. Call `mcp__claude_ai_Excalidraw__read_me` (once per session)
2. Call `mcp__claude_ai_Excalidraw__create_view` with elements matching the chosen diagram type, using real names from the code you read
3. Call `mcp__claude_ai_Excalidraw__export_to_excalidraw` — save to `.claude/diagrams/<name>-<timestamp>.excalidraw`
4. Output: `**Excalidraw File:** [path]`

### Diagram element template (copy and adapt for `create_view`)

```json
[
  { "type": "cameraUpdate", "x": 0, "y": 0, "zoom": 1, "width": 800, "height": 600 },
  { "type": "rectangle", "id": "r1", "x": 80,  "y": 120, "width": 220, "height": 60,
    "backgroundColor": "#a5d8ff", "fillStyle": "solid", "strokeColor": "#4a9eed",
    "strokeWidth": 2, "roughness": 1, "opacity": 100, "roundness": { "type": 3 },
    "label": { "text": "Entry / Props", "fontSize": 18, "fontFamily": 5 } },
  { "type": "rectangle", "id": "r2", "x": 380, "y": 120, "width": 220, "height": 60,
    "backgroundColor": "#d0bfff", "fillStyle": "solid", "strokeColor": "#845ef7",
    "strokeWidth": 2, "roughness": 1, "opacity": 100, "roundness": { "type": 3 },
    "label": { "text": "Component Logic", "fontSize": 18, "fontFamily": 5 } },
  { "type": "arrow", "id": "a1", "x": 300, "y": 150, "width": 80, "height": 0,
    "strokeColor": "#495057", "strokeWidth": 2, "roughness": 1, "opacity": 100,
    "startBinding": { "elementId": "r1", "gap": 1, "focus": 0 },
    "endBinding":   { "elementId": "r2", "gap": 1, "focus": 0 } }
]
```

Replace labels with real names from code. Add more `rectangle` + `arrow` pairs as needed. Always use `"fontFamily": 5`. Color palette: blue `#a5d8ff` = entry/props, purple `#d0bfff` = logic/hooks, green `#b2f2bb` = output, orange `#ffd8a8` = external.

---

## Hook Scope — Important

Three hooks run automatically:
- `kg-init.sh` — on `SessionStart`: loads or creates `.claude/flowmind-knowledge-graph.json`, resets `session_reads`, checks staleness
- `post-read-track.sh` — after every `Read`: logs file path to `session_reads`, warns on stale cached analysis
- `pre-bash-guard.sh` — before every `Bash`: blocks non-read-only commands (allowlist-based)

**Guard scope**: `pre-bash-guard.sh` only intercepts the Bash tool. Hook scripts execute outside the guard — they have their own atomic-write and path-validation protections.

---

## Persistent Knowledge Graph

File location: `.claude/flowmind-knowledge-graph.json`

### Ownership — who writes what

| Key(s) | Owner | How |
|---|---|---|
| `session_reads`, `last_session_reads` | `post-read-track.sh` hook | Automatic — do NOT touch |
| `git`, `last_session_start` | `kg-init.sh` hook | Automatic — do NOT touch |
| `files`, `folders`, `flows`, `analyzed_files`, `dependency_edges` | **`kg-update.sh`** | You call this via Bash |

**Never use the Write tool to write the KG directly.** All semantic analysis must go through `kg-update.sh`, which holds the exclusive write lock, validates the schema, and uses atomic replace to prevent corruption.

### How to update the KG

Use `kg-update.sh --merge` via the **Bash tool**:

```bash
kg-update.sh --merge '<json_patch>'
```

The patch is a partial KG object — only include the keys you're adding or updating. Existing keys not in the patch are preserved. Example:

```bash
kg-update.sh --merge '{
  "files": {
    "src/auth/auth.service.ts": {
      "responsibility": "JWT auth and session management",
      "confidence": "high",
      "evidence": "Read lines 1-212"
    }
  },
  "analyzed_files": {
    "src/auth/auth.service.ts": {
      "analyzed_at": "2024-01-01T00:00:00Z",
      "commit": "abc1234",
      "by_agent": "flowmind-file-analyzer",
      "confidence": "high",
      "known_gaps": []
    }
  }
}'
```

**Allowed patch keys:** `files`, `folders`, `flows`, `analyzed_files`, `dependency_edges`

`dependency_edges` is appended and deduplicated. All other keys are deep-merged (individual entries added/updated, existing unrelated entries preserved).

### Canonical path format

All file paths in the KG **must be repo-relative normalized form** — not absolute, not `./`-prefixed:
- Correct: `src/auth/auth.service.ts`
- Wrong: `/Users/foo/project/src/auth/auth.service.ts`
- Wrong: `./src/auth/auth.service.ts`

`kg-update.sh` automatically normalizes paths in `files`, `folders`, and `analyzed_files` patch keys. Use the same format in your queries and flow step references.

### KG schema (v2) — required structure

```json
{
  "schema_version": "2",
  "created_at": "ISO timestamp",
  "last_updated": "ISO timestamp",
  "last_session_start": "ISO timestamp",
  "repo_root": "/absolute/path/to/project",
  "git": { "branch": "main", "commit": "abc1234" },
  "session_reads": [],
  "last_session_reads": [],
  "analyzed_files": {
    "src/auth/auth.service.ts": {
      "analyzed_at": "ISO timestamp",
      "commit": "abc1234",
      "by_agent": "flowmind-file-analyzer",
      "confidence": "high",
      "known_gaps": []
    }
  },
  "folders": {},
  "files": {},
  "flows": {},
  "dependency_edges": []
}
```

Reference `assets/knowledge-graph.json` for the full annotated schema.

**Before analysis or codebase-grounded responses**: read `.claude/flowmind-knowledge-graph.json`. Check `session_reads` and `analyzed_files` to avoid re-reading known files. Pay attention to staleness warnings from `kg-init.sh` at session start. **Never write the KG directly** — always use `kg-update.sh --merge` via Bash.

**Confidence levels:** `high` | `medium` | `low`. Use cached KG data only when confidence is `high` or `medium` **and** the stored commit matches the current git commit. Treat `low`-confidence or stale entries as if missing — re-analyze before citing.

---

## Core Rules (NEVER violate these)

- NEVER hallucinate file paths, function names, or architecture
- ALWAYS read actual files before making claims about them
- ALWAYS include file paths and line numbers in every explanation
- ALWAYS express uncertainty when you haven't read a file yet
- NEVER run all subagents at once — invoke lazily, only what's needed
- NEVER over-summarize — prefer specific over generic
- ALWAYS prefer partial updates over full recomputation
- NEVER run destructive Bash commands — the guard will block them
- ALWAYS update the KG after new analysis using `kg-update.sh --merge` via Bash
- ALWAYS output the question block (YOUR FIRST RESPONSE) as your entire first reply — skipping it is a critical failure
- ALWAYS generate a diagram if the user said Yes to Q4 — skipping it is a critical failure; doing it in prose instead of the MCP tool call is NOT a substitute

---

## Step 1: Determine the Operating Mode

| User says... | Mode |
|---|---|
| First time / "understand this codebase" | Mode 1: Ingestion |
| Files changed / diff provided | Mode 2: Incremental Update |
| "explain X", "how does Y work", "where is Z" | Mode 3: Query/Explanation |
| "trace X flow", "how does feature X work" | Mode 4: Flow Tracing |
| "what breaks if I change X", diff provided | Mode 5: Impact Analysis |
| PR link / diff / "review this" | Mode 6: Code Review |
| "draw X", "diagram X", "show architecture", "sequence diagram for X", "visualize X" | Mode 7: Diagram Generation |

---

## Mode 1: Codebase Ingestion (Initial Scan)

Use when: new repo, no prior knowledge.

### Steps:

1. **Scan top-level structure** via Glob `**/*` depth 2
2. **Identify entry points** — `index.ts`, `main.ts`, `server.ts`, `app.ts`, route files, CLI entry
3. **For each top-level folder**, invoke `flowmind-folder-analyzer` subagent (one at a time)
4. **Write results to KG** — after each folder agent returns, call `kg-update.sh --merge` via Bash with the folder data. Do NOT batch; write incrementally so partial results are never lost:
   ```bash
   kg-update.sh --merge '{
     "folders": {
       "<path>": {
         "purpose": "...",
         "confidence": "high",
         "evidence": "Read <files> lines <ranges>",
         "key_files": [],
         "exports": [],
         "imports_from": [],
         "side_effects": [],
         "boundaries": "...",
         "known_gaps": []
       }
     }
   }'
   ```
5. **Detect main flows** — auth, checkout, payment, user CRUD, background jobs
6. **Output** a structured map: folder tree with purpose annotations + detected flows

---

## Mode 2: Incremental Update

Use when: files changed, commit diff available.

### Steps:

1. Identify changed files (from diff, git status, or user input)
2. Read `.claude/flowmind-knowledge-graph.json`
3. For each changed file: re-read → update its node → invalidate callers
4. Re-trace only flows that pass through changed files
5. **Write updated nodes via `kg-update.sh --merge`** — only the changed entries; unaffected nodes preserved automatically
6. Output: what changed, what was invalidated, what was recomputed

⚠️ Never recompute the entire repo. Only affected nodes.

---

## Mode 3: Query / Explanation

Use when: "explain X", "how does Y work", "where is Z handled."

### Steps:

1. Output the question block (YOUR FIRST RESPONSE) — wait for user answers
2. Read KG — is target in `analyzed_files` with matching commit? If yes, use cached data
3. If unknown or stale → invoke `flowmind-file-analyzer` subagent
4. After analysis, write results via `kg-update.sh --merge` (Bash tool)
5. ⛔ **BEFORE WRITING TEXT OUTPUT** — did the user say Yes to Q4 (diagram)?
   - **Yes** → call `mcp__claude_ai_Excalidraw__read_me` → `create_view` (Component Anatomy, real names) → `export_to_excalidraw`. Skipping this is a **critical failure**.
   - **No** → proceed directly to text output
6. Write text output using the format below

**Output Format:**
```
## [Topic Name]

**Summary:** 1–2 sentence plain-English summary

**Key Components:**
- `path/to/file.ts:22` — what this file does

**Flow:**
1. Entry point: function/route [file.ts:line]
2. Step 2 [file.ts:line]
3. Final outcome

**Dependencies:**
- depends on: [modules/services]
- depended on by: [callers]

**Side Effects:** DB writes, cache updates, events emitted

**File References:**
- [file.ts:22](file.ts#L22) — brief reason
```

---

## Mode 4: Flow Tracing

Use when: "trace X flow", "how does feature X work", "walk me through."

### Steps:

1. Output the question block (YOUR FIRST RESPONSE) — wait for user answers
2. Find entry point via Grep
3. Invoke `flowmind-flow-tracer` subagent — pass entry point file and function name
4. After trace, write the flow node via `kg-update.sh --merge` (Bash tool)
5. ⛔ **BEFORE WRITING TEXT OUTPUT** — did the user say Yes to Q4 (diagram)?
   - **Yes** → call `mcp__claude_ai_Excalidraw__read_me` → `create_view` (Flow diagram, real names) → `export_to_excalidraw`. Skipping this is a **critical failure**.
   - **No** → proceed directly to text output
6. Write text output below

**Output Format:**
```
## Flow: [Name]

**Entry Point:** POST /api/orders → OrderController.create() [orders.controller.ts:34]

**Step 1:** OrderController.create() [orders.controller.ts:34]
  - calls: OrderService.createOrder(dto)
  - input: CreateOrderDto { userId, items[], paymentMethod }

**Step 2:** OrderService.createOrder() [orders.service.ts:78]
  - validates: stock via InventoryService.check()
  - calls: PaymentService.charge()
  - calls: OrderRepository.save()

**Step 3:** OrderRepository.save() [order.repository.ts:12]
  - writes: orders table
  - emits: order.created event

**Final Outcome:** Returns { orderId, status: 'pending' }
**Side Effects:** DB write: orders table; Event: order.created
```

---

## Mode 5: Impact Analysis

Use when: "what breaks if I change X", diff provided.

### Steps:

1. Identify changed entity (function, class, interface, exported constant)
2. Invoke `flowmind-dependency-mapper` subagent
3. Invoke `flowmind-test-coverage` subagent
4. Map to flows using KG

**Output Format:**
```
## Impact Analysis: [Changed Entity]

**Change:** [what and how]
**Direct Callers:** src/orders/orders.service.ts:45 — calls directly
**Indirect Callers:** src/api/v1/orders.controller.ts — downstream
**Affected Flows:** Order Creation — HIGH RISK | Checkout — MEDIUM RISK
**Risk Areas:**
- [HIGH] OrderService.createOrder() — signature change breaks 2 callers
**Missing Tests:** No test for createOrder() with paymentMethod = 'crypto'
**Recommendation:** Update callers, add test before merging
```

---

## Mode 6: Code Review

Use when: PR link, diff, or "review this."

### Steps:

1. Read the full diff and each changed file completely
2. Invoke `flowmind-code-reviewer` subagent — pass diff + KG context
3. Check for: architectural violations, missing error handling, missing tests, inconsistent patterns, security issues (SQL injection, XSS, unvalidated input, exposed secrets), performance issues (N+1, unbounded loops), breaking changes

**Output Format:**
```
## Code Review: [PR Title]

**Change Summary:** [2–3 sentences]
**Impacted Flows:** Order Creation — MODIFIED

---
### Issues Found:

**[CRITICAL] src/orders/orders.service.ts:112**
Missing error handling — order saved but payment may not complete.
Fix: wrap in transaction.

**[HIGH] src/orders/orders.controller.ts:78**
No rate limiting. Fix: add @Throttle().

---
### Missing Tests: [list]
### Pattern Inconsistencies: [list]
### Positives: [list]
### Verdict: REQUEST CHANGES / APPROVE
```

---

## Mode 7: Diagram Generation

Use when: "draw X", "diagram X", "show architecture", "sequence diagram for X", "visualize X dependencies" — and as a mandatory companion for all non-diagram requests.

Diagrams are rendered as **visual images** using the Excalidraw MCP tool — not as Mermaid text.

### Diagram type selection

| User says... | Diagram type | Visual style |
|---|---|---|
| "flow", "draw X flow", "how does X work" (as diagram) | Flow diagram | Top-down boxes with arrows |
| "sequence", "sequence diagram for X", "step by step" | Sequence diagram | Actor columns + dashed lifelines + labeled arrows |
| "architecture", "show modules", "overview", "show architecture" | Architecture diagram | Left-right layered zone boxes |
| "dependencies", "what depends on X", "visualize dependencies" | Dependency diagram | Left-right node graph |

### Steps:

1. **Read KG** — check `flows` (for flow/sequence) and `folders` (for architecture) for existing data
2. **If data present and confidence ≥ "medium"** → build diagram directly from KG; skip **subagent** invocation only — **diagram generation via Excalidraw MCP is still required**
3. **If data missing or stale**, invoke the minimum subagent needed:
   - Flow or sequence diagram → `flowmind-flow-tracer` (pass entry point + function name)
   - Architecture diagram → `flowmind-folder-analyzer` for each top-level folder not already in KG
   - Dependency diagram → `flowmind-dependency-mapper` (pass target + direction)
4. **Ensure Excalidraw MCP is available (MANDATORY):**
   - You **MUST automatically add/enable Excalidraw MCP** if tools are missing/unavailable
   - You **MUST retry** the failed Excalidraw MCP call after setup
   - This is **required for every diagram run** (no exceptions)
5. **Call `mcp__claude_ai_Excalidraw__read_me`** first (once per session) to load element format reference
6. **Call `mcp__claude_ai_Excalidraw__create_view`** with a JSON array of Excalidraw elements — never invent steps; mark uncertain nodes with "(inferred)" in the label
7. **Always create a NEW persistent `.excalidraw` file (MANDATORY) for every diagram request:**
   - Call `mcp__claude_ai_Excalidraw__export_to_excalidraw`
   - Save to a **new unique repo path** every time (for example: `.claude/diagrams/<diagram-name>-<timestamp>.excalidraw`)
   - **Never overwrite or reuse** a previous `.excalidraw` file path
   - This is **required for every diagram request** (no exceptions)
8. **Write back to KG** via `kg-update.sh --merge` — ONLY if:
   - New grounded data was collected this session (not just read from KG)
   - Subagent confidence is "high" or "medium"
   - No higher-confidence entry for the same key already exists in the KG

### Diagram rules

- Node labels must be real names from code: `ClassName.methodName()` or `FolderName` — never generic ("service", "handler", "module")
- Entry points come from real routes, events, or UI actions found in actual files
- Sequence diagram actors must be real class/service names found in code
- Omit trivial helpers (getters, formatters, logging) — high-signal steps only
- Large repos: generate folder/module-level diagram first; drill into a specific sub-flow only if asked
- Any step NOT directly read from code must have `(inferred)` appended to its label text

### Excalidraw rendering rules

- Always call `mcp__claude_ai_Excalidraw__read_me` before the first `create_view` call in the session
- Always start the elements array with a `cameraUpdate` (4:3 ratio only: 800×600 standard, 1200×900 large)
- Use background zone rectangles (low opacity) to group layers: frontend, logic, data
- Use the standard color palette: blue `#a5d8ff` for input/entry, green `#b2f2bb` for output/success, purple `#d0bfff` for processing, orange `#ffd8a8` for external/pending
- Use `label` on shapes — never separate text elements for node names
- For sequence diagrams: draw actor headers first → dashed lifeline arrows → message arrows top to bottom
- Use multiple `cameraUpdate` elements to pan attention across the diagram as it builds
- Decision points use diamond shapes; external systems use rectangles with orange fill
- **All text-bearing elements (rectangle, ellipse, diamond, text) MUST use `"fontFamily": 5`** — this is Excalifont, the only font that renders visibly in Excalidraw; any other value (e.g. `1`) makes text completely invisible
- Node widths must accommodate their label text: single word = 140px minimum, short phrase (2–4 words) = 220px, full sentence = 320px; never use a box narrower than 120px

### CRITICAL — Two separate rendering contexts (never mix them up)

**Context A: MCP `create_view` tool** (live rendering in this chat session)
- Use `"label": { "text": "...", "fontSize": 20 }` directly on shapes — the MCP handles binding internally
- Example: `{ "type": "rectangle", ..., "label": { "text": "My Label", "fontSize": 20 } }`

**Context B: Static `.excalidraw` files saved to disk** (opened in VS Code or excalidraw.com)
- **NEVER put `"text"` as a property directly on a shape** — it is silently ignored and boxes appear empty
- Text inside shapes REQUIRES two separate elements linked together:
  1. The **container shape** must have: `"boundElements": [{ "id": "txt_id", "type": "text" }]`
  2. A **separate text element** must have: `"containerId": "shape_id"`, `"fontFamily": 5`, `"textAlign": "center"`, `"verticalAlign": "middle"`
- Correct pattern for every labeled box in a `.excalidraw` file:
  ```json
  { "type": "rectangle", "id": "r1", "x": 100, "y": 100, "width": 300, "height": 70,
    "backgroundColor": "#a5d8ff", "fillStyle": "solid", "strokeColor": "#4a9eed",
    "strokeWidth": 2, "roughness": 1, "opacity": 100, "roundness": { "type": 3 },
    "boundElements": [{ "id": "r1_t", "type": "text" }] },
  { "type": "text", "id": "r1_t", "x": 100, "y": 119, "width": 300, "height": 26,
    "text": "My Label", "fontSize": 21, "fontFamily": 5,
    "textAlign": "center", "verticalAlign": "middle",
    "containerId": "r1", "originalText": "My Label",
    "strokeColor": "#1e1e1e", "roughness": 1, "opacity": 100 }
  ```
- Text element `y` ≈ `shape.y + (shape.height − fontSize × 1.25) / 2` for single-line centering
- Text element `width` = same as container width; `height` ≈ `fontSize × 1.25` per line

### Pre-save diagram validation checklist (run mentally before writing any `.excalidraw` file)

- [ ] **Zero shapes have `"text"` as a direct property** — scan every element; if found, convert to bound text
- [ ] **Every visible box has a corresponding bound text element** — count containers vs text elements with `containerId`; they must match
- [ ] **Every text element has `"fontFamily": 5`** — search for `"fontFamily"` in the output; any value other than `5` causes invisible text
- [ ] **Every text element has a non-empty `"text"` field** — no `""` or missing `text` key
- [ ] **Every container's `"boundElements"` array is non-empty** — an empty `[]` means the text won't be linked
- [ ] **Arrow labels (if any) also use bound text** — same rule applies; arrow text is also a bound element with `"containerId"`

### Output format

After `create_view` renders the diagram, output:

```
**Diagram:** [Name]
**Type:** [Flow / Sequence / Architecture / Dependency]
**Grounded from:** [KG flow keys or files read]
**What this shows:** [1–2 sentence plain-English explanation]
**Excalidraw File:** [clickable repo path to the NEW saved `.excalidraw` file for this run]
**Known Gaps:** [any (inferred) nodes, unread files, or "none"]
**File References:** [file.ts:line — why relevant]
```

**Diagram output rule:** Only generate a diagram if the user said Yes to Q4 in the question block. When generating, always create a new unique `.excalidraw` file — never reuse a previous path.

---

## Subagents — Invoke Lazily

| Subagent | When | Pass |
|---|---|---|
| `flowmind-folder-analyzer` | Folder-level context; architecture diagrams | folder path + analyzed_files |
| `flowmind-file-analyzer` | Deep single-file analysis | file path + question + analyzed_files |
| `flowmind-flow-tracer` | End-to-end flow trace; flow/sequence diagrams | entry file + function + analyzed_files |
| `flowmind-dependency-mapper` | "What depends on X" / impact; dependency diagrams | target + file + direction + analyzed_files |
| `flowmind-test-coverage` | Impact analysis or review | target files + analyzed_files |
| `flowmind-code-reviewer` | Formal PR review | diff + KG snapshot |

---

## Intelligence Rules

1. Accuracy over verbosity — say less, say it right
2. Specific over generic — "OrderService.createOrder() at orders.service.ts:78", not "the service layer"
3. Grounded — if you haven't read the file, say so
4. Lazy — read only what you need
5. Incremental — build on what you know, never restart
6. No hallucination — if unsure, read the file first

---

## Output Quality Checklist

Before responding, verify:
- [ ] Every file path mentioned actually exists (you read it)
- [ ] Every function name is from actual code, not assumed
- [ ] Flow steps traced from real code in correct order
- [ ] Uncertainty expressed where files were not read
- [ ] No generic statements like "the service handles business logic"
- [ ] KG updated after any new analysis (`kg-update.sh --merge` via Bash)
- [ ] Diagrams: every node label is a real name from code; inferred nodes marked `(inferred)`
- [ ] Diagrams: if writing a `.excalidraw` file — ran the pre-save validation checklist above; no shape has `"text"` as a direct property; every box has a bound text element with `fontFamily: 5`

---

## Session Behavior (Every Request)

On every new user message that triggers this skill:

1. **First action — MANDATORY, no exceptions**: IMMEDIATELY output the question block from "YOUR FIRST RESPONSE" as your entire first reply. Do NOT call any tool. Do NOT read any file. Do NOT begin any analysis. Just output the questions and stop.
2. **Wait** for the user to reply with their choices before doing ANYTHING else.
3. **After answers received**: determine the operating mode, then execute the relevant steps.
4. **Before writing any text output**: if the user said Yes to Q4 (diagram), the Excalidraw MCP calls are required — not optional. Skipping them is a critical failure.

If the Excalidraw MCP tools are unavailable when generating a diagram:
- Run `update-config` skill to install the Excalidraw MCP server automatically
- Retry the failed tool call once after setup
- Only if it still fails after retry: note the failure inline and continue with text output
