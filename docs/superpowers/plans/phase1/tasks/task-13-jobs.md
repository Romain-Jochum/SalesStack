# Task 13: Jobs Status Module

**Depends on:** 03
**Parallel with:** 05, 06, 07, 12
**Blocks:** none
**Outputs:** `backend/src/modules/jobs/schemas.ts`, `modules/jobs/routes.ts`
**Verifies:** GET /api/jobs/:jobId returns status, state, progress, result, error, timestamp
**Estimated context:** ~120 lines

## Intent

Implement the jobs status endpoint that enables the pointer pattern for long-running operations. When any module returns `202 Accepted` with a job ID (e.g., bulk contact upsert, segment rebuilds, campaign exports), clients poll `GET /api/jobs/:jobId` to check progress. This endpoint searches all BullMQ queues (engagement, segment, export) for the given job ID and returns its current state, progress percentage, result (if completed), or error (if failed), along with timestamps. The jobs module is intentionally minimal -- no service layer or Prisma models -- since it reads directly from BullMQ queue state.

## Prerequisites check

- Task 03 (core infrastructure) is committed: `queues.ts` exports `engagementQueue`, `segmentQueue`, and `exportQueue`.
- `sales-db` and `sales-redis` containers are running and healthy.
- BullMQ queues are configured and connected to Redis.

## Steps

### Step 13.1: Create `backend/src/modules/jobs/routes.ts`

> See `shared/tdd-workflow.md` for the general RED-GREEN-REFACTOR pattern.

```typescript
import { FastifyPluginAsync } from 'fastify'
import { engagementQueue, segmentQueue, exportQueue } from '../../core/queues'
import { Queue } from 'bullmq'

const ALL_QUEUES: Queue[] = [engagementQueue, segmentQueue, exportQueue]

const jobsPlugin: FastifyPluginAsync = async (fastify) => {
  fastify.get('/api/jobs/:jobId', async (request, reply) => {
    const { jobId } = request.params as { jobId: string }

    // Search all queues for the job
    for (const queue of ALL_QUEUES) {
      const job = await queue.getJob(jobId)
      if (!job) continue

      const state = await job.getState()
      const progress = job.progress

      return reply.send({
        jobId: job.id,
        queue: queue.name,
        status: state,
        progress: typeof progress === 'number' ? progress : undefined,
        result: state === 'completed' ? job.returnvalue : undefined,
        error: state === 'failed' ? job.failedReason : undefined,
        createdAt: new Date(job.timestamp).toISOString(),
        completedAt: job.finishedOn ? new Date(job.finishedOn).toISOString() : undefined,
      })
    }

    return reply.code(404).send({ error: { code: 'NOT_FOUND', message: 'Job not found' } })
  })
}

export default jobsPlugin
```

### Step 13.2: Real-life verification (Phase C)

See `shared/phase-c-template.md` for the general pattern. See `shared/curl-testing-patterns.md` for curl conventions.

With the dev server and worker running (`npm run dev:api` and `npm run dev:worker`), test the job status endpoint:

```bash
API_KEY="sk_live_test1234567890"

# Test 1: Queue a bulk contact upsert job (from Task 6)
RESPONSE=$(curl -s -X POST http://localhost:3000/api/contacts/bulk \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "contacts": [
      {"firstName":"Eve","email":"eve@test.com"},
      {"firstName":"Frank","email":"frank@test.com"}
    ],
    "mode": "create_only"
  }')
# Expected: 202 Accepted

JOB_ID=$(echo "$RESPONSE" | jq -r '.jobId')
echo "Job ID: $JOB_ID"

# Test 2: Check job status immediately (should be waiting or processing)
curl http://localhost:3000/api/jobs/$JOB_ID \
  -H "Authorization: Bearer $API_KEY"
# Expected: 200 with status "waiting", "processing", or "completed"
# Example: {"jobId":"bulk-xyz","queue":"queue:engagement:process","status":"processing"...}

# Test 3: Wait for job to complete
sleep 3

# Check status again (should be completed)
curl http://localhost:3000/api/jobs/$JOB_ID \
  -H "Authorization: Bearer $API_KEY"
# Expected: 200 with status "completed", result object present

# Test 4: Non-existent job (unhappy path)
curl http://localhost:3000/api/jobs/nonexistent-job-id \
  -H "Authorization: Bearer $API_KEY"
# Expected: 404 Not Found
```

Specific verifications for this task:

- [ ] GET /api/jobs/:jobId returns job status when job exists
- [ ] Job status reflects actual BullMQ queue state (waiting/processing/completed)
- [ ] Completed job returns result object
- [ ] Non-existent job returns 404
- [ ] Endpoint works with jobs from engagement queue
- [ ] Logs show structured request/response entries

## Commit

```bash
git add backend/src/modules/jobs/
git commit -m "feat: add job status endpoint (GET /api/jobs/:jobId) with Phase C verification"
```

See `shared/commit-conventions.md` for formatting rules.
