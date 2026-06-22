# pmagent

Autonomous, spec-driven development engine. You act as Project Manager — write
PRDs and tickets; agents implement, test, and review while you're away. Agents
stop at "PR ready"; **you always perform the merge.**

See [`docs/PLAN.md`](docs/PLAN.md) for the architecture and build milestones.

## How it's structured

- **This repo = the shared engine.** Role prompts (`roles/`), the orchestrator
  (`scripts/run_agent.sh`), and a reusable GitHub Actions workflow
  (`.github/workflows/agent-engine.yml`). Update once → every project benefits.
- **Each consuming repo = a thin footprint.** Copy `templates/` in:
  - `.github/workflows/agent.yml` → calls the reusable engine workflow
  - `pmagent.config.yml` → the only file you customize per project
  - `specs/` → canonical, in-repo PRD + tickets (the agents' contract)

## Adopt it in a repo (M1 spine)

1. Copy `templates/agent.yml` → `<repo>/.github/workflows/agent.yml`
   and `templates/pmagent.config.yml` → `<repo>/pmagent.config.yml`; edit config.
2. Copy `templates/specs/` → `<repo>/specs/` and write one real ticket.
3. Add a repo secret: `ANTHROPIC_API_KEY` **or** `CLAUDE_CODE_OAUTH_TOKEN`.
4. Create GitHub issue labels: `spec-ready`, `in-progress`, `in-review`,
   `needs-human`, `done`.
5. Open an issue, attach the `spec-ready` label → the pipeline runs and opens a PR.

## State machine

`spec-ready → in-progress → in-review → done`, with `needs-human` as the
escalation branch. A PR cannot reach `in-review` until the realistic e2e gate
(`stack.test_cmd`) is green.

## Status / first-run validation

This is the M0 scaffold. Before trusting it unattended, validate on first CI run:
- exact `--permission-mode` value for headless CI (`scripts/run_agent.sh:PERM`)
- the engine `repository:`/`ref:` in `agent-engine.yml` once this repo is pushed
- model ids in `pmagent.config.yml` match what the CLI accepts

## Billing — keep it on your subscription

Authenticate with a `CLAUDE_CODE_OAUTH_TOKEN` secret (from `claude setup-token`).
Every Claude call in the pipeline then bills your Claude (Max) plan, not API
credits. **Do not set `ANTHROPIC_API_KEY`** — it forces metered pay-as-you-go
billing and overrides the OAuth token even when empty. Reserve an API key as a
manual overflow only if Max rate limits throttle a busy run. Because all layers
share one subscription quota, keep reviewer fan-out small and tickets mostly
serial to avoid hitting Max's usage windows.
