<!--
  pr-body.md — completion / PR-body template for single-branch-development.

  TWO ZONES, kept deliberately separate:

  1. AUTO  — machine-rendered facts. Do NOT hand-write this. Generate it with:
                 bash .github/hooks/track-report.sh            # uses $RUN_ID / newest breadcrumb
             and paste its output where {{AUTO_BLOCK}} sits below (or pipe it in).
             It renders: files changed + size, evidence (fingerprint + pass/fail),
             tool_calls, subagent trace, and (fenced off) any self-reported skills/loops.

  2. ASSERTED — the narrative you (the model) are CLAIMING. This is the only part you
             author by hand. Keep it clearly below the auto block so a reviewer can tell
             a verified fact from a model claim. Delete any section that doesn't apply —
             this template is a menu, not a mandate.

  Everything between {{ }} is a fill-in. Remove these HTML comments before publishing.
-->

## {{TITLE — e.g. "Stage 1: Setup — Three-Runtime Skeleton"}}

{{ONE-SENTENCE summary of what this PR does.}}

---

{{AUTO_BLOCK}}
<!-- ^ paste `track-report.sh` output here. Everything above the "ASSERTED" line is machine-derived. -->

---

### Asserted — narrative & compliance (model claim, verify before trusting)

#### What this adds
{{Optional prose or a task→intent table. The FILE list is already in the auto block above;
  use this only for INTENT the diff can't show. Delete if the auto block is self-explanatory.}}

#### Compliance
<!-- Each line here is an ASSERTION, not a hook-verified fact. Cite the enforcing mechanism
     (a lint rule, a test, a config) so it is checkable, not just claimed. Delete if N/A. -->
- {{✅ Principle / rule — how it's enforced, e.g. "depguard bans kernel→internal (see .golangci.yml)"}}
- {{✅ OWASP Axx — concrete mitigation, e.g. "credentials in env vars, images pinned"}}

#### Follow-ups / caveats
<!-- Anything a merger or the next stage must know: manual steps, deferred work, known gaps. -->
- {{e.g. "`go mod tidy` required in backend-go/ before first build (no go.sum in scaffold)"}}

#### After merge
{{What the next stage/PR should pick up. Delete if this is terminal.}}
