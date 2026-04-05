# Decision: BullMQ FlowProducers for Research Pipeline

**Status:** Decided (Phase 2)  
**Date:** 2026-04-05  
**Stakeholders:** Architecture, backend engineering

---

## Decision

Use **BullMQ FlowProducers** to orchestrate the research pipeline (SCRAPE → PARSE → ENRICH stages) instead of:
- Chaining independent jobs via event listeners
- A single monolithic worker that does all three stages
- n8n-style workflow engine

---

## Context

Phase 2 research engine has a dependency graph:
```
SCRAPE (fetch raw HTML from URL)
    ↓ (raw HTML pointer)
PARSE (convert HTML to JSON/markdown)
    ↓ (parsed content pointer)
ENRICH (LLM extract signals: decision-makers, revenue, intent)
    ↓
ResearchJob COMPLETED
```

Each stage must wait for the previous one. Each stage can fail independently. If PARSE fails, ENRICH should not run.

Need a queueing primitive that models this dependency graph and handles failure atomically.

---

## Rationale

### ✅ Why FlowProducers

**Dependency Graph Modeling**
FlowProducers represent parent jobs with child jobs. A parent job is only "completed" when all its children succeed:

```typescript
const researchFlow = await flowProducer.add({
  name: 'research-pipeline',
  data: { researchJobId: '...' },
  children: [
    { name: 'scrape', data: { sourceUrl: '...' }, opts: { priority: 10 } },
    { name: 'parse', data: { sourceKey: '...' }, opts: { priority: 5 } },
    { name: 'enrich', data: { parsedKey: '...' }, opts: { priority: 3 } },
  ],
  opts: { ...jobOpts }
})
// Parent waits. Child 1 completes → queue child 2. Child 2 completes → queue child 3.
// If child 2 fails → parent stays RUNNING until retry succeeds.
```

This is enforced by BullMQ's flow logic. No custom event listeners needed.

**Atomic Failure Handling**
If PARSE fails:
- Parent remains in `RUNNING` state
- ENRICH is never queued
- Retry automatically retries PARSE (not SCRAPE)
- On success, ENRICH is queued automatically

Without FlowProducers, you need:
```typescript
// ❌ Fragile: what if Redis restarts between events?
worker.on('completed', async (job) => {
  if (job.name === 'scrape') {
    await parseQueue.add('parse', job.returnvalue)
  }
  if (job.name === 'parse') {
    await enrichQueue.add('enrich', job.returnvalue)
  }
})
```

This pattern can lose jobs if the process crashes between `completed` event and `add()`.

**Visibility into Pipeline State**
One ResearchJob ID shows the entire pipeline state:

```typescript
const flow = await flowProducer.getFlow(parentJobId)
// Returns:
{
  id: parentJobId,
  name: 'research-pipeline',
  state: 'RUNNING',
  data: { researchJobId: '...' },
  children: [
    { id: child1, name: 'scrape', state: 'COMPLETED', ... },
    { id: child2, name: 'parse', state: 'FAILED', ... },
    { id: child3, name: 'enrich', state: 'WAITING', ... },  // hasn't started yet
  ]
}
```

No need to query three separate queues or join tables. The flow tree is the source of truth.

**Memory Efficiency**
Each job's data is a MinIO key pointer (~100 bytes):
```typescript
{ sourceKey: 'raw-content/abc123.html', contentBucket: 'sales-research-phase2' }
```

Job data is never the raw HTML (10–100KB). Each stage worker downloads from MinIO as needed. Parent FlowProducer holds the dependency graph (small), not the payloads.

At 10K concurrent research jobs: ~1MB Redis (pointers), not 100GB.

### ⚠️ Trade-Offs (Minimal)

**Operational Complexity (Acceptable)**
- FlowProducers are a BullMQ feature; documented in BullMQ docs
- One-time learning curve during Phase 2 implementation
- Pays for itself with visibility + atomicity

**Testing Complexity (Manageable)**
- Testing flows requires mocking BullMQ (use `jest-bull` or `bull-board`)
- Unit tests can mock individual workers
- Integration tests run against real Redis (like Phase 1 tests)

**Limited to Fastify/Node.js**
- FlowProducers are a BullMQ concept; not portable to other languages
- Acceptable: this backend is Node.js-only. If we ever port to another language, we'll choose a different orchestrator for that language.

---

## Alternatives Considered

### Event Listeners (Rejected)
```typescript
// ❌ Fragile pattern
engagementQueue.on('completed', async (job) => {
  if (job.name === 'scrape-html') {
    const parseJob = await parseQueue.add(...)
    // What if the process crashes here? parseJob is created but researchJob thinks it's still scraping.
  }
})
```

**Problems:**
1. Race conditions if process crashes between event and `add()`
2. No built-in retry logic; must implement manually
3. Querying pipeline state requires joining three queue tables + ResearchJob table
4. If Redis restarts, event listeners are cleared (jobs already in queues will orphan)

---

### Single Monolithic Worker (Rejected)
```typescript
// ❌ All in one step
worker.process('research', async (job) => {
  const html = await scrape(job.data.url)        // stage 1
  const parsed = await parse(html)                // stage 2
  const enriched = await enrich(parsed, gpt4)     // stage 3
  return enriched
})
```

**Problems:**
1. No partial failure recovery: if enrich fails after 10 min of scraping, retry re-scrapes (wasteful)
2. Worker timeout risk: all three stages share one timeout; if scraping takes 5 min, total timeout must be >5 min, even if enrich only needs 30 sec
3. No visibility into which stage is slow
4. Hard to scale: can't run 10 SCRAPE workers + 5 PARSE workers + 3 ENRICH workers independently

---

### Temporal.io or Durable Functions (Rejected)
- ✓ Powerful orchestration primitives
- ✗ Adds external dependency (Temporal server or equivalent)
- ✗ Overkill for three-stage pipeline
- ✓ Consider for Phase 3 if orchestration becomes more complex (e.g., branching, loops, human approval)

---

### n8n Native Workflows (Rejected)
- ✓ Visual workflow builder (good for marketing)
- ✗ n8n is the outreach executor, not the research orchestrator
- ✗ Would require n8n to call back into the sales-engine API, then sales-engine to call back into n8n (circular dependency)
- **Decision:** Keep separation of concerns. n8n orchestrates outreach. Sales-engine orchestrates research.

---

## Implementation (Phase 2)

**Setup (core/flows.ts, new file)**
```typescript
import { FlowProducer } from 'bullmq'
import { redis } from './redis'

export const flowProducer = new FlowProducer({
  connection: redis,
  defaultJobOptions: {
    removeOnComplete: true,
    removeOnFail: { count: 100 },  // keep recent failures for debugging
  }
})

export async function createResearchFlow(researchJobId: string, targetUrl: string) {
  return flowProducer.add({
    name: 'research-pipeline',
    data: { researchJobId, targetUrl },
    children: [
      { name: 'scrape', data: { url: targetUrl }, opts: { priority: 10 } },
      { name: 'parse', data: { /* will be set by scrape worker */ }, opts: { priority: 5 } },
      { name: 'enrich', data: { /* will be set by parse worker */ }, opts: { priority: 3 } },
    ]
  })
}
```

**Workers (src/workers/index.ts, extended)**
```typescript
// Phase 2 additions
import { createScrapeWorker } from '../modules/research-jobs/scrape.worker'
import { createParseWorker } from '../modules/research-jobs/parse.worker'
import { createEnrichWorker } from '../modules/research-jobs/enrich.worker'

// ... existing Phase 1 workers ...

// Phase 2 workers
workers.push(
  createScrapeWorker(),  // queue:research:scrape
  createParseWorker(),   // queue:research:parse
  createEnrichWorker(),  // queue:research:enrich
)
```

**Phase 1 Note**
Phase 1 defines queue name constants but does NOT instantiate the research queues:
```typescript
// Phase 1 (core/queues.ts)
export const QUEUE_NAMES = {
  ENGAGEMENT_PROCESS: 'queue:engagement:process',
  SEGMENT_EVALUATE: 'queue:segment:evaluate',
  SYNC_EXPORT: 'queue:sync:export',
  // Phase 2 (defined, not instantiated):
  RESEARCH_SCRAPE: 'queue:research:scrape',
  RESEARCH_PARSE: 'queue:research:parse',
  RESEARCH_ENRICH: 'queue:research:enrich',
}
```

Phase 2 will instantiate the research queues and the FlowProducer.

---

## Metrics

Monitor:
- Flow completion rate (% of research jobs that complete successfully)
- Retry rate per stage (high retries → investigate stability)
- Duration per stage (scrape vs. parse vs. enrich — which is slowest?)
- Queue depths (are children queuing faster than parents completing?)

---

## Testing Strategy

**Unit Tests**
- Mock individual workers (`scrapeWorker`, `parseWorker`, `enrichWorker`)
- Test each worker in isolation (input → output)
- No FlowProducer involvement

**Integration Tests**
- Spin up real Redis
- Create a FlowProducer
- Dispatch a test flow with real workers (but mocked API calls: scrape → fake HTML, etc.)
- Assert flow state transitions (parent: WAITING → RUNNING → COMPLETED)

**E2E Test (Phase 2 Smoke Test)**
- Real URL (e.g., news article)
- Real FireCrawl API (or mock if quota concerns)
- Full pipeline: scrape → parse → enrich
- Assert DataLineage records written
- Assert MinIO objects stored

---

## Approval

- [ ] Engineering lead
- [ ] Backend architect
- [ ] Solo maintainer

---

## Related Decisions

- `001-minio-not-s3.md` — Why MinIO stores artifacts (not BullMQ Redis)
- `003-pointer-pattern-webhooks.md` — Why jobs carry pointers, not payloads
