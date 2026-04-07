# curl Testing Patterns

> Reusable curl snippets for Phase C real-life verification. All examples use
> port 2359 (Docker Compose external mapping). When testing with `npm run
> dev:api` directly, replace 2359 with 3000.

## Setup

```bash
# Set your API key (created via psql -- see phase-c-template.md)
API_KEY="sk_live_test1234567890"
BASE_URL="http://localhost:2359"
```

---

## Auth -- Bearer token authentication

Every authenticated endpoint requires the `Authorization` header:

```bash
curl -H "Authorization: Bearer $API_KEY" $BASE_URL/api/contacts
```

---

## JSON POST -- Creating resources

```bash
# Create a contact
curl -X POST $BASE_URL/api/contacts \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $API_KEY" \
  -d '{"firstName":"Alice","lastName":"Smith","email":"alice@test.com","jobTitle":"CTO"}'
# Expected: 201 Created

# Create a company
curl -X POST $BASE_URL/api/companies \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $API_KEY" \
  -d '{"name":"Acme Corp","domain":"acme.com","industry":"SaaS","employeeCount":50}'
# Expected: 201 Created

# Create a campaign
curl -X POST $BASE_URL/api/campaigns \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $API_KEY" \
  -d '{"name":"Cold Outreach Q1","type":"EMAIL_SEQUENCE","description":"Outreach to US CTOs"}'
# Expected: 201 Created with status DRAFT

# Create a segment with filter rules
curl -X POST $BASE_URL/api/segments \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $API_KEY" \
  -d '{
    "name": "US CTOs",
    "filterRules": {
      "operator": "AND",
      "rules": [
        {"field": "country", "op": "eq", "value": "US"},
        {"field": "jobTitle", "op": "eq", "value": "CTO"}
      ]
    }
  }'
# Expected: 201 Created

# Log an engagement event
curl -X POST $BASE_URL/api/engagements \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $API_KEY" \
  -d '{"contactId":"<CONTACT_UUID>","eventType":"EMAIL_OPENED","channel":"email"}'
# Expected: 201 Created

# Create an opportunity
curl -X POST $BASE_URL/api/opportunities \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $API_KEY" \
  -d '{"title":"Deal with Acme","value":50000,"stage":"prospecting","probability":25}'
# Expected: 201 Created
```

---

## JSON PATCH -- Updating resources

```bash
curl -X PATCH $BASE_URL/api/contacts/<ID> \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $API_KEY" \
  -d '{"jobTitle":"VP Engineering"}'
# Expected: 200 OK with updated resource
```

---

## DELETE -- Soft-deleting resources

```bash
curl -X DELETE $BASE_URL/api/contacts/<ID> \
  -H "Authorization: Bearer $API_KEY"
# Expected: 204 No Content

# Verify soft-delete
curl $BASE_URL/api/contacts/<ID> \
  -H "Authorization: Bearer $API_KEY"
# Expected: 404 Not Found
```

---

## Pagination -- List endpoints

```bash
# Default pagination (page 1, pageSize 50)
curl "$BASE_URL/api/contacts" \
  -H "Authorization: Bearer $API_KEY"

# Custom pagination
curl "$BASE_URL/api/contacts?page=2&pageSize=20" \
  -H "Authorization: Bearer $API_KEY"

# With search
curl "$BASE_URL/api/contacts?search=alice" \
  -H "Authorization: Bearer $API_KEY"

# With sorting
curl "$BASE_URL/api/contacts?sortBy=engagementScore&sortDir=desc" \
  -H "Authorization: Bearer $API_KEY"

# Filter by segment
curl "$BASE_URL/api/contacts?segmentId=<SEGMENT_UUID>" \
  -H "Authorization: Bearer $API_KEY"
```

Response shape for all list endpoints:

```json
{
  "data": [...],
  "meta": { "total": 42, "page": 1, "pageSize": 50 }
}
```

---

## HMAC Signing -- Webhook signature verification

### Cal.com (HMAC-SHA256, header: `x-cal-signature-256`)

```bash
CAL_SECRET="test-cal-secret"
PAYLOAD='{"triggerEvent":"BOOKING_CREATED","payload":{"uid":"booking-123","attendees":[{"email":"alice@test.com","name":"Alice Smith"}]}}'
SIG=$(echo -n "$PAYLOAD" | openssl dgst -sha256 -hmac "$CAL_SECRET" -hex | awk '{print $2}')

curl -X POST $BASE_URL/api/webhooks/cal \
  -H "Content-Type: application/json" \
  -H "x-cal-signature-256: $SIG" \
  -d "$PAYLOAD"
# Expected: 200 {"received":true}
```

### WAHA / WhatsApp (HMAC-SHA512, header: `x-webhook-hmac`)

```bash
WAHA_SECRET="test-waha-secret"
PAYLOAD='{"event":"message.ack","from":"447911123456@c.us","id":"msg-uuid-456","ack":4}'
SIG=$(echo -n "$PAYLOAD" | openssl dgst -sha512 -hmac "$WAHA_SECRET" -hex | awk '{print $2}')

curl -X POST $BASE_URL/api/webhooks/waha \
  -H "Content-Type: application/json" \
  -H "x-webhook-hmac: $SIG" \
  -d "$PAYLOAD"
# Expected: 200 {"received":true}
```

### Email provider (Postmark / Mailgun)

```bash
# Postmark webhook (detected by x-postmark-signature header)
curl -X POST $BASE_URL/api/webhooks/email \
  -H "Content-Type: application/json" \
  -H "x-postmark-signature: <base64-hmac>" \
  -d '{"RecordType":"Open","Recipient":"alice@test.com","MessageID":"msg-123"}'
# Expected: 200 {"received":true}

# Mailgun webhook (detected by x-mailgun-signature header)
curl -X POST $BASE_URL/api/webhooks/email \
  -H "Content-Type: application/json" \
  -H "x-mailgun-signature: <hmac-hex>" \
  -d '{"event":"delivered","recipient":"alice@test.com","message-id":"msg-456"}'
# Expected: 200 {"received":true}
```

---

## Async Jobs -- Pointer pattern

Bulk operations return 202 Accepted with a job ID. Poll for status:

```bash
# Submit bulk contact upsert
RESPONSE=$(curl -s -X POST $BASE_URL/api/contacts/bulk \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $API_KEY" \
  -d '{
    "contacts": [
      {"firstName":"Eve","email":"eve@test.com"},
      {"firstName":"Frank","email":"frank@test.com"}
    ],
    "mode": "create_only"
  }')
# Expected: 202 Accepted

JOB_ID=$(echo "$RESPONSE" | jq -r '.jobId')

# Poll job status
curl $BASE_URL/api/jobs/$JOB_ID \
  -H "Authorization: Bearer $API_KEY"
# Expected: {"jobId":"...","queue":"...","status":"completed","result":{...}}
```

---

## Segment Evaluation -- Triggering async evaluation

```bash
# Trigger evaluation for specific segments
curl -X POST $BASE_URL/api/segments/evaluate \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $API_KEY" \
  -d '{"segmentIds":["<SEGMENT_UUID>"]}'
# Expected: 202 Accepted

# Wait for worker to process
sleep 5

# Check segment members
curl $BASE_URL/api/segments/<SEGMENT_UUID>/contacts \
  -H "Authorization: Bearer $API_KEY"
# Expected: 200 with matching contacts
```

---

## Campaign Enrollment

```bash
# Enroll a contact in a campaign
curl -X POST $BASE_URL/api/campaigns/<CAMPAIGN_ID>/enroll \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $API_KEY" \
  -d '{"contactId":"<CONTACT_UUID>"}'
# Expected: 201 Created with enrollment object, stage "enrolled"

# Re-enroll same contact (expect conflict)
curl -X POST $BASE_URL/api/campaigns/<CAMPAIGN_ID>/enroll \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $API_KEY" \
  -d '{"contactId":"<CONTACT_UUID>"}'
# Expected: 409 Conflict
```

---

## Error Testing -- Expected failures

```bash
# Missing required field (expect 400 VALIDATION_ERROR)
curl -X POST $BASE_URL/api/contacts \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $API_KEY" \
  -d '{}'

# Non-existent ID (expect 404 NOT_FOUND)
curl $BASE_URL/api/contacts/00000000-0000-0000-0000-000000000000 \
  -H "Authorization: Bearer $API_KEY"

# Missing auth header (expect 401 UNAUTHORIZED)
curl $BASE_URL/api/contacts

# Invalid auth header (expect 401 UNAUTHORIZED)
curl $BASE_URL/api/contacts \
  -H "Authorization: Bearer sk_live_invalid"

# Invalid webhook signature (expect 401 INVALID_SIGNATURE)
curl -X POST $BASE_URL/api/webhooks/cal \
  -H "Content-Type: application/json" \
  -H "x-cal-signature-256: invalid_signature_xyz123" \
  -d '{"triggerEvent":"BOOKING_CREATED","payload":{}}'

# Non-existent job ID (expect 404 NOT_FOUND)
curl $BASE_URL/api/jobs/nonexistent-job-id \
  -H "Authorization: Bearer $API_KEY"
```

---

## Health Endpoints (no auth required)

```bash
# Liveness probe
curl $BASE_URL/health
# Expected: {"status":"ok","uptime":...}

# Readiness probe (checks DB + Redis)
curl $BASE_URL/ready
# Expected: {"status":"ready","db":"ok","redis":"ok"}

# Prometheus metrics
curl $BASE_URL/metrics
# Expected: text/plain with HELP, TYPE, and metric lines
curl $BASE_URL/metrics | grep "process_uptime_seconds"
```

---

## Database Verification

After curl testing, verify state directly in PostgreSQL:

```bash
# Check contacts
docker compose exec sales-db psql -U salesengine -d salesengine -c \
  "SELECT id, first_name, email, engagement_score, deleted_at FROM contacts ORDER BY created_at DESC LIMIT 5;"

# Check companies
docker compose exec sales-db psql -U salesengine -d salesengine -c \
  "SELECT id, name, domain, deleted_at FROM companies ORDER BY created_at DESC LIMIT 5;"

# Check engagement events
docker compose exec sales-db psql -U salesengine -d salesengine -c \
  "SELECT id, contact_id, event_type, occurred_at FROM engagement_events ORDER BY created_at DESC LIMIT 5;"

# Check webhook events (idempotency)
docker compose exec sales-db psql -U salesengine -d salesengine -c \
  "SELECT id, provider, provider_event_id, status FROM webhook_events ORDER BY created_at DESC LIMIT 5;"

# Check segment memberships
docker compose exec sales-db psql -U salesengine -d salesengine -c \
  "SELECT segment_id, contact_id, added_by, removed_at FROM contact_segment_memberships ORDER BY added_at DESC LIMIT 5;"
```
