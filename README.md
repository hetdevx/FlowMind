# FlowMind

A Claude Code skill that builds a persistent knowledge graph of your repository and gives you deep, grounded codebase understanding — explanations, flow traces, impact analysis, code review, and diagram generation.

---

## Installation

Install via the skills CLI:

```bash
npx skills add https://github.com/hetdevx/flowmind --skill flowmind
```

Or copy the skill manually to your Claude global skills directory:

```bash
cp -r FlowMind/ ~/.claude/skills/flowmind/
```

For per-project use, copy to your project instead:

```bash
cp -r FlowMind/ your-project/.claude/skills/flowmind/
```

Make scripts executable:

```bash
chmod +x ~/.claude/skills/flowmind/scripts/*.sh
```

Restart Claude Code. The skill activates automatically — no slash command needed. On session start, `kg-init.sh` runs and either loads your existing knowledge graph or creates a fresh one.

---

## What it does

FlowMind builds and maintains a `.claude/flowmind-knowledge-graph.json` file in your project. This file stores everything it has learned about your codebase — folder purposes, file responsibilities, end-to-end flows, dependency edges, and analysis metadata. Every session it loads this graph so it never starts from scratch.

---

## When to use what

### "I'm starting fresh on a new repo"
**→ Mode 1: Codebase Ingestion**

Say: `understand this codebase`

FlowMind scans your top-level structure, analyzes each folder with a dedicated subagent, detects main flows (auth, checkout, payment, etc.), and outputs an annotated folder map. Results are written to the knowledge graph for all future sessions.

---

### "Files just changed / I merged a PR"
**→ Mode 2: Incremental Update**

Say: `files changed in src/auth — update your understanding`

FlowMind identifies changed files, re-reads only those, invalidates any cached callers or flows that pass through them, and updates just the affected nodes in the graph. It never recomputes the entire repo.

---

### "Explain this file / function / module"
**→ Mode 3: Query / Explanation**

Say: `explain how auth works` or `how does OrderService.createOrder() work`

FlowMind checks the knowledge graph first. If the target is already analyzed at the current commit, it answers from cache. Otherwise it invokes the file analyzer subagent, then writes the result back to the graph.

---

### "Walk me through a full feature flow"
**→ Mode 4: Flow Tracing**

Say: `trace the checkout flow` or `walk me through how a user logs in`

FlowMind finds the entry point (route, event, UI action), invokes the flow tracer subagent to follow the real execution path step by step, then writes the traced flow to the graph for reuse.

---

### "What breaks if I change this?"
**→ Mode 5: Impact Analysis**

Say: `what breaks if I change PaymentService.charge()`

FlowMind identifies direct and indirect callers, maps impact to known flows, checks test coverage, and classifies risk as HIGH / MEDIUM / LOW with specific line references.

---

### "Review this PR / diff"
**→ Mode 6: Code Review**

Say: `review this PR` or paste a diff

FlowMind reads every changed file in full, checks for architectural violations, missing error handling, security issues (injection, XSS, exposed secrets), performance issues (N+1, unbounded loops), missing tests, and breaking changes. Outputs issues sorted by severity.

---

### "Show me a diagram"
**→ Mode 7: Diagram Generation**

| What you say | What you get |
|---|---|
| `draw the login flow` | `graph TD` flow diagram |
| `sequence diagram for checkout` | `sequenceDiagram` with real participants |
| `show architecture` | `graph LR` folder/module overview |
| `visualize dependencies of auth` | `graph LR` dependency map |

FlowMind reads the knowledge graph first. If a relevant flow is already traced at medium or high confidence, it renders the diagram immediately. Otherwise it invokes the minimum subagent needed, then renders. Every diagram node is a real name from code — uncertain nodes are labeled `(inferred)`.

---

## Subagents — what each one does

These run automatically when FlowMind needs them. You never invoke them directly.

| Subagent | Triggered by | What it does |
|---|---|---|
| `flowmind-folder-analyzer` | Mode 1 ingestion, Mode 7 architecture diagram | Analyzes one folder: purpose, key files, exports, imports, side effects |
| `flowmind-file-analyzer` | Mode 3 query, Mode 2 incremental update | Deep single-file analysis: all exported functions, params, return types, side effects, call chains |
| `flowmind-flow-tracer` | Mode 4 flow tracing, Mode 7 flow/sequence diagrams | Follows a real execution path from entry point to final outcome, step by step |
| `flowmind-dependency-mapper` | Mode 5 impact analysis, Mode 7 dependency diagrams | Maps what depends on a target (upstream) or what a target depends on (downstream) |
| `flowmind-test-coverage` | Mode 5 impact analysis, Mode 6 code review | Reports which callers and paths have no test coverage |
| `flowmind-code-reviewer` | Mode 6 code review | Formal review: security, performance, architecture, missing tests, breaking changes |

---

## Hook scripts — what runs automatically

| Script | When | What it does |
|---|---|---|
| `kg-init.sh` | Session start | Loads or creates the knowledge graph; resets `session_reads`; checks git staleness (branch/commit mismatch) |
| `post-read-track.sh` | After every `Read` tool call | Logs the file into `session_reads`; warns if a file was analyzed at a different commit than the current one |
| `pre-bash-guard.sh` | Before every `Bash` tool call | Allowlist-based guard — only read-only commands permitted; blocks shell operators, in-place edits, destructive patterns |
| `kg-update.sh` | Called by FlowMind via Bash | Single writer for semantic KG data; acquires file lock, deep-merges patch, validates schema, atomic write |

---

## Knowledge Graph

File: `.claude/flowmind-knowledge-graph.json`

The graph stores:
- `folders` — purpose, key files, exports, imports, boundaries for each folder
- `files` — responsibility, exported functions, call chains, side effects
- `flows` — end-to-end traced paths with step-by-step execution
- `analyzed_files` — metadata (when analyzed, at which commit, by which agent, confidence level)
- `dependency_edges` — explicit from→to dependency relationships
- `session_reads` — files opened this session (auto-managed by hook)

**Confidence levels:**
- `high` — full file read, all exports analyzed
- `medium` — partial read, minor gaps
- `low` — single file or unclear structure

FlowMind uses cached data only when confidence is `high` or `medium` **and** the stored commit matches the current git commit. Low-confidence or stale entries are treated as missing and re-analyzed.

**Writing to the graph:** FlowMind only writes through `kg-update.sh --merge`, never directly. This ensures atomic writes, file locking (no concurrent corruption), and schema validation on every update.

---

## Confidence and staleness

At session start, `kg-init.sh` compares the graph's stored branch and commit against the current repo state. If they differ, it prints a staleness warning and lists affected files. The graph is not automatically invalidated — FlowMind re-analyzes only the files it actually needs for your query.

---

## Canonical path format

All paths inside the knowledge graph are repo-relative and normalized:
- Correct: `src/auth/auth.service.ts`
- Wrong: `/Users/you/project/src/auth/auth.service.ts`
- Wrong: `./src/auth/auth.service.ts`

`kg-update.sh` normalizes paths automatically. Use repo-relative paths when referring to files in prompts for best results.
