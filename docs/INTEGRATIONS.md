# Integration Architecture

How the four tools in the sales stack connect, with n8n as the central automation hub.

## Overview

```
Twenty CRM  <--n8n-->  Mautic  <--n8n-->  WAHA (WhatsApp)
     \                   |                    /
      \                  |                   /
       +--------  n8n (hub)  ---------------+
```

No native integration exists between Twenty CRM and Mautic. n8n bridges them using its built-in Mautic node and HTTP Request nodes for Twenty's REST API. WAHA connects through n8n as middleware or directly via Mautic's webhook campaign action.

## Twenty <-> Mautic Bidirectional Sync

### Flow A: Twenty -> Mautic (new/updated leads)

**n8n Workflow 1:**
```
[Webhook: POST /twenty-sync]
  -> [Switch: route by event type]
    -> person.created  -> [Mautic: Create Contact] -> [HTTP Request: store Mautic ID back in Twenty]
    -> person.updated  -> [Mautic: Update Contact]
    -> opportunity.updated -> [Mautic: Edit Points / Add to Segment]
```

1. Twenty fires webhook (e.g., `person.created`) to `https://n8n.example.com/webhook/twenty-sync`
2. n8n receives it, maps fields, creates/updates contact in Mautic
3. n8n writes the Mautic contact ID back to Twenty as a custom field (`mauticContactId`)

### Flow B: Mautic -> Twenty (engagement data)

**n8n Workflow 2:**
```
[Mautic Trigger: email_on_open, lead_points_change, form_on_submit]
  -> [Switch: route by event]
    -> email opened     -> [HTTP Request: PATCH Twenty person + create note]
    -> points changed   -> [HTTP Request: PATCH Twenty person update score]
```

1. Mautic Trigger node auto-registers webhooks in Mautic
2. When engagement happens (email open, score change), Mautic notifies n8n
3. n8n uses the `twenty_crm_id` custom field to update the right person in Twenty

## Field Mapping

| Twenty CRM (People) | Mautic (Contacts) | Direction |
|---|---|---|
| `name.firstName` | `firstname` | Bidirectional |
| `name.lastName` | `lastname` | Bidirectional |
| `email.primaryEmail` | `email` | Bidirectional |
| `phone.primaryPhone` | `phone` | Bidirectional |
| `jobTitle` | `position` | Bidirectional |
| `company.name` | `company` | Bidirectional |
| `id` (Twenty) | `twenty_crm_id` (custom) | Twenty -> Mautic |
| `mauticContactId` (custom) | `id` (Mautic) | Mautic -> Twenty |
| `mauticScore` (custom) | `points` | Mautic -> Twenty |

## Cross-Reference ID Strategy

Both systems store each other's ID:
- **Mautic** has a custom field `twenty_crm_id` storing the Twenty person ID
- **Twenty** has a custom field `mauticContactId` storing the Mautic contact ID

This eliminates expensive lookup queries during sync. Deduplication uses **email** as the unique key. Synced records in Mautic get the `twenty-synced` tag.

**Loop prevention:** Skip processing if the update originated from the other system (check if the sync tag/field was just set by the integration itself).

## WAHA <-> Mautic WhatsApp Integration

### Path 1: Direct webhook (simple)

Mautic campaign builder -> "Send a Webhook" action -> WAHA `/api/sendText`:
- URL: `http://waha:3000/api/sendText` (Docker internal)
- Headers: `X-Api-Key: <WAHA_API_KEY>`
- Body: `{"session":"default","chatId":"{contactfield=mobile}@c.us","text":"Hi {contactfield=firstname}!"}`

Limited: no response tracking, no media messages.

### Path 2: n8n middleware (recommended)

**Outbound:** Mautic campaign webhook -> n8n -> transforms data -> WAHA sendText/sendImage -> n8n logs delivery status back to Mautic

**Inbound:** WAHA incoming message webhook -> n8n -> extract phone -> search Mautic contact -> add note/activity to contact timeline

WAHA webhook events configured per-session: `message`, `message.ack`, `session.status`.

## MCP Servers

| Server | Purpose | Config needed |
|--------|---------|---------------|
| `context7` | Library docs (Docker, n8n, etc.) | None (npx) |
| `twenty-crm` | Twenty CRM API (29 tools) | `TWENTY_API_KEY` |
| `mautic` | Mautic API via mantic-MCP (68 tools) | OAuth2 credentials |
| `waha` | WAHA WhatsApp API (63 tools) | `WAHA_API_KEY` |
| `n8n` | n8n workflow API | `N8N_API_KEY` |
| `n8n-docs` | n8n documentation | None |
| `openapi-bridge` | Generic OpenAPI-to-MCP bridge | Swagger spec URL |

The most efficient approach: use **n8n's built-in MCP Server Trigger** to expose unified workflows through a single MCP endpoint that orchestrates all tools.

## Internal Service URLs (Docker network)

Used by n8n and inter-service communication:
- Twenty API: `http://twenty-server:3000/rest/`
- Mautic API: `http://mautic-web:80/api/`
- WAHA API: `http://waha:3000/api/`
- n8n webhooks: `http://n8n:5678/webhook/`
