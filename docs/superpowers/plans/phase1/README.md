# Phase 1 Implementation Plan

## Purpose

Phase 1 delivers a Fastify + PostgreSQL backend that serves as the system of record for contacts, companies, campaigns, and engagements — replacing Mautic — with a REST API that n8n can call immediately. Tech stack: Node.js 24 LTS, Fastify v5, Prisma v7, PostgreSQL 18, Redis 7, BullMQ v5.71+.

## How to use this plan

Agents read `CONTEXT.md` + `shared/` + their specific task file, nothing else. They do NOT need to read other task files or the original monolith. Each task file is self-contained with its own dependencies listed.

## Dependency graph

```
Task 0 (Pre-setup)
    ↓
Task 1 (Scaffolding) → Task 2 (Prisma) → Task 2.5 (DB/Redis launch) → Task 3 (Core Infra) → Task 4 (Middleware)
                    ┌────────────────────────────────┬──────────────────────┐
                    ↓                                ↓                      ↓
                Task 5 (Health)    Task 6 (Contacts) + Task 7 (Companies)   Task 13 (Jobs)
                                        ↓                                   Task 12 (Opportunities)
                                   Task 8 (Segments)
                                        ↓
                                   Task 9 (Campaigns)
                                        ↓
                                  Task 10 (Engagements)
                                        ↓
                                  Task 11 (Webhooks)
                                        ↓
                Task 14 (Workers) → Task 15 (Server)
                                        ↓
                Task 16 (Docker) → Task 17 (Docker Compose) + Task 18 (Config)
                                        ↓
                                   Task 19 (Env Vars)
                                        ↓
                                   Task 20 (CI/CD)
                                        ↓
                Task 21 (Smoke Test + n8n + README)
```

## Parallelization opportunities

- Tasks 5 + 6 + 7 + 12 + 13 can all start after Task 4
- Tasks 17 + 18 can run in parallel after Task 16

## Status

See [STATUS.md](STATUS.md) for current progress.
