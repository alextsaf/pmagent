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

## Adopt it in a repo — one command

From inside the target repo:

```bash
cd /path/to/your-repo
~/Desktop/Projects/pmagent/scripts/adopt.sh
```

`adopt.sh` drops in the caller workflow + config + specs, creates the 5 labels,
sets the Actions permissions (token write + allow PR creation), and sets the
`CLAUDE_CODE_OAUTH_TOKEN` secret **cleanly** (no trailing newline — the cause of
"401 Invalid bearer token"). It's idempotent and won't clobber an existing
config/specs. Then:

1. Edit `pmagent.config.yml` (`test_cmd` must be a realistic e2e run).
2. Commit the new files and push.
3. Open a ticket issue → add the `spec-ready` label (or `gh workflow run
   agent.yml -f ticket=<issue#>`) → the pipeline runs and opens a PR.

## Create tickets — the Architect front-half

You don't hand-write tickets. The **`pmagent-architect`** skill (interactive, in a
local Claude Code session) turns a feature idea into detailed, spec-ready tickets:
it reads the codemap, clarifies scope with you, drafts the `specs/tickets/*` files,
and on your approval opens the issues + pushes the specs via `scripts/new_ticket.sh`.
It dispatches the autonomous pipeline only when you say so.

Mechanical path (what the skill calls, also usable directly from inside a repo):
```bash
~/Desktop/Projects/pmagent/scripts/new_ticket.sh --title "Add X" --spec draft.md [--dispatch]
```
Opens the issue, writes `specs/tickets/TICKET-<issue#>.md` to the default branch,
and (with `--dispatch`) labels it `spec-ready` to run the pipeline.

> Auth: the secret must be a `claude setup-token` OAuth token to bill your
> subscription. Generate with `claude setup-token`; **don't** set
> `ANTHROPIC_API_KEY` unless you want metered API billing.

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
