#!/usr/bin/env bash
# track-report.sh — render the DETERMINISTIC half of a stage/PR completion report.
#
# NOT a hook. Run by the skill at Step 8 (draft-PR handoff). It emits the "Auto" block
# of the PR body ENTIRELY from machine state that already exists — never from the
# model's recollection — so the factual half of the report cannot drift from reality:
#
#   - Files changed + change size   ← git diff --name-status / --stat vs TRACK_BASE_REF
#   - Evidence (kind, cmd, fingerprint, pass/fail) ← runs/<RUN_ID>.json .evidence[]
#   - Tool calls / subagent order   ← runs/<RUN_ID>.json .tool_calls / .trace[]
#   - Self-reported skills / loops  ← runs/<RUN_ID>.json .skills[] / .iterations
#                                     (rendered UNDER a "self-reported" heading so a
#                                      reader can never mistake a model claim for a
#                                      hook-observed fact — same discipline as the record)
#   - Duration / timestamps         ← runs/<RUN_ID>.dispatch breadcrumb + heartbeat
#
# The NARRATIVE half (constitution/OWASP compliance, "After merge", caveats) is a model
# ASSERTION and is NOT produced here — it lives in templates/pr-body.md, which the skill
# fills in and appends. Keeping the two halves in separate producers is the whole point:
# machine-rendered facts vs. clearly-labelled model claims.
#
# Usage (writes the Auto block to stdout):
#   track-report.sh                 # uses $RUN_ID (or recovers it from a runs/*.dispatch)
#   track-report.sh <RUN_ID>        # explicit run id
#   track-report.sh --json          # emit the same facts as a JSON object (for tooling)
#
# Opt-in via env (same contract as the rest of the bundle):
#   RUN_ID          run id (else recovered from the newest runs/*.dispatch breadcrumb)
#   RUNS_DIR        where run records live (default: runs)
#   TRACK_BASE_REF  diff base for the files/size block (default: origin/main, then HEAD)
#
# Requires: jq, git. Read-only: never mutates the record, the tree, or git state.
set -eufo pipefail

# Bootstrap the same presets every bundle script sources (exported > worktree > base).
__env_dir="${BASH_SOURCE[0]%/*}"
if [ -f "$__env_dir/track-env.sh" ]; then . "$__env_dir/track-env.sh"; fi
if [ -f "$__env_dir/track-env.base.sh" ]; then . "$__env_dir/track-env.base.sh"; fi
unset __env_dir

RUNS_DIR="${RUNS_DIR:-runs}"
emit_json=0
run_id="${RUN_ID:-}"
for arg in "$@"; do
  case "$arg" in
    --json) emit_json=1 ;;
    -*)     printf 'track-report: unknown flag %s\n' "$arg" >&2; exit 2 ;;
    *)      run_id="$arg" ;;
  esac
done

# Recover RUN_ID from the newest breadcrumb when none was supplied — a solo run that
# never exported it can still be reported at handoff.
if [ -z "$run_id" ]; then
  # RUN_IDs are `<UTC-timestamp>_<track>`, so the lexically-greatest .dispatch is the
  # newest — a deterministic pick that also survives `set -f` (no glob) via find, and
  # doesn't depend on mtime. `|| true` keeps an empty runs/ from tripping pipefail.
  newest="$(find "$RUNS_DIR" -maxdepth 1 -name '*.dispatch' -type f 2>/dev/null | sort | tail -1 || true)"
  if [ -n "$newest" ]; then
    run_id="$(jq -r '.run_id // empty' "$newest" 2>/dev/null || true)"
    [ -n "$run_id" ] || run_id="$(basename "$newest" .dispatch)"
  fi
fi
[ -n "$run_id" ] || { printf 'track-report: no RUN_ID and no runs/*.dispatch to recover from.\n' >&2; exit 2; }

rec="$RUNS_DIR/$run_id.json"
dispatch="$RUNS_DIR/$run_id.dispatch"

# --- gather facts (missing sources degrade to empty, never abort) --------------------
base="${TRACK_BASE_REF:-origin/main}"
git rev-parse --verify --quiet "$base" >/dev/null 2>&1 || base="HEAD"

files_ns="$(git diff --name-status "$base"...HEAD 2>/dev/null || true)"
stat_line="$(git diff --shortstat "$base"...HEAD 2>/dev/null | sed 's/^ *//' || true)"
[ -n "$stat_line" ] || stat_line="no committed changes vs ${base}"

# record-derived (all optional — absent record = empty sections, not an error)
if [ -f "$rec" ]; then
  tool_calls="$(jq -r '.tool_calls // 0' "$rec" 2>/dev/null || echo 0)"
  started_ts="$(jq -r '.started_ts // empty' "$rec" 2>/dev/null || true)"
  last_ts="$(jq -r '.last_ts // empty' "$rec" 2>/dev/null || true)"
  iterations="$(jq -r '.iterations // 0' "$rec" 2>/dev/null || echo 0)"
else
  tool_calls=0; started_ts=""; last_ts=""; iterations=0
fi

if [ -f "$dispatch" ]; then
  d_branch="$(jq -r '.branch // empty' "$dispatch" 2>/dev/null || true)"
  d_tasks="$(jq -r '.tasks // empty' "$dispatch" 2>/dev/null || true)"
  d_created="$(jq -r '.created_utc // empty' "$dispatch" 2>/dev/null || true)"
  d_completed="$(jq -r '.completed_utc // empty' "$dispatch" 2>/dev/null || true)"
  d_duration="$(jq -r '.duration_secs // empty' "$dispatch" 2>/dev/null || true)"
else
  d_branch=""; d_tasks=""; d_created=""; d_completed=""; d_duration=""
fi

# --- JSON mode: same facts, machine-consumable --------------------------------------
if [ "$emit_json" -eq 1 ]; then
  jq -nc \
    --arg run_id "$run_id" --arg base "$base" \
    --arg stat "$stat_line" --arg files "$files_ns" \
    --argjson tool_calls "${tool_calls:-0}" --argjson iterations "${iterations:-0}" \
    --arg started_ts "$started_ts" --arg last_ts "$last_ts" \
    --arg branch "$d_branch" --arg tasks "$d_tasks" \
    --arg created "$d_created" --arg completed "$d_completed" --arg duration "$d_duration" \
    --slurpfile r "${rec:-/dev/null}" \
    '{run_id:$run_id, base:$base, branch:$branch, tasks:$tasks,
      change_shortstat:$stat,
      files:($files | split("\n") | map(select(length>0))),
      tool_calls:$tool_calls, iterations:$iterations,
      started_ts:$started_ts, last_ts:$last_ts,
      created_utc:$created, completed_utc:$completed, duration_secs:$duration,
      evidence:(($r[0].evidence) // []),
      trace:(($r[0].trace) // []),
      skills:(($r[0].skills) // [])}' 2>/dev/null \
  || printf '{"run_id":"%s","error":"record unreadable"}\n' "$run_id"
  exit 0
fi

# --- markdown mode: the "Auto" block ------------------------------------------------
md_row_files() {
  # git name-status → a markdown table (status letter → word)
  printf '%s\n' "$files_ns" | while IFS=$'\t' read -r st path rest; do
    [ -n "${st:-}" ] || continue
    case "$st" in
      A*) w="added" ;; M*) w="modified" ;; D*) w="deleted" ;;
      R*) w="renamed"; path="$rest" ;; C*) w="copied"; path="$rest" ;;
      *)  w="$st" ;;
    esac
    printf '| `%s` | %s |\n' "$path" "$w"
  done
}

printf '<!-- BEGIN track-report auto block — machine-rendered, do not hand-edit -->\n'
printf '### Run `%s`\n\n' "$run_id"
[ -n "$d_branch" ] && printf -- '- **Branch:** `%s`\n' "$d_branch"
[ -n "$d_tasks" ]  && printf -- '- **Tasks:** %s\n' "$d_tasks"
printf -- '- **Base:** `%s`\n' "$base"
if [ -n "$d_duration" ] && [ "$d_duration" != "null" ]; then
  printf -- '- **Duration:** %ss' "$d_duration"
  [ -n "$d_completed" ] && printf ' (completed %s)' "$d_completed"
  printf '\n'
elif [ -n "$started_ts" ]; then
  printf -- '- **Activity window:** %s → %s (heartbeat)\n' "$started_ts" "${last_ts:-$started_ts}"
fi
printf '\n#### Files changed\n\n'
if [ -n "$files_ns" ]; then
  printf '| File | Change |\n|---|---|\n'
  md_row_files
else
  printf '_No committed changes vs `%s`._\n' "$base"
fi
printf '\n_%s_\n' "$stat_line"

# Evidence — pass/fail derived from the recorded response text, fingerprint shown.
printf '\n#### Evidence\n\n'
if [ -f "$rec" ] && [ "$(jq -r '.evidence | length' "$rec" 2>/dev/null || echo 0)" -gt 0 ]; then
  printf '| Kind | Command | Result | Fingerprint |\n|---|---|---|---|\n'
  fail_pat="${TRACK_FAIL_PATTERN:-FAIL|--- FAIL|Error:|panic:|Traceback|AssertionError|✗|npm ERR!}"
  jq -r --arg fp "$fail_pat" '
    .evidence[] |
    ((.response // "") | test($fp)) as $failed |
    "| \(.kind // "?") | `\((.cmd // "?") | gsub("\\|";"\\|"))` | \(if $failed then "❌ FAIL" else "✅ pass" end) | `\((.fingerprint // "?")[0:12])` |"
  ' "$rec" 2>/dev/null || printf '| _(evidence unreadable)_ | | | |\n'
else
  printf '_No evidence rows recorded (evidence hooks not enabled, or none captured)._\n'
fi

# Mechanical run stats.
printf '\n#### Run stats (hook-observed)\n\n'
printf -- '- **Tool calls:** %s\n' "${tool_calls:-0}"
if [ -f "$rec" ] && [ "$(jq -r '.trace | length' "$rec" 2>/dev/null || echo 0)" -gt 0 ]; then
  printf -- '- **Subagent trace (in order):**\n'
  jq -r '.trace[] | "  - \(.t): \(.event) \(.agent_type // "") \((.agent_id // "") | if . == "" then "" else "(\(.))" end)"' \
    "$rec" 2>/dev/null || true
fi

# Self-reported — clearly fenced off from the mechanical facts above.
if [ -f "$rec" ] && { [ "$(jq -r '.skills | length' "$rec" 2>/dev/null || echo 0)" -gt 0 ] || [ "${iterations:-0}" -gt 0 ]; }; then
  printf '\n#### Trace (self-reported — model claim, not hook-observed)\n\n'
  if [ "$(jq -r '.skills | length' "$rec" 2>/dev/null || echo 0)" -gt 0 ]; then
    printf -- '- **Skill activations (in order):**\n'
    jq -r '.skills[] | "  - \(.t): \(.skill)\((.step // "") | if . == "" then "" else " — \(.)" end)"' \
      "$rec" 2>/dev/null || true
  fi
  [ "${iterations:-0}" -gt 0 ] && printf -- '- **Iterations (RED→GREEN→review cycles):** %s\n' "$iterations"
fi
printf '<!-- END track-report auto block -->\n'
exit 0
