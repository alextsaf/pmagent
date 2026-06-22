# pmagent — Build Plan

Autonomous, spec-driven development pipeline. You act as Project Manager; agents
implement, test, and review tickets while you're away. You stay the merge gate.

## Architecture (one-screen view)

```
 HUMAN-FACING            CANONICAL LAYER (in-repo)         AGENTS (Claude Code headless)
 ────────────            ─────────────────────────         ────────────────────────────
 Notion / ClickUp  ──▶   specs/prd.md                ──▶   PM      (compiles PRD)
 (PRD + tickets)         specs/tickets/TICKET-*.md    ──▶   TechLead(enriches ticket + codemap)
                         codemap/ (repo graph)        ──▶   Implementer (cheap model, branch+tests)
                         .pmagent/config.yml          ──▶   Reviewer x N (no-memory, adversarial)
                                                            └─▶ opens PR → YOU merge
```

The **canonical layer lives in the repo**. External tools are views; adapters
translate them into `specs/`. Swap a tool → rewrite one adapter, not the pipeline.

## Repo split (modularity)

- **`pmagent` (this repo)** = the shared engine: role prompts, orchestrator,
  reusable GitHub Actions workflow. Update once, every project benefits.
- **Each consuming repo** = thin footprint: `.github/workflows/agent.yml`
  (calls the reusable workflow), `pmagent.config.yml`, `specs/`.
- **Template repository** = a GitHub "template repo" pre-wired for new projects.

## State machine (GitHub issue labels are the queue)

```
spec-ready ──▶ in-progress ──▶ in-review ──▶ done
                   │
                   └──▶ needs-human   (escalation: agent comments + pings you)
```

Each transition is an agent action. A PR cannot reach `in-review` until the
e2e gate is green. You apply the final merge.

## Roles

| Role | Input → Output | Model | Human |
|------|----------------|-------|-------|
| PM | Notion/ClickUp PRD → `specs/prd.md` | strong | you, heavily |
| TechLead | PRD + codemap → enriched ticket | strong | you skim |
| Implementer | one ticket + codemap → branch + e2e | cheap | no |
| Reviewer ×N | diff → findings (no memory, fresh each round) | mid | no |

## Build milestones

- [ ] **M0 — Engine scaffold** (this repo): roles, config schema, orchestrator,
      reusable workflow, templates. ← we are here
- [ ] **M1 — Spine on ONE app**: `spec-ready` ticket → Implementer → e2e gate →
      Reviewer loop → PR, fully unattended. Prove it on a real ticket.
- [ ] **M2 — TechLead + codemap**: enrich thin tickets so cheap implementers work.
- [ ] **M3 — PM compiler**: Notion/ClickUp PRD → `specs/prd.md` adapter.
- [ ] **M4 — Generalize**: template repo + adopt a second project; harden escalation.
- [ ] **M5 — PM interface**: dashboard surfacing ticket state + codemap blast radius.

## Open decisions (carry-forward)

- **Guinea-pig app**: which small app/plugin with real e2e tests do we wire first? (blocks M1)
- **Auth in CI**: `ANTHROPIC_API_KEY` (Agent-SDK credit pool as of 2026-06-15) vs
  `CLAUDE_CODE_OAUTH_TOKEN`. Pick before first run.
- **Permission flag**: validate exact `--permission-mode` value on first CI run.
- **Notify channel**: GitHub comment only, or also Slack/push?
