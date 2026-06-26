#!/usr/bin/env bash
# pmagent orchestrator. Drives one ticket through the state machine using
# separate, no-memory Claude Code invocations per phase. Runs in CI (see
# agent-engine.yml) but is plain bash so you can run it locally too.
#
# State machine (GitHub issue labels): spec-ready -> in-progress -> in-review -> done
#                                                         \-> needs-human (escalation)
set -euo pipefail

ENGINE="${PMAGENT_ENGINE:-$(cd "$(dirname "$0")/.." && pwd)}"
CFG="pmagent.config.yml"
ESC=".pmagent/escalation.md"
mkdir -p .pmagent

# Defensive: a trailing newline/space in the CLAUDE_CODE_OAUTH_TOKEN secret makes
# the API reject it as "401 Invalid bearer token". Strip whitespace if present.
# (Tokens contain no internal whitespace, so this is safe.)
if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  export CLAUDE_CODE_OAUTH_TOKEN="$(printf '%s' "$CLAUDE_CODE_OAUTH_TOKEN" | tr -d '[:space:]')"
fi

# ---- config helpers ---------------------------------------------------------
cfg() { yq -r "$1" "$CFG"; }
TICKET="${PMAGENT_TICKET:?ticket id/issue number required}"
TEST_CMD="$(cfg '.stack.test_cmd')"
LINT_CMD="$(cfg '.stack.lint_cmd')"
BUILD_CMD="$(cfg '.stack.build_cmd')"
IMPL_MODEL="$(cfg '.agent.implementer_model')"
REV_MODEL="$(cfg '.agent.reviewer_model')"
LEAD_MODEL="$(cfg '.agent.techlead_model')"
MAX_TURNS="$(cfg '.agent.max_turns')"
ROUNDS_MAX="$(cfg '.review.rounds_max')"
IMPL_ATTEMPTS="$(cfg '.agent.implement_attempts')"; [ "$IMPL_ATTEMPTS" = "null" ] && IMPL_ATTEMPTS=3

# Tools each phase may use. NOTE: validate the exact --permission-mode value on
# first CI run (candidate: dontAsk / acceptEdits). Until confirmed, runs may
# require the broader sandbox flag on an ephemeral runner.
EDIT_TOOLS='Bash(git *),Bash(gh *),Bash(pnpm *),Bash(npm *),Bash(node *),Read,Edit,Write'
READ_TOOLS='Bash(git *),Bash(gh *),Read'
PERM='--permission-mode acceptEdits'   # TODO: confirm correct CI value

# claude_run <role_file> <allowed_tools> <model> <task_prompt>  -> stdout
claude_run() {
  local role="$1" tools="$2" model="$3" task="$4"
  # NOTE: do NOT add --bare here. --bare forces auth to be "strictly
  # ANTHROPIC_API_KEY" and IGNORES the CLAUDE_CODE_OAUTH_TOKEN subscription token,
  # which makes every call fail with "Not logged in". A fresh CI runner has no
  # hooks/plugins/MCP to skip anyway, so --bare buys us nothing here.
  claude -p "$task" \
    --append-system-prompt "$(cat "$ENGINE/roles/$role")" \
    --allowedTools "$tools" \
    --model "$model" \
    --max-turns "$MAX_TURNS" \
    $PERM --output-format json
}

# ---- cost accounting + work evidence ----------------------------------------
# Every claude_run uses --output-format json, which reports per-call token usage
# (and total_cost_usd). We accumulate it and post an API-equivalent $ proxy.
COST_FILE=".pmagent/cost.tsv"; : > "$COST_FILE"

# Fallback $ per 1M tokens, used only when a run doesn't report total_cost_usd.
# VERIFY against current Anthropic pricing; edit freely.
rate_in()  { case "$1" in *opus*) echo 15;; *haiku*) echo 1;; *) echo 3;;  esac; }   # sonnet=3
rate_out() { case "$1" in *opus*) echo 75;; *haiku*) echo 5;; *) echo 15;; esac; }   # sonnet=15

result_text() { jq -r '.result // ""' "$1" 2>/dev/null || echo ""; }
comment() { gh issue comment "$TICKET" --body "$1" >/dev/null 2>&1 || true; }

# record_usage <phase_label> <model> <result_json_file>
record_usage() {
  local label="$1" model="$2" f="$3" in out cin cread cost
  [ -f "$f" ] || return 0
  in=$(jq -r '.usage.input_tokens // 0'  "$f" 2>/dev/null || echo 0)
  out=$(jq -r '.usage.output_tokens // 0' "$f" 2>/dev/null || echo 0)
  cin=$(jq -r '.usage.cache_creation_input_tokens // 0' "$f" 2>/dev/null || echo 0)
  cread=$(jq -r '.usage.cache_read_input_tokens // 0'   "$f" 2>/dev/null || echo 0)
  cost=$(jq -r '.total_cost_usd // empty' "$f" 2>/dev/null || echo "")
  in=$(( in + cin + cread ))   # count cache tokens as input for the proxy
  if [ -z "$cost" ]; then
    cost=$(awk -v i="$in" -v o="$out" -v ri="$(rate_in "$model")" -v ro="$(rate_out "$model")" \
      'BEGIN{printf "%.4f",(i/1e6*ri)+(o/1e6*ro)}')
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$label" "$model" "$in" "$out" "$cost" >> "$COST_FILE"
}

cost_report() {  # -> markdown table + totals
  [ -s "$COST_FILE" ] || { echo "_no usage recorded_"; return; }
  awk -F'\t' '
    BEGIN{print "### 💸 Cost (API-equivalent proxy)\n";
          print "| phase | model | in tok | out tok | ~$ |";
          print "|---|---|--:|--:|--:|"}
    {printf "| %s | %s | %d | %d | %.4f |\n",$1,$2,$3,$4,$5; ti+=$3; to+=$4; tc+=$5}
    END{printf "\n**Total: %d in + %d out tok · ~$%.2f at API rates**\n",ti,to,tc;
        print "_Billed to the Max subscription; $ is the pay-as-you-go equivalent._"}
  ' "$COST_FILE"
}

# Leave work evidence on the issue so the NEXT agent/run has context.
post_implement_evidence() {
  local stat last summary
  stat=$(git diff --stat main...HEAD 2>/dev/null | tail -40)
  last=$(ls -t .pmagent/impl-implement-*.json 2>/dev/null | head -1)
  summary=$(result_text "$last")
  comment "## 🛠 Implementation — \`#$TICKET\`
**Branch:** \`pmagent/$TICKET\`

<details><summary>Files changed</summary>

\`\`\`
$stat
\`\`\`
</details>

<details><summary>Implementer notes</summary>

$summary
</details>"
}

post_review_evidence() {  # <round> <result_json_file>
  comment "## 🔍 Review round $1 — $REV_MODEL (no-memory)

\`\`\`json
$(result_text "$2")
\`\`\`"
}

escalate() {
  local reason="$1"
  gh issue edit "$TICKET" --add-label needs-human --remove-label in-progress || true
  local body="🚧 **pmagent paused — needs human**

$reason"
  [ -f "$ESC" ] && body="$body

$(cat "$ESC")"
  comment "$body

$(cost_report)"
  echo "ESCALATED: $reason" >&2
  exit 0
}

GATE_LOG=".pmagent/gate.log"

run_gate() {  # run one project command, tee output to gate log; null/empty = skip
  local cmd="$1" name="$2"
  { [ "$cmd" = "null" ] || [ -z "$cmd" ]; } && { echo "skip $name"; return 0; }
  echo "::group::$name"
  set +e; eval "$cmd" 2>&1 | tee -a "$GATE_LOG"; local rc=${PIPESTATUS[0]}; set -e
  echo "::endgroup::"
  return $rc
}

verify_gates() {  # 0 only if lint+build+e2e all pass; failing output lands in GATE_LOG
  : > "$GATE_LOG"
  run_gate "$LINT_CMD"  "lint"  || return 1
  run_gate "$BUILD_CMD" "build" || return 1
  run_gate "$TEST_CMD"  "e2e"   || return 1
  return 0
}

# implement_until_green <first_task_prompt> <label>
# The real loop: implement -> verify gates. On red, feed the failure output back
# and let the implementer try again. Escalate to needs-human ONLY when either
#   (a) the implementer writes .pmagent/escalation.md (genuine ambiguity/blocker), or
#   (b) gates are still red after IMPL_ATTEMPTS tries.
# A single failing test run is NOT an escalation — it's the next attempt.
implement_until_green() {
  local task="$1" label="$2" attempt=1
  while [ "$attempt" -le "$IMPL_ATTEMPTS" ]; do
    echo "==> Implementer ($label) attempt $attempt/$IMPL_ATTEMPTS"
    claude_run implementer.md "$EDIT_TOOLS" "$IMPL_MODEL" "$task" \
      > ".pmagent/impl-$label-$attempt.json" || true
    record_usage "$label#$attempt" "$IMPL_MODEL" ".pmagent/impl-$label-$attempt.json"
    [ -f "$ESC" ] && escalate "Implementer reported a blocker during '$label'."
    if verify_gates; then
      # Orchestrator commits the implementer's work-tree edits onto the branch.
      git add -A
      git diff --cached --quiet || git commit -q -m "pmagent($label): ticket $TICKET"
      echo "Gates green ($label, attempt $attempt)."; return 0
    fi
    echo "Gates red ($label, attempt $attempt) — feeding failures back to implementer."
    task="Ticket $TICKET: lint/build/e2e are FAILING. Fix the code (or the test, if the test itself is wrong) until ALL are green. Do NOT open the PR.

Failing output (tail):
$(tail -c 4000 "$GATE_LOG")"
    attempt=$((attempt+1))
  done
  escalate "Gates still red after $IMPL_ATTEMPTS implement attempts ('$label'). Last failures:
$(tail -c 1500 "$GATE_LOG")"
}

# ---- auth preflight: fail fast & clearly on bad credentials -----------------
# A bad/truncated token otherwise wastes the whole run and reports a misleading
# "reviewer still requesting changes". Probe once; surface token length + error.
echo "==> Auth preflight (CLAUDE_CODE_OAUTH_TOKEN length=${#CLAUDE_CODE_OAUTH_TOKEN}, ANTHROPIC_API_KEY set=${ANTHROPIC_API_KEY:+yes})"
PROBE="$(claude -p "reply with the single word OK" --max-turns 1 --output-format json 2>&1 || true)"
if printf '%s' "$PROBE" | grep -qiE 'invalid bearer|not logged in|please run /login|authenticat'; then
  escalate "Auth preflight failed (token length ${#CLAUDE_CODE_OAUTH_TOKEN}): $(printf '%s' "$PROBE" | tr -d '\n' | head -c 240)"
fi
echo "Auth OK."

# ---- phase 0: claim ticket --------------------------------------------------
gh issue edit "$TICKET" --add-label in-progress --remove-label spec-ready || true
TICKET_FILE="specs/tickets/TICKET-${TICKET}.md"
[ -f "$TICKET_FILE" ] || TICKET_FILE="$(ls specs/tickets/ 2>/dev/null | head -1)"

# The ORCHESTRATOR owns all git (the CI runner has no identity, and we don't want
# to depend on the implementer running git correctly). Set identity + branch here;
# the implementer only edits files, and we commit after each green gate.
git config user.email "pmagent-bot@users.noreply.github.com"
git config user.name "pmagent"
BRANCH="pmagent/${TICKET}"
git checkout -B "$BRANCH"

# ---- phase 1: tech-lead enrich — SAFETY NET ONLY ----------------------------
# The Architect normally enriches tickets interactively (with you) before they're
# marked spec-ready, so this branch should rarely fire. It only runs if a ticket
# somehow arrives without acceptance criteria, so a cheap implementer isn't left
# guessing. The happy path skips straight to implement.
if ! grep -q "Acceptance criteria" "$TICKET_FILE" 2>/dev/null; then
  echo "==> Tech Lead enriching $TICKET_FILE (ticket arrived thin)"
  claude_run techlead.md "$EDIT_TOOLS" "$LEAD_MODEL" \
    "Enrich ticket $TICKET (file: $TICKET_FILE) per your role. Use codemap/ and specs/prd.md." \
    > .pmagent/techlead.json || true
  record_usage "techlead" "$LEAD_MODEL" .pmagent/techlead.json
  [ -f "$ESC" ] && escalate "Tech Lead could not enrich the ticket."
fi

# ---- phase 2: implement until the e2e gate is green (retries, not instant give-up)
implement_until_green \
  "Implement ticket $TICKET (file: $TICKET_FILE) per your role. Add a realistic e2e test and make lint/build/e2e green. Do NOT run any git commands (no branch/add/commit/push) and do NOT open a PR — the orchestrator handles all git. Just edit files." \
  "implement"
post_implement_evidence   # leave a work-log comment on the issue

# ---- phase 3: no-memory reviewer loop ---------------------------------------
round=1
while [ "$round" -le "$ROUNDS_MAX" ]; do
  echo "==> Review round $round/$ROUNDS_MAX"
  claude_run reviewer.md "$READ_TOOLS" "$REV_MODEL" \
    "Review the diff: git diff main...HEAD for ticket $TICKET. Output strict JSON per your role." \
    > ".pmagent/review-$round.json" || true
  record_usage "review#$round" "$REV_MODEL" ".pmagent/review-$round.json"
  post_review_evidence "$round" ".pmagent/review-$round.json"

  verdict="$(result_text ".pmagent/review-$round.json" | grep -o '"verdict" *: *"[a-z-]*"' | head -1 || true)"
  if echo "$verdict" | grep -q 'clean'; then
    echo "Review clean."; break
  fi
  if [ "$round" -eq "$ROUNDS_MAX" ]; then
    escalate "Reviewer still requesting changes after $ROUNDS_MAX rounds."
  fi
  echo "==> Applying reviewer fixes (round $round)"
  # Same retry-until-green loop: fixes must keep the gates green, with retries.
  implement_until_green \
    "Address the reviewer findings in .pmagent/review-$round.json for ticket $TICKET, then keep lint/build/e2e green. Do NOT open the PR." \
    "fix-$round"
  round=$((round+1))
done

# ---- phase 4: push branch + open PR (surface failures, don't swallow them) ---
echo "==> Opening PR"
if [ "$(git rev-list --count "main..$BRANCH" 2>/dev/null || echo 0)" -eq 0 ]; then
  escalate "Implementer produced no commits on $BRANCH — nothing to PR (it may have made no real change)."
fi
git push -u origin "$BRANCH" 2>".pmagent/push_err" \
  || escalate "Could not push $BRANCH: $(head -c 200 .pmagent/push_err)"
if PR_URL="$(gh pr create \
    --title "pmagent: ${TICKET}" \
    --body "Automated implementation of #${TICKET}. e2e green, reviewed by ${REV_MODEL} (no-memory). **Human merge required.**

$(cost_report)" \
    --base main --head "$BRANCH" 2>".pmagent/pr_err")"; then
  :
else
  escalate "PR creation failed: $(head -c 200 .pmagent/pr_err)"
fi
gh issue edit "$TICKET" --add-label in-review --remove-label in-progress || true

# Final work-evidence comment on the issue: PR link + full cost report.
comment "## ✅ PR opened — awaiting your merge
${PR_URL}

$(cost_report)"
echo "DONE: PR opened for ticket $TICKET (${PR_URL}), awaiting human merge."
