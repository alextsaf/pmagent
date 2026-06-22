#!/usr/bin/env bash
# Generate a codemap (repo graph) the Tech Lead + Implementer use for blast
# radius. Provider is set in pmagent.config.yml (codemap.provider).
# Output: codemap/ in the consuming repo.
set -euo pipefail

PROVIDER="$(yq -r '.codemap.provider' pmagent.config.yml 2>/dev/null || echo none)"
mkdir -p codemap

case "$PROVIDER" in
  aider)
    # aider's repo-map is a ranked, token-budgeted symbol/import map built for
    # LLM context. Cheapest good option to start.
    pip install -q aider-chat || true
    aider --show-repo-map > codemap/repomap.txt 2>/dev/null || \
      echo "aider repo-map unavailable; see fallback below" > codemap/repomap.txt
    ;;
  none|null|"")
    # Fallback: a lightweight structural map so the agents aren't blind.
    { echo "# codemap (fallback)"; echo; echo "## tree"; \
      git ls-files | head -300; } > codemap/repomap.txt
    ;;
  *)
    echo "Unknown codemap provider: $PROVIDER" >&2; exit 1;;
esac

echo "codemap written to codemap/repomap.txt"
