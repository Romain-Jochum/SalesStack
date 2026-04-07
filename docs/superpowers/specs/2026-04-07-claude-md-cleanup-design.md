# Design: CLAUDE.md Cleanup — Single Source of Truth for Git Practices

**Date:** 2026-04-07
**Status:** approved

---

## Problem

Four files currently define or repeat git/commit best practices:

1. `CLAUDE.md` — Git & PR Practices section (prose)
2. `docs/superpowers/plans/phase1/shared/commit-conventions.md` — detailed reference (duplicates CLAUDE.md)
3. `.claude/skills/task-implementation-standard/SKILL.md` — Phase D defines its own commit format (`<type>/<TASK-ID>/<module>: ...`) that conflicts with CLAUDE.md
4. `.claude/skills/plan-restructuring/SKILL.md` — references commit-conventions.md as a generated output

Additionally, CLAUDE.md is too dense: it carries Port Allocation, Environment Variables, MCP Servers, Documentation pointers, and Architecture prose that belong in README.md or plan docs — not in the agent-facing instructions file.

---

## Goal

- **CLAUDE.md** becomes the single, lean source of truth for all agent behavior rules
- **Other files** reference CLAUDE.md rather than defining their own rules
- Style modeled after the Race Trophy CLAUDE.md: ALWAYS/NEVER bullets, no prose explanations

---

## Changes

### 1. CLAUDE.md — Full Rewrite

Drop: Port Allocation table, Environment Variables, MCP Servers, Documentation pointers, Architecture prose.

Keep and rewrite as bullet rules: Tech Stack, Commands, Project Structure tree.

Add new behavioral sections: START, CODE ANALYSIS, TYPESCRIPT, CODE ARCHITECTURE, SECURITY, TESTING, GIT, PULL REQUESTS.

**New structure:**

```
# Sales Engine
[one-line description]

## Tech Stack
[concise pinned-version list]

## Commands
[existing bash block, unchanged]

## Project Structure
[existing tree, unchanged]

## START
- ALWAYS enter plan mode before implementing a feature
- ALWAYS explore and load relevant skills before starting work
- If a plan task: ALWAYS read CONTEXT.md before touching code
- If no plan: ALWAYS explore existing patterns and files before writing anything new
- If no relevant skill exists, ask whether to search for one

## CODE ANALYSIS
- ALWAYS read existing code before modifying anything
- ALWAYS follow established patterns for consistency
- NEVER assume structure — read it first

## TYPESCRIPT
- ALWAYS use strong typing on every interface, function, and return type
- NEVER use `any` — use `unknown` and narrow
- NEVER use `@ts-ignore` without a `// @ts-ignore — [reason]` comment
- NEVER use `console.log` — use the Pino logger

## CODE ARCHITECTURE
- Vertical slice per module: schemas.ts → service.ts → routes.ts
- Services throw typed errors — NEVER catch errors in route handlers, let error middleware handle it
- Error response shape: { error: { code, message, details? } } — codes: VALIDATION_ERROR, NOT_FOUND, UNAUTHORIZED, RATE_LIMITED, INTERNAL_ERROR
- tenantId on every model, every query — unique constraints scoped to tenant
- Long operations: return 202 + jobId, client polls GET /api/jobs/:jobId
- Any read-then-write sequence belongs in a $transaction — never split across two queries
- All required env vars validated at startup — process exits immediately if any are missing
- One Dockerfile, two roles — ROLE env var selects API or worker entrypoint
- NEVER expose ports publicly — always bind to 127.0.0.1
- ALWAYS use `docker compose` (v2), not `docker-compose` (v1)
- All inter-service traffic uses Docker service names (e.g. redis://sales-redis:6379)
- Exact dependency pinning — no ^ or ~ in package.json

## SECURITY
- NEVER log secrets, API keys, or PII at any log level
- NEVER process a webhook payload before verifying its HMAC signature
- ALWAYS validate API keys via SHA-256 hash comparison — never store raw keys
- ALWAYS test every endpoint without auth and confirm it returns 401
- Rate limiting: 500 req/min per IP — requests exceeding the limit return 429

## TESTING
- ALWAYS write a failing test before implementation — RED → GREEN → REFACTOR
- NEVER commit code that breaks existing tests
- Coverage targets (enforced in CI): 80% for business logic, 60% for plumbing
- NEVER mock PostgreSQL or Redis in integration tests — use real containers (testcontainers)
- ALWAYS test at least one unhappy path per endpoint or handler

## GIT
- NEVER mention Claude, AI, agent, or co-authored in commits or PRs
- Commit at each tiny implementation change — one logical change per commit
- Conventional Commits: feat:, fix:, chore:, docs:, refactor:, test:, ci:
- Subject: max 50 chars, imperative mood, lowercase after prefix, no trailing period
- NEVER use emojis in commits
- Branch naming: <type>/<TASK-ID>-<kebab-slug> e.g. feature/P1-007-contacts-crud
- GitHub Flow: branch off main, merge back to main
- NEVER bypass pre-commit hooks with --no-verify

## PULL REQUESTS
- ALWAYS keep PRs small — one task per PR, one branch per task
- Title: <TASK-ID>: short description
- Body: one-line summary → ## Changes (bullets) → ## Testing (at least one curl command showing happy path + observed response)
- Rebase and merge into main — atomic commits are the audit trail, never squash
- Before merge: rebase onto latest main, force-push with --force-with-lease, CI green
- NEVER mention Claude, AI, agent, or co-authored in PR title or body
- NEVER over-explain — no walls of text, no checkbox checklists
```

---

### 2. commit-conventions.md — Add Reference Banner

Add at the very top of `docs/superpowers/plans/phase1/shared/commit-conventions.md`:

```
> **Source of truth:** `CLAUDE.md → ## GIT`. This file is a detailed reference only.
> If anything conflicts, CLAUDE.md wins.
```

No other changes to the file.

---

### 3. task-implementation-standard/SKILL.md — Replace Phase D Commit Format

In Phase D, replace the custom format block:

```
<type>/<TASK-ID>/<module>: <imperative subject under 50 chars>
<body wrapped at 72 ...>
```

With:

```
Follow CLAUDE.md → ## GIT for commit conventions. Commits are atomic —
one tiny logical change per commit, not one per phase or task step.
```

Remove the example commit `feat/P1-007/contacts: add upsert by email with tenant scoping`
and its explanation. The surrounding Phase D text (JSDoc, inline comments, test summary,
push-after-commit) stays untouched.

---

### 4. plan-restructuring/SKILL.md — No Change

This skill references `shared/commit-conventions.md` only as a generated output file
when restructuring a plan. No rules are defined here. No change needed.

---

## What Moves Out of CLAUDE.md (to README.md)

- Port Allocation table
- Environment Variables (required + optional)
- MCP Servers list
- Documentation pointers (Phase 1 plan path, Phase 2/3 architecture path, decisions/)

These already exist in `docs/superpowers/plans/phase1/CONTEXT.md`. README.md is
the right home for the human-facing reference; CLAUDE.md is agent behavior only.

---

## Out of Scope

- `docs/superpowers/plans/phase1/CONTEXT.md` — not touched
- `plan-restructuring/SKILL.md` — not touched
- Docker skills, other skills — not touched
- README.md content migration — tracked separately; dropping from CLAUDE.md is the
  priority, README.md authoring is a follow-up

---

## Success Criteria

1. CLAUDE.md has no prose paragraphs — only bullet rules and code blocks
2. No git/commit rule exists in commit-conventions.md or task-implementation-standard
   that is not traceable back to CLAUDE.md
3. A new agent reading only CLAUDE.md knows: how to start work, how to write code,
   how to test it, how to commit it, and how to open a PR
