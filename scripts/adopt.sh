#!/usr/bin/env bash
# Adopt pmagent in a repository, in one shot. Run from INSIDE the target repo:
#
#   cd /path/to/your-repo
#   ~/Desktop/Projects/pmagent/scripts/adopt.sh
#
# It drops in the thin caller workflow + config + specs, creates the 5 labels,
# sets the Actions permissions, and sets the subscription token secret cleanly
# (no trailing newline — the thing that caused "401 Invalid bearer token").
#
# Idempotent: safe to re-run. Won't clobber an existing pmagent.config.yml/specs.
# Env: SKIP_TOKEN=1 to skip the secret step; GH_ACCOUNT=<user> to switch first.
set -euo pipefail

ENGINE="$(cd "$(dirname "$0")/.." && pwd)"
TPL="$ENGINE/templates"

[ -n "${GH_ACCOUNT:-}" ] && gh auth switch -u "$GH_ACCOUNT" >/dev/null 2>&1 || true

# Target repo: arg owner/repo, else inferred from this repo's git remote.
REPO="${1:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)}"
[ -n "$REPO" ] || { echo "Run inside a repo with a GitHub remote, or pass owner/repo." >&2; exit 1; }
echo "Adopting pmagent in: $REPO   (gh account: $(gh api user -q .login 2>/dev/null || echo '?'))"

# 1. Files: thin caller workflow + config + specs (don't overwrite existing config/specs).
mkdir -p .github/workflows specs/tickets
cp "$TPL/agent.yml" .github/workflows/agent.yml
[ -f pmagent.config.yml ] || cp "$TPL/pmagent.config.yml" pmagent.config.yml
[ -f specs/prd.md ] || cp "$TPL/specs/prd.md" specs/prd.md
[ -f specs/tickets/TICKET-EXAMPLE.md ] || cp "$TPL/specs/tickets/TICKET-EXAMPLE.md" specs/tickets/TICKET-EXAMPLE.md
echo "✓ workflow + config + specs in place"

# 2. Labels = the state machine (idempotent; bash 3.2-compatible, no assoc arrays).
for pair in "spec-ready:0E8A16" "in-progress:FBCA04" "in-review:1D76DB" "needs-human:D93F0B" "done:6F42C1"; do
  gh label create "${pair%%:*}" -R "$REPO" --color "${pair##*:}" --force >/dev/null
done
echo "✓ labels created"

# 3. Actions permissions: GITHUB_TOKEN write + allow Actions to create/approve PRs.
#    (Without this the reusable engine job exceeds the caller's grant -> startup_failure.)
gh api --method PUT "repos/$REPO/actions/permissions/workflow" \
  -F default_workflow_permissions=write -F can_approve_pull_request_reviews=true >/dev/null
echo "✓ Actions permissions set (write + PR create)"

# 4. Subscription token secret — set WITHOUT a trailing newline (printf, not echo),
#    which is what previously caused "401 Invalid bearer token".
if [ "${SKIP_TOKEN:-}" != "1" ]; then
  echo
  echo "Need a token? Run:  claude setup-token   (log in with your Max account)"
  echo "Tip: test it first ->  CLAUDE_CODE_OAUTH_TOKEN='<token>' claude -p 'reply OK'"
  read -rs -p "Paste CLAUDE_CODE_OAUTH_TOKEN (hidden; blank to skip): " TOKEN; echo
  if [ -n "$TOKEN" ]; then
    printf %s "$TOKEN" | gh secret set CLAUDE_CODE_OAUTH_TOKEN -R "$REPO"
    echo "✓ secret set cleanly (no trailing newline)"
  else
    echo "– skipped. Later:  printf %s '<token>' | gh secret set CLAUDE_CODE_OAUTH_TOKEN -R $REPO"
  fi
fi

cat <<EOF

Done. Next:
  1. Edit pmagent.config.yml (test_cmd must be a realistic e2e run).
  2. Commit the new files: git add -A && git commit -m "Adopt pmagent" && git push
  3. Open a ticket issue, then add the 'spec-ready' label (or:
     gh workflow run agent.yml -f ticket=<issue#> -R $REPO).
EOF
