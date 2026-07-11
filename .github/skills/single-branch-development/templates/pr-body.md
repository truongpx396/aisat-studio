<!--
  pr-body.md — completion / PR-body template for single-branch-development.

  TWO ZONES, kept deliberately separate:

  1. AUTO  — machine-rendered facts. Do NOT hand-write this. Generate it with:
                 bash .github/hooks/track-report.sh            # uses $RUN_ID / newest breadcrumb
             and paste its output where {{AUTO_BLOCK}} sits below (or pipe it in).
             It renders: files changed (grouped by area, with a collapsible full list when the
             diff is large), evidence (fingerprint + pass/fail), a compliance-warnings check,
             tool_calls, subagent trace, and (fenced off) any self-reported skills/loops.

  2. ASSERTED — the narrative you (the model) are CLAIMING. This is the only part you
             author by hand. Keep it clearly below the auto block so a reviewer can tell
             a verified fact from a model claim. Delete any section that doesn't apply —
             this template is a menu, not a mandate.
             Write plain GitHub Markdown: use real backticks (`like this`), NEVER escaped
             backticks (\` … \`) — escaping leaks literal backslashes into the rendered PR.

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
<!-- Prefer a TASK → intent table over prose — it maps the diff back to the plan and reads far
     better than a file-by-file list (the auto block already has the per-file/area breakdown).
     One row per task (or per merged task cluster), naming only the headline artifact + intent. -->
| Task | What it adds |
|------|--------------|
| {{T001}} | {{e.g. "three-runtime directory structure (backend-go / backend-python / frontend / deploy)"}} |
| {{T002}} | {{e.g. "`backend-go/go.mod` — Go 1.23, Gin/GORM/NATS/Redis/OTel"}} |
| {{T003+T009}} | {{merge tasks that share a file — e.g. "`pyproject.toml` deps + ruff/black config"}} |

#### Compliance
<!-- A TABLE of assertions, each citing the enforcing mechanism (a lint rule, a test, a config)
     so it is checkable, not just claimed. These are CLAIMS, not hook-verified facts. Delete rows N/A. -->
| ✓ | Principle / rule | How it's enforced |
|---|------------------|-------------------|
| ✅ | {{Principle I/II — kernel isolation}} | {{depguard bans kernel→internal (see `.golangci.yml`)}} |
| ✅ | {{OWASP A02/A03}} | {{credentials in env vars; images pinned}} |

#### Follow-ups / caveats
<!-- Anything a merger or the next stage must know: manual steps, deferred work, known gaps. -->
- {{e.g. "`go mod tidy` required in backend-go/ before first build (no go.sum in scaffold)"}}

#### After merge
{{What the next stage/PR should pick up. Delete if this is terminal.}}
