---
name: single-branch-development
description: 'Run a full end-to-end implementation pipeline on one branch or worktree (TDD, two-stage verification for spec compliance plus code quality, evidence capture, optional Copilot hooks, and draft PR handoff). Use when asked to implement one feature or foundation setup with strong quality gates but without parallel fan-out orchestration.'
---

# Single-Branch Development

Run one autonomous branch from implement to review to evidence to draft PR. This skill is a thin
**per-branch bracket** around `subagent-driven-development` (SDD): it adds isolation *before* the
loop, an evidence gate *after* it, a draft-PR boundary that **replaces** SDD's merge-capable finish,
and the optional hooks bundle. It does **not** re-implement the implement/review loop — SDD owns
that. Use it standalone (N=1) or composed by a higher-level orchestrator.

## When to Use This Skill

- User asks to implement one feature end-to-end on a single branch.
- User asks for foundation/bootstrap work with strict gates before parallel tracks exist.
- You want TDD + verifier + evidence + draft PR without parallel fan-out complexity.
- You need a reusable per-branch worker contract that another skill can compose.

## Prerequisites

- `git` and `gh` CLI authenticated for PR creation.
- One or more tasks defined (a single task or a small plan that SDD can execute).
- Project test commands are known (lint/unit/integration/e2e as applicable).
- Optional: Copilot agent hooks enabled with a hook file in `.github/hooks/*.json`.

## Pipeline (One Branch)

This pipeline **brackets** `subagent-driven-development`; it never re-describes or re-runs SDD's
internal stages.

1. **Isolate** — create/select one branch or worktree (`using-git-worktrees`). Never start on main.
2. **Delegate the implement → review loop to `subagent-driven-development`.** Per task, SDD runs a
   fresh implementer subagent (which follows `test-driven-development`) → **stage 1** spec/contract
   compliance review → **stage 2** code-quality/security review (`requesting-code-review` rubric),
   looping until both stages pass. These stages live in SDD — do not duplicate them here.
3. **Evidence gate** (`verification-before-completion`) — paste real command output; "all green"
   without pasted output is not done.
4. **Update the run artifact** if your workflow tracks one (`runs/<run-id>.json`, handoff notes).
5. **Draft-PR finish (overrides SDD's terminal).** Open a **draft** PR and stop. This step
   **replaces** SDD's call to `finishing-a-development-branch` — the worker never reaches that
   skill's merge menu. Integration/merge is owned by repo process/CI, not the worker.

## Quality Gates (Owned Here)

These are the **invariants** this skill asserts; most are *realized by* SDD's loop, not re-run here.

- **TDD required** for implementation changes (enforced inside SDD's implementer subagent).
- **Maker/checker principle required**: the stage-1/stage-2 reviewer must be a subagent distinct
  from the implementer (SDD's two-stage review; an orchestrator may require an *adversarial* verifier).
- **Evidence, not assertion**: completion requires command output evidence, not statements.
- **Self-heal cap**: at most `self_heal_attempts` (default 2) fix attempts per distinct failure, then stop and escalate `blocked` rather than thrashing. Counts *fix attempts*, distinct from any no-progress *stalled-pass* detector an orchestrator may add.
- **Draft-PR handoff** by default; this **overrides** `finishing-a-development-branch` (no local-merge menu). Merge policy is owned by repo process/CI.

## Hooks (Optional, Composable) — Bundle Owned Here

The gates above are only as strong as the worker's compliance — unless you make them
**mechanical**. Copilot's native [agent hooks](https://docs.github.com/en/copilot/concepts/agents/hooks)
run shell commands at lifecycle points (`PreToolUse`, `PostToolUse`, `SubagentStart`,
`SubagentStop`, `Stop`, …) and can **block a tool call before it happens**. Config lives in
`.github/hooks/*.json` (repo-scoped, so it travels with each worktree) and is read by VS Code
Agent Mode, the Copilot CLI, and the cloud agent. A `PreToolUse` hook receives the tool call as
JSON on stdin and denies it via exit code `2` (stderr → model) or
`hookSpecificOutput.permissionDecision: "deny"`.

Wire a gate to a hook only when it is a *mechanical* property (a path, a forbidden command, a
counter). Leave *judgement* gates — TDD ordering, the maker/checker split, review quality — as
prompt instructions; a hook cannot tell which subagent reasoned about something.

**Portability (no matchers; event names differ).** Copilot hooks have **no `matcher` field** —
unlike Claude Code, you cannot scope a hook to specific tools in config. A `PreToolUse` hook fires
on **every** tool call, so the script must branch on `tool_name` from stdin and early-exit (allow)
for tools it doesn't care about — which `track-guard.sh` already does. Event *names* also differ by
surface: the bundled `track-hooks.json` uses the VS Code keys (`preToolUse`, `postToolUse`,
`subagentStart`, `subagentStop`, `stop`); the Copilot CLI / cloud-agent docs name the same events
`agentStop` / `subagentStop` / `userPromptSubmitted` / `sessionEnd`. The *scripts* are
surface-agnostic (they read stdin JSON); only the registration keys change if you run them under the
CLI instead of VS Code.

This skill **ships the canonical bundle** ([`scripts/track-*.sh`](scripts/) +
[`templates/track-hooks.json`](templates/track-hooks.json)). Orchestrators that compose this skill
reuse the same files and only layer extra env on top.

| Pipeline gate | Bundled script (event) | What it does |
|---|---|---|
| Scope / never edit frozen entrypoints | `track-guard.sh` (`PreToolUse`) | **Deny** an edit whose target path is outside `TRACK_ALLOWED_PREFIXES` or hits a `TRACK_FROZEN_PATHS` entrypoint (deny-by-default, per worktree). |
| Never hand-edit generated or applied artifacts | `track-guard.sh` (`PreToolUse`) | **Deny** edits to any file carrying a `GENERATED — DO NOT EDIT` banner (re-run the generator), and to already-committed files under `TRACK_IMMUTABLE_PREFIXES` (e.g. applied migrations — add a NEW file instead). A brand-new file under the prefix is allowed. |
| No auto-merge from a worker | `track-guard.sh` (`PreToolUse`) | **Deny** `git push`, `gh pr merge`, `--force`, `--no-verify`, `git reset --hard` on terminal calls. Workers physically stop at `gh pr create --draft`. |
| No irreversible data/infra ops *(opt-in)* | `track-guard.sh` (`PreToolUse`) | When `TRACK_GUARD_DESTRUCTIVE` is set, **deny** `DROP`/`TRUNCATE`, unbounded `DELETE FROM` (no `WHERE`), Redis `FLUSHALL`/`FLUSHDB`, NATS stream/consumer teardown, and `rm -rf` on absolute/home paths. Stack-specific — tune the patterns. |
| Evidence gate (recorded test output) | `track-evidence.sh` (`PostToolUse`) | Append `{kind, cmd, response, fingerprint}` for test commands into the run record — captured by the tool, not claimed by the model. `fingerprint` (HEAD + tracked diff) ties each entry to the exact code it tested. **`tool_response` is textual, not a numeric exit code** (CI stays the pass/fail authority). |
| Evidence pack complete + fresh *(opt-in)* | `track-evidence-gate.sh` (`Stop`) | The closing “missing rows = not done” assertion. The required-kind set is **diff-conditional**: `TRACK_EVIDENCE_RULES` (`glob:kind` pairs) selects kinds by the paths the branch touched — so a frontend-only diff needs `ts`, a migration diff needs `pg-explain` — unioned with the optional always-on floor `TRACK_REQUIRED_EVIDENCE`. **`decision:block`** unless every selected kind has an entry whose `fingerprint` matches the **current** tree and whose response shows no failure marker — reporting exactly which are MISSING / STALE / FAILING. Selection is mechanical glob-matching (no model call); no-ops when both vars are unset or the diff selects nothing. Honors `stop_hook_active`; failure markers extend via `TRACK_FAIL_PATTERN`. Mechanizes verification-before-completion; CI stays authoritative. |
| Tool-call ceiling | `track-meter.sh` (`PostToolUse`) | Count tool calls; emit `continue:false` + set `status:no-progress` when `TRACK_MAX_TOOL_CALLS` trips. **Hook I/O carries no token/cost data**, so token/$ ceilings stay orchestrator-side. |
| Activation trace | `track-trace.sh` (`SubagentStart`/`SubagentStop`) | Append a `trace` entry per subagent spawn/stop. The `Run-Id:` *commit trailer* is NOT set here — add it in the worker's commit command or a git `prepare-commit-msg` hook. |
| Pre-handoff secret/leftover scan *(opt-in)* | `track-sentinel.sh` (`Stop`) | When `TRACK_SENTINEL` is set, scan the **staged diff** and `decision:block` if it finds a likely secret or debug leftover (`console.log`, `debugger`, `TODO(claude)`, `FIXME`). Honors `stop_hook_active` so it can't loop; patterns override via `TRACK_SECRET_PATTERN`/`TRACK_LEFTOVER_PATTERN`. Defense-in-depth — CI/secret-scanning stays authoritative. |
| Completion notification | `track-notify.sh` (`Stop`) | `curl` the run's terminal state to `TRACK_NOTIFY_WEBHOOK`. Best-effort; never blocks or fails the session. |

**Install:** copy every [`scripts/track-*.sh`](scripts/) into the repo's `.github/hooks/` directory
and place [`templates/track-hooks.json`](templates/track-hooks.json) there too. Each script is
**opt-in and no-ops unless its env is set**, so dropping them in is safe before configuring anything:
```bash
export TRACK_ALLOWED_PREFIXES="src/feature:test/feature"   # guard: this branch's writable scope
export RUN_ID="2026-06-27T14-03_feat"                       # <UTC-timestamp>_<id>
export TRACK_FROZEN_PATHS="cmd/main.go:internal/app/app.go" # guard: frozen entrypoints (see caveat)
export RUNS_DIR="runs"                                       # RUN_ID keys the record file
# OPTIONAL — each stays off until set
export TRACK_IMMUTABLE_PREFIXES="migrations/"               # guard: committed files here are append-only
export TRACK_GUARD_DESTRUCTIVE=1                            # guard: deny DROP/TRUNCATE/FLUSHALL/etc.
export TRACK_SENTINEL=1                                     # Stop: scan staged diff for secrets/leftovers
export TRACK_TEST_CMD_PATTERN="go test|uv run pytest|npm (run )?test"  # evidence
export TRACK_EVIDENCE_KINDS="go-test:go test -race;py:uv run pytest;ts:tsc --noEmit"  # tag evidence by pack row
export TRACK_EVIDENCE_RULES="*.go:go-test;*.py:py;*.tsx:ts;*.ts:ts;migrations/*:pg-explain"  # Stop gate: diff path → required kind
export TRACK_REQUIRED_EVIDENCE=""             # Stop gate: kinds required on EVERY diff (floor); empty = rules-only
export TRACK_MAX_TOOL_CALLS=200                                       # tool-call ceiling
export TRACK_NOTIFY_WEBHOOK="https://hooks.slack.com/services/..."     # notify
```

**Hooks are defense-in-depth, not the final gate.** They are local and bypassable. Layer them:
hooks (fast, in-session) → git `pre-push` (local backstop) → **CI (the unbypassable merge gate)**.

For foundation/bootstrap runs, avoid freezing paths too early. If entrypoints do not exist yet,
leave `TRACK_FROZEN_PATHS` unset for the bootstrap branch, then enable strict frozen entrypoints
for subsequent parallel tracks.

## Composition Contract

When composed by a parallel orchestrator, this skill's gates may be **tightened** by overlays such
as: distinct adversarial verifier subagent, draft-only/no-merge worker boundary, and stricter
run-id/trace requirements.

## References

- **Delegates the per-task implement → two-stage review loop to** `subagent-driven-development`,
  which **transitively** uses `test-driven-development` (implementation) and `requesting-code-review`
  (stage-2 rubric). Do **not** list those as separate steps — they are nested inside SDD.
- **Brackets that loop with** `using-git-worktrees` (isolation, before) and
  `verification-before-completion` (evidence gate, after).
- **Overrides** SDD's terminal `finishing-a-development-branch`: this skill stops at a **draft PR**
  (no local-merge menu); integration/merge is owned by repo process/CI.
- Related orchestrator: `../executing-parallel-tracks/SKILL.md` (dispatches one run of this skill
  per track and layers parallel-only overlays).
