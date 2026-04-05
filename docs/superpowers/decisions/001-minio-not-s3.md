# Decision: MinIO (Self-Hosted) vs. AWS S3

**Status:** Decided (Phase 2)  
**Date:** 2026-04-05  
**Stakeholders:** Architecture, DevOps, Solo maintainer

---

## Decision

Use **MinIO** (self-hosted, Docker-deployed) for Phase 2 research artifact storage instead of AWS S3, managed equivalents (DigitalOcean Spaces, Backblaze B2), or cloud-native storage.

---

## Context

Phase 2 research engine produces large artifacts:
- Raw HTML (10–100KB per page)
- Parsed JSON/markdown (~1–10KB compressed per page)
- LLM embeddings (vectors, future)
- Screenshots/PDFs (varies)

At the outset, estimated volume: 10K–50K research jobs/month. Over a year: ~500M–2B bytes of storage. Need a storage backend that is:
1. Cost-effective for low-volume, self-hosted operation
2. Fully under the operator's control (audit trail, data locality)
3. Replaceable without code changes if we later choose AWS

---

## Rationale

### ✅ Why MinIO

**Self-Hosted Deployment Model**
This stack runs on a single Linux VM via Docker Compose. Adding an S3 dependency introduces:
- External cloud account (AWS, DigitalOcean, Backblaze)
- IAM role setup + credential rotation
- Billing integration and egress cost tracking
- Operator must monitor consumption (no risk of runaway costs, but adds operational toil)

MinIO runs in the same Docker network as the sales-engine backend. No external dependencies, no billing surprises.

**S3-Compatible Interface (Lock-In Escape Hatch)**
MinIO implements the S3 API. If we later need to scale to AWS S3:
1. No code changes required (assuming we abstract storage ops behind an interface)
2. Change one env var: `MINIO_ENDPOINT=https://s3.amazonaws.com`
3. Existing bucket and object names work as-is

This is future-proofing: we get self-hosted simplicity today and a clear migration path tomorrow.

**Complete Audit Trail Ownership**
Raw HTML, parsed content, LLM prompts/outputs are stored locally:
- No third-party data retention concerns
- Full history available for debugging (e.g., "what did the FireCrawl API return on 2026-04-10?")
- Can snapshot `volumes/sales-minio` for disaster recovery (operator's responsibility, but fully under their control)

**Docker Compose Profile Isolation**
MinIO is activated only with `--profile phase2`:
- Phase 1 developers: `docker compose up` (no MinIO, zero overhead)
- Phase 2 developers: `docker compose --profile phase2 up` (MinIO included)

Adds zero complexity to Phase 1 iteration.

### ⚠️ Trade-Offs (Accepted)

**Disk Space Becomes the Bottleneck**
- MinIO stores everything on the VM's disk
- Scaling beyond ~1TB requires adding storage (NFS, larger VM, etc.)
- Mitigated by: `ResearchSource.byteSize` tracking — can query "how much storage are we using per research type?"

**No CDN or Geo-Redundancy**
- S3 with CloudFront offers low-latency reads globally
- MinIO serves from single VM
- Acceptable: Phase 2 reads are back-office (not user-facing), latency not critical
- Future: Phase 3 can revisit if user-facing retrieval becomes necessary

**Backup is the Operator's Responsibility**
- S3 has multi-region replication and automatic redundancy
- MinIO is a single point of failure if the VM dies
- Mitigated by: backup strategy must be documented (daily snapshots of `volumes/sales-minio` to external storage)
- Not a blocker: solo-maintained tools often rely on operator discipline

**Learning Curve (Minimal)**
- Team may be unfamiliar with MinIO
- Offset by: MinIO API is identical to S3, existing docs apply
- One-time cost during Phase 2 setup

---

## Alternatives Considered

### AWS S3 (Rejected)
- ✗ Requires AWS account + billing setup (friction for solo-maintained tool)
- ✗ Egress costs add up (especially during Phase 2 heavy development — lots of re-research)
- ✓ Mature, battle-tested, scales infinitely
- ✓ Multi-region replication included
- **Decision:** Too much operational overhead for Phase 2. Use MinIO today, migrate to S3 in Phase 3 if needed.

### DigitalOcean Spaces (Rejected)
- ✗ Still an external dependency (cloud account, billing)
- ✗ Egress charges apply
- ✓ Simpler setup than AWS
- **Decision:** MinIO solves this better for self-hosted operation.

### Backblaze B2 (Considered)
- ✓ Cheap egress (cheaper than S3)
- ✗ Still external (account, billing, lock-in)
- **Decision:** MinIO preferred for ownership.

### Local Disk Only (Rejected)
- ✗ No redundancy, no replication, fragile
- ✗ Doesn't scale (hit filesystem limits)
- **Decision:** MinIO adds resilience without complexity.

---

## Implementation

**Phase 1 (Preparation)**
- MinIO service defined in docker-compose.yml (profile: `phase2`)
- `sales-minio-data` volume mapped to `volumes/sales-minio`
- Env vars: `MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY` in `.env`
- Health check: `/minio/health/live` endpoint

**Phase 2 (Usage)**
- `ResearchSource` model includes `contentKey` and `contentBucket` fields (pointers)
- `sources` module implements `uploadToMinIO()` and `downloadFromMinIO()` functions
- Workers: upload parsed content → get key/bucket → store pointer in DB
- APIs: `GET /api/sources/:id/content` streams from MinIO

**Phase 3+ (Future Migration, if needed)**
- To migrate to S3: 1) Change `MINIO_ENDPOINT` env var, 2) Create S3 bucket with same structure, 3) Sync `volumes/sales-minio` → S3 bucket

---

## Metrics

Monitor:
- `volumes/sales-minio` disk usage (should grow linearly with research volume)
- MinIO API latency (typical: <100ms for upload, <200ms for download)
- Research job failure rate (high failure → investigate MinIO connectivity)

If disk usage exceeds 80% capacity: trigger operator alert for capacity planning.

---

## Approval

- [ ] Engineering lead
- [ ] DevOps / infrastructure owner
- [ ] Solo maintainer

---

## Related Decisions

- `002-flowproducers-research-workflows.md` — Why BullMQ FlowProducers orchestrate the research pipeline
- `003-pointer-pattern-webhooks.md` — Why payloads are stored in DB, jobs carry only IDs
