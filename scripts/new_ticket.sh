#!/usr/bin/env bash
# Create a pmagent ticket from a drafted spec, the same way the Architect does by
# hand: open the GitHub issue, write the spec to specs/tickets/TICKET-<issue#>.md
# on the default branch, and (optionally) dispatch by labeling spec-ready.
# Run from INSIDE the consuming repo.
#
#   new_ticket.sh --title "Add X" --spec /path/to/draft.md [--dispatch]
#
# The spec is pushed via the GitHub API so it works even if your local checkout is
# behind the remote default branch (pmagent merges happen on GitHub).
set -euo pipefail

TITLE=""; SPEC=""; DISPATCH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --title)    TITLE="$2"; shift 2;;
    --spec)     SPEC="$2";  shift 2;;
    --dispatch) DISPATCH=1; shift;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done
[ -n "$TITLE" ] && [ -f "$SPEC" ] || {
  echo "usage: new_ticket.sh --title <title> --spec <file.md> [--dispatch]" >&2; exit 1; }

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" \
  || { echo "run inside a GitHub repo (and check 'gh auth status')" >&2; exit 1; }
BRANCH="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || echo main)"
echo "repo: $REPO   branch: $BRANCH   account: $(gh api user -q .login 2>/dev/null)"

# 1. open the issue (its number becomes the ticket id the pipeline keys on)
URL="$(gh issue create -R "$REPO" --title "$TITLE" \
  --body "Detailed spec in \`specs/tickets/\`. Add the \`spec-ready\` label to run the pipeline.")"
N="${URL##*/}"
echo "issue #$N: $URL"

# 2. normalize the spec's H1 to "# TICKET-N:" (or prepend one)
TMP="$(mktemp)"
if head -1 "$SPEC" | grep -qiE '^# *TICKET'; then
  sed "1s/^# *TICKET[^:]*:/# TICKET-$N:/" "$SPEC" > "$TMP"
else
  { echo "# TICKET-$N: $TITLE"; echo; cat "$SPEC"; } > "$TMP"
fi

# 3. push the spec to the default branch via the API
content="$(base64 < "$TMP" | tr -d '\n')"
gh api --method PUT "repos/$REPO/contents/specs/tickets/TICKET-$N.md" \
  -f message="Add ticket spec for #$N ($TITLE)" \
  -f content="$content" -f branch="$BRANCH" --jq '.commit.sha' >/dev/null
rm -f "$TMP"
echo "spec → specs/tickets/TICKET-$N.md on $BRANCH"

# 4. dispatch only if asked — releasing a ticket spends subscription quota + opens a PR
if [ "$DISPATCH" = "1" ]; then
  gh issue edit "$N" -R "$REPO" --add-label spec-ready >/dev/null
  echo "labeled spec-ready → pipeline running for #$N"
else
  echo "drafted, not dispatched. Release it with:  gh issue edit $N -R $REPO --add-label spec-ready"
fi
echo "TICKET_NUMBER=$N"
