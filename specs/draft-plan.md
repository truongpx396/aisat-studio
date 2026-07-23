# AISAT-STUDIO — Draft Plan: Later-Phase Design Notes (Phase 2+)

**Status**: Holding document for review · **Scope**: Phase 2 and later

This file collects the **later-phase (Phase 2+) plan and design material** that was
previously kept inside the Phase 1 MVP package at
[specs/001-contextengine-mvp/](./001-contextengine-mvp/). It was extracted here so the MVP
package stays clean and focused on **Phase 1 (Core App)**, while the future-phase plans are
preserved in one place for later phase planning. Nothing here is scheduled or implemented;
it is design intent to be revisited when the corresponding phase is planned.

> **Phase map:** Phase 1 = Core App · **Phase 2 = Evaluation Suite (+ Headroom eval) &
> Billing/Payments & AI Response Rating & Workspace Mind Map & Enterprise Knowledge
> Layer** · Phase 3 = Automated security red-teaming · **Phase 4 = Scale & Resilience
> Hardening**.

The Phase 1 spec, plan, research, data-model, contracts, and tasks remain the source of
truth for what ships now — see [specs/001-contextengine-mvp/spec.md](./001-contextengine-mvp/spec.md)
"Out of Scope" for the authoritative deferral list. The inline Phase-1 rationale that
merely *mentions* later phases (the scale-forward seams in research §14–§15, the deferral
notes in research §12/§17, etc.) intentionally stays in the Phase 1 docs, because it
explains Phase-1 scoping decisions.

---

## Phase 2 Billing and Payments

**Original title**: Phase 2 Design: Billing & Payments (Stripe / Polar / PayPal)
**Date**: 2026-06-18 | **Plan**: [plan.md](./001-contextengine-mvp/plan.md) | **Status**: Design draft (Phase 2 — out of Phase 1 scope per [spec.md](./001-contextengine-mvp/spec.md) "Out of Scope")

This document specifies the **additive** layer that turns the Phase 1 credit-metering backbone into a monetized, provider-backed billing system. Nothing here changes credit *consumption*: credits remain the single internal unit, decoupled from pricing. A payment provider only converts fiat → credits (one-time top-up) or grants a recurring credit allotment (subscription), then appends a `credit_ledger` row. The consumption hot path (Redis `DECRBY` + outbox + ledger) is untouched.

Layer legend: **K** = kernel (template-level, reusable across products) · **P** = product-specific. All new tables follow the Phase 1 conventions: UUID v7 PKs, `workspace_id NOT NULL` + RLS on tenant-scoped tables, ISO-8601 UTC timestamps, integer money (no floats).

### Design principles

1. **Provider-agnostic core, thin adapters.** A `PaymentProvider` port (Go kernel `billing/`) exposes `CreateCheckout`, `CreatePortalSession`, `VerifyWebhook`, `ParseEvent`, `FetchSubscription`. Stripe, Polar, and PayPal are interchangeable adapters behind it. No product code imports a provider SDK directly.
2. **Money is integer minor units.** All fiat amounts are `BIGINT` minor units (cents) + an ISO-4217 `currency` CHAR(3). Reuses the `cost_usd_micros BIGINT` precedent from [data-model.md](./001-contextengine-mvp/data-model.md). Never floats.
3. **Webhooks are the source of truth for fulfillment.** Credits are granted on a verified `payment_succeeded` / `invoice_paid` webhook, never optimistically on checkout return. Checkout return only redirects the UI.
4. **Idempotent everywhere.** Provider event IDs dedup in `payment_events`; credit grants reuse the existing `credit_ledger.idem_key UNIQUE` guarantee (SC-006). Replayed webhooks are no-ops.
5. **Signature verification is mandatory (CRITICAL).** Every webhook is HMAC/signature-verified before any parsing or side effect (security ruleset AP4: *Webhook Without Signature Verification = CRITICAL*). Unverified payloads are rejected with `400` and logged, never processed.
6. **Grants flow through the existing outbox.** A purchase publishes the same `billing.deduct`-family path (a new `billing.grant.<ws>` subject) so the durable ledger remains the single audit trail.

### New / extended entities

#### `plans` (K) — supersedes the Phase 1 stub
A purchasable product (credit pack or subscription tier).
- `id`, `code` (unique slug, e.g. `pro_monthly`, `pack_10k`), `name`, `description`
- `kind` (`one_time` | `subscription`)
- `price_minor` BIGINT, `currency` CHAR(3) (ISO-4217)
- `credit_allotment` INT (credits granted per purchase / per billing period)
- `billing_interval` (`month` | `year` | NULL for `one_time`)
- `is_active` BOOL, `sort_order` INT, `created_at`, `updated_at`
- Provider price mapping lives in `plan_provider_prices` (below), not here — one plan can map to a Stripe price, a Polar product, and a PayPal plan simultaneously.
- Rules: `credit_allotment` is the *only* coupling between fiat and credits; changing a price never affects already-granted credits.

#### `plan_provider_prices` (K)
Maps one logical `plan` to each provider's external price/product/plan ID.
- `id`, `plan_id` → `plans`, `provider` (`stripe` | `polar` | `paypal`), `provider_price_id` TEXT, `created_at`
- `UNIQUE (provider, provider_price_id)` and `UNIQUE (plan_id, provider)`
- Rules: lets the same catalog entry be sold through any provider; the adapter resolves the right `provider_price_id` at checkout.

#### `billing_customers` (K)
Links a workspace (the billing entity) to a provider customer record.
- `id`, `workspace_id` → Workspace, `provider` (`stripe` | `polar` | `paypal`), `provider_customer_id` TEXT, `created_at`, `updated_at`
- `UNIQUE (workspace_id, provider)` and `UNIQUE (provider, provider_customer_id)`
- Rules: the workspace is the unit of billing (matches `workspace_credits`). A workspace may have at most one customer record per provider.

#### `subscriptions` (K) — supersedes the Phase 1 stub
An active recurring entitlement.
- `id`, `workspace_id` → Workspace, `plan_id` → `plans`, `provider`, `provider_subscription_id` TEXT
- `status` (`trialing` | `active` | `past_due` | `paused` | `canceled` | `incomplete` | `incomplete_expired`)
- `current_period_start`, `current_period_end`, `cancel_at_period_end` BOOL
- `created_at`, `updated_at`, `canceled_at`
- `UNIQUE (provider, provider_subscription_id)`
- Rules: status is driven exclusively by webhooks. Each `invoice_paid` for a subscription grants `plan.credit_allotment` credits via a ledger row keyed by the invoice ID (idempotent renewal grant).

#### `payments` (K)
A fiat transaction record (one-time top-up or a subscription invoice), kept for accounting, receipts, refunds, and provider reconciliation.
- `id`, `workspace_id` → Workspace, `provider`, `provider_payment_id` TEXT (PaymentIntent / order / invoice ID)
- `plan_id` → `plans` (nullable for ad-hoc), `kind` (`one_time` | `subscription_invoice`)
- `amount_minor` BIGINT, `currency` CHAR(3), `credits_granted` INT
- `status` (`pending` | `succeeded` | `failed` | `refunded` | `partially_refunded` | `disputed`)
- `receipt_url` TEXT (nullable), `failure_reason` TEXT (nullable)
- `idem_key` TEXT (the key used for the matching `credit_ledger` grant row)
- `created_at`, `updated_at`
- `UNIQUE (provider, provider_payment_id)`
- Rules: a `succeeded` payment maps 1:1 to exactly one `credit_ledger` grant row via `idem_key`. Refunds/chargebacks append a *negative* grant ledger row (see `operation_type` below), never mutate the original.

#### `payment_events` (K) — webhook dedup + audit
Raw, verified provider webhook events, for idempotent processing and replay-safety.
- `id`, `provider`, `provider_event_id` TEXT, `event_type` TEXT
- `payload_hash` TEXT (SHA-256 of the raw verified body — body itself not stored long-term; PII/30-day policy from research §9 applies)
- `status` (`received` | `processed` | `ignored` | `failed`)
- `workspace_id` (nullable — resolved from customer mapping after parse), `received_at`, `processed_at`
- `UNIQUE (provider, provider_event_id)`
- Rules: the unique constraint is the replay guard. Insert-on-receive (after signature verification); a duplicate insert short-circuits processing (SC-006-style idempotency for webhooks).

#### Extension: `credit_ledger.operation_type`
Phase 1 enumerates only `reconcile` (+ the implicit consumption types, e.g. `query`, `ingest`, `caption`, **`enrich`** — note web-link enrichment, FR-001). Phase 2 adds the **credit-positive** operation types:
- `grant` (signup / promo), `purchase` (one-time top-up), `subscription_grant` (recurring allotment), `refund` (negative), `chargeback` (negative), `expiry` (negative, if credits expire), `admin_adjustment` (signed).
- **Sign convention (to confirm in implementation):** `credits_used` becomes a signed delta — negative = debit (consumption), positive = credit (grant). The Redis balance is `SUM(delta)`. The column may be renamed `credits_delta` in a Phase 2 migration; document the chosen convention in one place.
- Rules: every grant row carries an `idem_key` (the `payments.idem_key`); the existing `UNIQUE (idem_key)` makes webhook replays and double-clicks no-ops (SC-006).

#### Extension: Workspace
- Add `billing_email` (nullable; defaults to owner email) for receipts/invoices.
- No provider IDs on Workspace itself — those live in `billing_customers` to keep multi-provider clean.

### REST contract additions (BFF)

To append to [contracts/bff-rest.md](./001-contextengine-mvp/contracts/bff-rest.md) under a new **Billing & payments (Phase 2, US4-ext)** section. All authenticated and workspace-scoped unless noted; `workspace_id` resolved server-side from the JWT. Mutating endpoints accept `Idempotency-Key`.

| Method | Path | Purpose | Notes |
|--------|------|---------|-------|
| GET | `/billing/plans` | List active purchasable plans | Public catalog from `plans` + the caller's currency; no provider IDs leaked |
| POST | `/billing/checkout` | Start a checkout for a plan | Body `{ plan_code, provider? }`; resolves `provider_price_id`, creates/fetches `billing_customers`, returns `{ checkout_url }`. Admin/owner only |
| GET | `/billing/subscription` | Current workspace subscription + entitlement | `{ plan, status, current_period_end, cancel_at_period_end }` or `null` |
| POST | `/billing/subscription/cancel` | Cancel at period end | Sets provider `cancel_at_period_end=true`; status synced via webhook. Owner only |
| GET | `/billing/portal` | Provider-hosted billing/management portal link | Returns `{ portal_url }` (Stripe Billing Portal / Polar / PayPal equivalent). Admin/owner only |
| GET | `/billing/payments` | Workspace payment history | Paginated `?limit=&cursor=`; from `payments`; for the credits-page ledger/receipts |
| POST | `/webhooks/{provider}` | Provider webhook ingress | **Unauthenticated** (verified by signature, not JWT). `{provider}` ∈ `stripe`\|`polar`\|`paypal`. Raw body required for signature verification — must bypass any JSON body-rewrite middleware |

Response/error additions:
- `402 payment_required` (already defined for exhausted balance) now carries an `upgrade_url` pointing at `/billing/checkout` for the recommended plan.
- `POST /billing/checkout` for a non-admin → `403 forbidden`.
- `POST /webhooks/{provider}` with a bad/missing signature → `400 invalid_signature` (logged as a security event), never `2xx`.
- `POST /webhooks/{provider}` for an already-seen `provider_event_id` → `200` no-op (idempotent ack so the provider stops retrying).

### NATS subject additions

To append to [contracts/nats-subjects.md](./001-contextengine-mvp/contracts/nats-subjects.md):

| Subject | Publisher | Consumer | Payload (key fields) |
|---------|-----------|----------|----------------------|
| `billing.grant.<workspace_id>` | BFF (webhook handler, post-verify) | **Go kernel billing worker** | `{ workspace_id, plan_id, credits, operation_type, payment_id, idem_key, trace_id }` → `INSERT INTO credit_ledger` (positive delta) + `UPDATE workspace_credits` + Redis `INCRBY` (idempotent). The Go kernel is the sole `credit_ledger` writer. |
| `notify.<workspace_id>` (reuse) | BFF (webhook handler) | Notification service | New categories: `payment_succeeded`, `payment_failed`, `subscription_renewed`, `subscription_canceled` (extend the `notifications.category` enum) |

Rules:
- **Grant idempotency.** The **Go** `billing.grant` consumer relies on `credit_ledger.idem_key UNIQUE`; a replayed webhook that re-publishes the same `idem_key` inserts one ledger row and performs one Redis `INCRBY` (guarded by `SET NX billing:applied:{idem_key}`, mirroring research §3).
- **Order independence.** A `subscription_grant` for invoice N is keyed by the invoice ID, so out-of-order or duplicated provider deliveries converge to the correct balance.

### Webhook processing flow (per provider)

```
provider → POST /webhooks/{provider}
  1. Read RAW request body (no JSON pre-parse).
  2. VerifyWebhook(signature, secret) — CRITICAL. Fail → 400, log security event, stop.
  3. ParseEvent → { provider_event_id, event_type, object }.
  4. INSERT payment_events (provider, provider_event_id) — ON CONFLICT DO NOTHING.
       conflict → already processed → return 200 (no-op).
  5. Resolve workspace via billing_customers(provider_customer_id).
  6. Map event_type → action:
       payment_succeeded / invoice_paid → upsert payments(succeeded);
            publish billing.grant.<ws> with idem_key = provider_payment_id.
       payment_failed / invoice_payment_failed → payments(failed);
            notify payment_failed (dunning).
       customer.subscription.updated/deleted → upsert subscriptions(status,...).
       charge.refunded / dispute → payments(refunded|disputed);
            publish billing.grant.<ws> with NEGATIVE credits (operation_type=refund|chargeback).
  7. Mark payment_events.status = processed; return 200.
```

Per-provider mapping notes:
- **Stripe**: verify with `Stripe-Signature` (HMAC-SHA256 + timestamp tolerance). Events: `checkout.session.completed`, `invoice.paid`, `invoice.payment_failed`, `customer.subscription.updated|deleted`, `charge.refunded`, `charge.dispute.created`. Use Stripe `idempotency_key` on outbound calls.
- **Polar**: verify with the Polar webhook secret (HMAC). Events: `order.created`, `subscription.active|updated|canceled`, `benefit_grant.*`. Polar is closest to the credit-grant model.
- **PayPal**: verify via PayPal `verify-webhook-signature` API (not a local HMAC — requires a call back to PayPal with the transmission headers + `webhook_id`). Events: `PAYMENT.CAPTURE.COMPLETED`, `BILLING.SUBSCRIPTION.ACTIVATED|CANCELLED`, `PAYMENT.CAPTURE.REFUNDED`.

### Go kernel surface (`billing/`)

```
billing/
  provider.go          # PaymentProvider port (interface)
  providers/
    stripe.go          # adapter
    polar.go           # adapter
    paypal.go          # adapter
  checkout.go          # CreateCheckout / portal orchestration
  webhook.go           # verify → dedup → parse → dispatch
  grants.go            # publish billing.grant, ledger reconciliation helpers
  catalog.go           # plans / plan_provider_prices resolution
```

`PaymentProvider` port (sketch):
```go
type PaymentProvider interface {
    CreateCheckout(ctx, CheckoutInput) (checkoutURL string, err error)
    CreatePortalSession(ctx, customerID string) (portalURL string, err error)
    VerifyWebhook(ctx, rawBody []byte, headers http.Header) (Event, error) // CRITICAL
    FetchSubscription(ctx, providerSubID string) (Subscription, error)
}
```
Selection of the active provider(s) is a kernel `Flags`/config concern (e.g., `billing.providers.enabled = [stripe]`), so adding Polar/PayPal is config + an adapter, not a product change.

### Security checklist (delta from the OWASP ruleset)

- [ ] **AP4** Webhook signature verified before any side effect; raw body preserved; constant-time comparison.
- [ ] **S1/S3** Provider secret keys from environment only; never `NEXT_PUBLIC_`/client-exposed; only publishable keys reach the SPA.
- [ ] **AZ1/AZ6** `/billing/checkout`, `/billing/portal`, cancel are admin/owner-only; re-auth for cancel/downgrade.
- [ ] **AZ4** Webhook handler never trusts `workspace_id`/amount/credits from the client — resolves them from the verified provider object + `billing_customers`.
- [ ] **SC-006** Credit grants idempotent via `credit_ledger.idem_key` + `payment_events` dedup; replays are no-ops.
- [ ] **L2** No card data, no full provider payloads with PII in logs; store `payload_hash`, honor the 30-day raw-retention policy (research §9).
- [ ] **AP6** `/webhooks/*` has a body-size limit; reject oversized payloads.
- [ ] **H8** No CORS on webhook routes; they are server-to-server only.

### What stays unchanged

- Credit **consumption** (Redis hot path, `billing.deduct`, three ceilings, `402`/`429` blocking) — untouched.
- `workspace_credits`, the outbox pattern, and reconciliation — reused as-is; grants are just positive ledger rows.
- The credits UI ([credits.md](../design-system/aisat-studio/pages/credits.md)) gains a real **Upgrade/Top-up** action wired to `/billing/checkout` and a receipts list from `/billing/payments`; the meter/ledger components are unchanged.

### Open decisions to confirm before implementation

1. **Ledger sign convention**: signed `credits_delta` (recommended) vs. separate debit/credit columns. Pick one and document it once.
2. **Do credits expire?** If yes, add an `expiry` sweep + `expires_at` on grant rows; if no, drop the `expiry` op-type.
3. ~~**Billing entity**~~ **RESOLVED 2026-07-22** — **organization**, not workspace. One
   contract and one invoice per customer; `billing_customers`, `subscriptions`, `payments`
   and `billing_email` anchor to `organization_id`, and `workspace_credits` becomes an
   allocation drawn from an `organization_credits` pool rather than a direct purchase. The
   Phase 1 three-ceiling consumption path is untouched. See
   [Phase 2 — Tenancy & Delegated Administration](#phase-2--tenancy--delegated-administration).
4. **Tax/invoicing**: rely on provider-hosted invoices/tax (Stripe Tax / Polar Merchant-of-Record / PayPal) vs. issuing own invoices. MoR (Polar) materially reduces tax-compliance scope.
5. **Proration & mid-cycle plan changes**: defer to provider proration, or block plan changes to period boundaries.

---

## Phase 2 — AI Response Rating (Thumbs Up / Down)

**Status**: Draft / not started · **Added**: 2026-07-20

### Problem & intent

Phase 1 generates cited answers but has no signal on whether those answers were
useful. A lightweight per-response thumbs-up / thumbs-down rating closes that
loop: it feeds the eval pipeline (Phase 2 Ragas/DeepEval), surfaces systematic
retrieval or generation gaps, and gives the admin dashboard a human-quality
signal alongside the automated metrics.

Core rules:
- A rating is **per message turn** (one LLM answer), tied to the `llm_call_log`
  row for that turn. It does not replace automated evaluation — it complements it.
- Only the **user who received the answer** can rate it (no cross-user voting).
- Ratings are **workspace-scoped and RLS-protected** — a member in workspace A
  never sees feedback from workspace B.
- The same turn can be re-rated (last write wins); **no forced comment**. An
  optional free-text reason field (max 500 chars) is offered only on dislike.
- No gamification, no per-user score, no visible counts to other members.
- Rating data is **append-only for audit**; a re-rating inserts a new row and
  sets the previous row `superseded_at`.

### Data model

#### `response_ratings` (P) — new table

Anchors to the existing `llm_call_log` (Phase 1) row for the rated turn.
Partitioned by `created_at` (same convention as the parent table).

| Column | Type | Notes |
|--------|------|-------|
| `id` | UUID v7 PK | |
| `workspace_id` | UUID NOT NULL | RLS column — `SET LOCAL app.workspace_id` enforced |
| `user_id` | UUID NOT NULL | Only the session owner may insert |
| `llm_call_log_id` | UUID NOT NULL | FK → `llm_call_log.id`; the specific answer turn |
| `chat_session_id` | UUID NULL | FK → `chat_session.id`; denormalised for easier session-level aggregation |
| `rating` | SMALLINT NOT NULL | `1` = thumbs up · `-1` = thumbs down |
| `reason` | TEXT NULL | Optional free-text (≤ 500 chars); only surfaced on dislike |
| `superseded_at` | TIMESTAMPTZ NULL | Set when a newer rating supersedes this row |
| `created_at` | TIMESTAMPTZ NOT NULL | Partition key |

Indexes: `(workspace_id, llm_call_log_id, user_id)` for "my active rating for turn X"; `(workspace_id, created_at)` for admin time-range queries.

RLS policy: `workspace_id = current_setting('app.workspace_id')::uuid` (same as all other tenant tables).

#### Materialized view: `response_rating_daily` (P)

Aggregates for the admin quality dashboard (mirrors the `llm_cost_daily` view pattern from Phase 1):

```sql
SELECT
  workspace_id,
  date_trunc('day', created_at) AS day,
  COUNT(*) FILTER (WHERE rating = 1)  AS thumbs_up,
  COUNT(*) FILTER (WHERE rating = -1) AS thumbs_down,
  ROUND(COUNT(*) FILTER (WHERE rating = 1)::numeric
      / NULLIF(COUNT(*), 0) * 100, 1) AS satisfaction_pct
FROM response_ratings
WHERE superseded_at IS NULL
GROUP BY 1, 2;
```

`REFRESH MATERIALIZED VIEW CONCURRENTLY` triggered by the existing
`usage.matview.refresh` NATS tick in the `cmd/worker` role — no new
scheduler required.

### REST contract additions (BFF)

| Method | Path | Purpose | Notes |
|--------|------|---------|-------|
| `POST` | `/chat/sessions/{sessionId}/messages/{llmCallLogId}/rating` | Submit or update a rating | Body `{ rating: 1 \| -1, reason?: string }`. Authenticated; `workspace_id` from session. Returns `204`. Inserts a row and marks previous one `superseded_at = now()`. |
| `GET` | `/chat/sessions/{sessionId}/messages/{llmCallLogId}/rating` | Get the caller's current rating | Returns `{ rating, reason, created_at }` or `null`. Used to restore the thumbs state on re-open. |
| `GET` | `/admin/quality/ratings` | Workspace-level satisfaction metrics | Paginated, date-range filterable; returns daily `response_rating_daily` rows. Admin-only. |

Errors:
- `403` if `user_id` in session ≠ caller (can't rate someone else's answer).
- `422` if `reason` exceeds 500 chars.
- `404` if `llm_call_log_id` not found or not in the caller's workspace (prevents IDOR — resolve via join on `workspace_id`, not raw ID lookup).

### Phase 1 seam (no changes required)

`llm_call_log` already has `id`, `workspace_id`, `user_id`, `trace_id` — the
exact columns needed to join. No schema migration is needed in Phase 1; the
`response_ratings` table is an **additive** new table in Phase 2.

The Phase 1 SSE `done` event already carries the `trace_id` to the client,
which lets the SPA correlate a displayed answer with its `llm_call_log_id`
for the rating call.

### Eval pipeline integration

- Phase 2 Ragas evaluation runs automatically compare automated retrieval/
  faithfulness scores with human thumbs signals for the same turns.
- Disliked turns with `reason` text become a **seeded eval dataset** (negative
  examples) for prompt regression testing (Promptfoo/DeepEval).
- Admin dashboard gains a **"Satisfaction" card** alongside the existing
  cost/usage cards; an alert fires when `satisfaction_pct` drops below a
  configurable threshold.

### Security checklist

- [ ] **AZ3 (IDOR)** `llm_call_log_id` resolved via `workspace_id` join — never
      by raw ID.
- [ ] **AZ1** `POST` endpoint requires authenticated session; `user_id` from
      session cookie, never request body.
- [ ] **FE8 / AZ4** `rating` value validated server-side to `1 | -1` (smallint
      range); `reason` clamped to 500 chars.
- [ ] **L2** `reason` text is user content — never logged raw; stored only in DB
      under RLS.

### Open decisions

1. **Expose aggregate thumbs counts in the chat UI?** (e.g. "12 👍 for this
   answer type") — probably not for Phase 2; keep it admin-only to avoid
   anchoring bias.
2. **Rate individual cited chunks vs. the whole answer?** Per-chunk rating is
   richer for retrieval eval but significantly more complex UX. Defer to a
   later iteration; the schema can be extended with `chunk_id NULL` without
   breaking existing rows.
3. **Export to Langfuse?** Human feedback can be pushed as a Langfuse score
   via the existing OTel integration. Evaluate after Phase 2 eval pipeline
   is wired.

---

## Phase 2 — Workspace Knowledge Mind Map

**Status**: Draft / not started · **Added**: 2026-07-20

### Problem & intent

Members ask good questions in chat, but there is no way to see the *shape* of
the workspace's knowledge — what topics exist, how documents and notes relate,
where the dense clusters and the gaps are. A workspace knowledge mind map
provides an exploratory, non-linear view of the library: starting from a seed
(a topic string, a document, or a note), the system generates a graph of related
nodes sourced directly from the workspace, with every edge backed by a real
retrieval result or an explicit relationship, never fabricated.

Core rules:
- **No hallucinated edges.** Every relationship is sourced from a retrieval
  result (shared concepts / cited entities), a shared tag, or an explicit
  user-drawn link. The system states its confidence and source for each edge.
- **Access-scoped, always.** The map runs the same RLS + Qdrant
  payload-filter stack as chat: a member only sees nodes they are cleared for
  (`access_level ≤ effective_clearance`). A node that exists but is out of scope
  is omitted, not shown as a locked node, to avoid leaking its existence
  (SC-001 invariant).
- **Additive, not destructive.** Generating or refreshing a map never modifies
  any document, note, or tag — it is a read-only derived view.
- **Lazy expansion.** The initial map renders only the seed and its K nearest
  neighbours (default K=8). Each node can be individually expanded. This keeps
  first-render latency acceptable and avoids dumping the whole workspace at once.
- **Credit-metered.** Each expansion call deducts credits like a chat query
  (uses the same `billing.deduct` path and `llm_call_log` row). First render
  is cheaper (retrieval-only, no generation); enriched label generation costs
  more.

### User stories

| ID | Story |
|----|-------|
| MMP-01 | As a member, I can open a "Mind Map" view from a document or note and see related workspace knowledge. |
| MMP-02 | As a member, I can click any node to expand it to its own neighbours. |
| MMP-03 | As a member, I can click any node or edge to jump to the source document / cited passage. |
| MMP-04 | As a member, I can search a topic and generate a map seeded from that query. |
| MMP-05 | As a member, I can save a map layout (node positions + expansion state) to revisit later. |
| MMP-06 | As an admin, I can see workspace-level entity/topic clustering maps for knowledge-gap auditing. |

### Architecture

The mind map is a **read-path feature** built on existing Phase 1 retrieval
infrastructure. No new ML models are required.

#### Generation pipeline (Python `query.*` worker — additive graph node)

```
seed (query string or document id)
    │
    ▼
[Retrieve] hybrid search (BM25/SPLADE + dense, same as chat Node 3)
    │  top-K documents / chunks, with scores + metadata
    ▼
[Cluster] lightweight entity / concept extraction
    │  NER or KeyBERT on retrieved chunks → extract named entities / topics
    │  Group by shared entity to form candidate edges
    ▼
[Score edges] cosine similarity between chunk embeddings
    │  Keep edges where similarity ≥ threshold (configurable, default 0.65)
    │  Discard edges that cross access_level boundaries
    ▼
[Label] (optional, flag-gated) LLM call via `fast` alias
    │  Generate a short relationship label for each edge (e.g. "cites", "extends", "contradicts")
    │  Costs credits; skipped when flag disabled or budget exhausted
    ▼
MindMapResult { nodes[], edges[], seed, access_level_used, credits_spent }
```

This pipeline runs as a **new LangGraph sub-graph** (a `mindmap` intent) that
reuses the existing `search` and `lookup` MCP tools — no new MCP tools needed
in the common case. The `fast` alias for label generation is the same gateway
alias as the semantic cache warm-up, keeping cost low.

#### New NATS subject

| Subject | Publisher | Consumer | Payload |
|---------|-----------|----------|---------|
| `query.mindmap.<workspace_id>` | BFF (via existing `POST /query` with `intent=mindmap`) | Python `query.*` worker (mindmap sub-graph) | `{ workspace_id, user_id, seed_type: "doc"|"note"|"query", seed_id?: uuid, seed_text?: string, depth: int, k: int, label_edges: bool, stream_id, trace_id }` |

Reuses the existing SSE streaming path — the client opens a `GET /query/{streamId}`
SSE stream and receives incremental `mindmap_node` and `mindmap_edge` events as
they are discovered, so the map renders progressively rather than waiting for the
full result.

#### New SSE events (additive to [sse-events.md](./001-contextengine-mvp/contracts/sse-events.md))

| Event type | Payload | Notes |
|------------|---------|-------|
| `mindmap_node` | `{ id, label, type: "document"\|"note"\|"topic", doc_id?, source_url?, access_level, score }` | Streamed incrementally; one event per discovered node |
| `mindmap_edge` | `{ source_id, target_id, label?, weight, evidence_count }` | Streamed after the two endpoint nodes are emitted |
| `mindmap_done` | `{ node_count, edge_count, credits_spent, trace_id }` | Terminal event; mirrors `done` from chat |

#### New REST endpoints (additive to [bff-rest.md](./001-contextengine-mvp/contracts/bff-rest.md))

| Method | Path | Purpose | Notes |
|--------|------|---------|-------|
| `POST` | `/mindmap` | Start a mind map stream | Body `{ seed_type, seed_id?, seed_text?, depth?, k?, label_edges? }`. Returns `{ stream_id }`. Same flow as `POST /query`. |
| `GET` | `/mindmap/layouts` | List saved map layouts | Paginated; workspace-scoped. |
| `POST` | `/mindmap/layouts` | Save a layout | Body `{ name, seed, nodes_state: json, edges_state: json }`. |
| `GET` | `/mindmap/layouts/{id}` | Load a saved layout | Returns node positions + last-known graph; marks stale if any source doc updated since save. |
| `DELETE` | `/mindmap/layouts/{id}` | Delete a saved layout | Owner or admin only. |

### Data model

#### `mindmap_layouts` (P) — new table

Persists user-saved map layouts (node positions, expansion state). The live
graph data is **not** stored — it is regenerated on demand so it always reflects
current workspace content. Only the layout (positions + user annotations) is saved.

| Column | Type | Notes |
|--------|------|-------|
| `id` | UUID v7 PK | |
| `workspace_id` | UUID NOT NULL | RLS column |
| `user_id` | UUID NOT NULL | Owner |
| `name` | TEXT NOT NULL | User-chosen label |
| `seed_type` | TEXT NOT NULL | `doc` \| `note` \| `query` |
| `seed_id` | UUID NULL | Source doc/note id if seed_type ≠ query |
| `seed_text` | TEXT NULL | Query string if seed_type = query |
| `nodes_state` | JSONB NOT NULL | `{ [node_id]: { x, y, expanded } }` |
| `edges_state` | JSONB NOT NULL | `{ [edge_key]: { hidden } }` |
| `created_at` | TIMESTAMPTZ NOT NULL | |
| `updated_at` | TIMESTAMPTZ NOT NULL | |

RLS policy: same pattern — `workspace_id = current_setting('app.workspace_id')::uuid`.

### Phase 1 seams (no changes required)

- **Qdrant hybrid search** already runs per-workspace with payload filters — the
  mindmap pipeline calls it with the same pre-filter and clearance check.
- **`POST /query` + SSE streaming** already exists — `intent=mindmap` is a new
  dispatch branch in the existing policy chain, not a new endpoint. The `stream_id`
  / SSE flow is unchanged.
- **`llm_call_log`** row is written for any label-generation LLM call — the
  same credit metering / audit trail applies automatically.
- **`billing.deduct`** subject is published by the Python worker exactly as in
  chat — no new billing wiring.

### Frontend

The map is rendered in a dedicated **Library → Mind Map** tab (alongside the
existing Library list/grid views). Recommended library: **React Flow** (MIT) or
**Cytoscape.js** — both handle large graphs with zoom/pan/expand. The map view
should:
- Show node type via icon — document, note, and topic/entity each get a distinct
  glyph from the shared Heroicons/Lucide SVG set. **Not emoji**: the design system
  bans emoji icons outright ([.stitch/DESIGN.md](../.stitch/DESIGN.md) "Accessibility
  & Motion"), and emoji render inconsistently across platforms at graph-node size.
- Show edge weight via line thickness; edge label on hover.
- On node click → open the source document or note in the side panel.
- On edge click → show the evidence snippet(s) that produced the relationship.
- Toolbar: **Expand**, **Collapse subtree**, **Save layout**, **Export as PNG/SVG**.
- Debug panel (consistent with Phase 1 chat debug): show retrieval scores,
  edge similarity thresholds, and credits spent for the current map.

### Performance constraints

- **First render ≤ 3 s** for a depth-1 map (K=8, no label generation) on a
  warm Qdrant index.
- **Progressive streaming** — first node appears within 500 ms of the SSE
  connection opening.
- **Max nodes per session** capped at 200 (configurable per workspace via
  `agent_policies`). Beyond cap, the UI shows a "zoom in to a subtopic" prompt
  rather than expanding further.

### Security checklist

- [ ] **AZ3 (IDOR)** `seed_id` resolved via `workspace_id` join — never raw ID.
- [ ] **SC-001** Qdrant pre-filter + RLS enforced on every node; out-of-scope
      nodes are omitted, not shown locked.
- [ ] **AZ1** `POST /mindmap` requires authenticated session; workspace from cookie.
- [ ] **SC-007** Prompt injection in `seed_text` goes through the same input
      validation as `POST /query` — reject / sanitize before embedding.
- [ ] **L2** `seed_text` is user content; not logged raw. `reason`/content fields
      from retrieved chunks not logged beyond the existing `result_hash` pattern.

### Open decisions

1. **Cross-workspace maps for admins?** An org-level admin who can see multiple
   workspaces might want a cross-workspace map. Defer — requires a new
   "org-admin" clearance concept not in Phase 1.
2. **Collaborative maps?** Real-time multi-user map editing (like Figma
   multiplayer). Out of scope for Phase 2; the `nodes_state` JSONB column is
   intentionally layout-only to keep this option open without over-engineering.
3. **Entity extraction model:** KeyBERT is fast and zero-shot; a fine-tuned NER
   model gives better precision on domain jargon. Start with KeyBERT behind a
   flag; replace if quality signals from `response_ratings` suggest retrieval
   edges are poor.
4. **Export formats:** PNG/SVG export is a nice-to-have. Markdown export
   (hierarchical bullet list from the graph) is cheap and useful for note-taking.

---

## Phase 2 — Enterprise Knowledge Layer (Typed Artifacts, Knowledge Graph & Agent Context API)

**Status**: Draft / not started · **Added**: 2026-07-22

### Problem & intent

Phase 1 makes uploaded documents queryable by **people**. This feature widens the
same substrate into an organization's **centralized, reliable knowledge base that AI
agents query** — biz rules, requirements, specs, system design, workflows, and
AI-agent source/metadata — so every agent in the enterprise has one authoritative
place to look things up instead of guessing or re-deriving.

This is a **superset, not a pivot.** It reuses the Phase 1 engine unchanged — MCP
server, NATS bus, hybrid search, Postgres RLS + Qdrant payload filters. The delta is
a **typed-artifact + relationship (graph) layer** over the existing Document model,
plus an agent-facing consumption API. No Phase 1 contract changes.

Layer legend (same as Billing): **K** = kernel (reusable across products) ·
**P** = product-specific.

Core rules:

- **Hybrid source of truth.** Every artifact carries `origin` ∈ (`authored` |
  `mirrored`). *Authored* artifacts (agent registry, curated biz rules, the taxonomy,
  and all edges) live canonically in AISAT. *Mirrored* artifacts (specs, requirements,
  code, system-design docs) stay authoritative in Git/Jira/Confluence and are indexed
  here with a `source_ref` back-link.
- **Governance follows origin.** *Authored* artifacts get the full lifecycle machine
  (`draft → active → deprecated`, approval, `version`, `supersedes_id`). *Mirrored*
  artifacts get **none** of it — they inherit their origin's state and instead carry
  `synced_at` + `source_version` + a `stale` flag. Never re-version what Git already
  versions.
- **No hallucinated edges.** Every relationship is sourced from a retrieval result, a
  declared-in-source reference, or an explicit human link, and records its `provenance`
  (`llm_inferred` | `human_confirmed` | `declared_in_source`) and a `confidence`.
  Reuses the Workspace Mind Map's "no fabricated edges" discipline — the two share one
  edge model.
- **Extraction, not authoring.** Typed metadata is **LLM-extracted from existing
  docs/code with human review**, never required as manual data entry. Reuses the
  Phase 1 BAML metadata step (which already produces `data_type`, `summary`, `tags[]`).
- **Access-scoped, always.** Artifacts and edges run the same RLS + Qdrant
  payload-filter stack as chat. An out-of-scope node is omitted, never shown locked
  (SC-001 invariant).
- **Two access axes, both required.** The Phase 1 L1–L5 clearance ladder is kept and
  joined by a second, orthogonal **principal (group ACL)** axis. See
  [Access model](#access-model-decided) below — this was the feature's biggest open
  question and is now settled.

### Access model (decided)

**Decision (2026-07-22): keep the L1–L5 ladder, add a group-principal ACL axis, require
both.** Not extra rungs, not compartments, not an external policy engine.

```
visible  ⟺  doc.access_level ≤ user.clearance
       AND  ( doc.allowed_principals = '{}'
              OR doc.allowed_principals && user.principals )   -- array overlap
```

**Why this shape.** The ladder answers *how sensitive*; it cannot answer *which domain*,
because an ordered axis always leaks upward — on a pure ladder every L4 and L5 sees
whatever an L3 security engineer sees. The second axis fixes that. It is a **group ACL**
(permissive, "any listed principal may read") rather than IC-style **compartments**
(restrictive, "holder must have every label") because this feature's premise is
*mirroring* Git/Jira/Confluence, and every one of those systems expresses access as group
ACLs. Modelling a Confluence space as a compartment forces one compartment per
space/repo/project, which defeats the point of a small controlled label set. Conjunctive
need-to-know ("security **and** legal, both required") is an intelligence-community
requirement, not a software-company one; if it ever appears, it is an additive third
field, not a rewrite.

**Why not a policy engine.** SpiceDB/OpenFGA/Cedar are the modern commercial answer for
sharing-heavy apps, but they resolve permissions **per object**. Retrieval must
**pre-filter inside the vector search** — post-filtering an ANN top-K destroys result
quality and turns SC-001 from an invariant into a best effort. A denormalized principal
array on each chunk is precisely the "security trimming" pattern used by enterprise RAG
systems, and it compiles to a single cheap payload filter.

#### Principals

One namespaced `TEXT[]` field, so internal shares and mirrored external ACLs compose in
a single filter:

| Form | Meaning |
|------|---------|
| `user:<uuid>` | Direct share to one member |
| `group:<uuid>` | AISAT-native workspace group |
| `ext:<source>:<external_id>` | Mirrored external group (Confluence space, Jira project role, Git team) |

A caller's principal set is resolved at session-mint time — `user:self` ∪ native groups ∪
external groups from the IdP/SCIM claim or connector sync — and carried in the request
context beside `clearance`.

**Sizing rule (not a fixed cap).** The set inlined into a Qdrant filter is *not* the
user's directory membership. A group that never appears on any indexed record cannot
change a result, so the filter only ever needs:

```
effective_principals = user_principals ∩ used_principals
```

where `used_principals` is the distinct set of values actually appearing in
`allowed_principals` across the workspace corpus, maintained incrementally on artifact
write/delete. An enterprise user in 500 directory groups where only 12 gate content
carries 12 principals into the filter, not 500.

This matters because it moves the bound onto something you control (how many groups are
*used as ACLs in this workspace*) instead of something the customer controls (how big
their directory is). Consequences:

- **Connectors mirror ACL-bearing groups only** — the groups that appear on records being
  indexed — never the whole directory.
- The operational ceiling is `|used_principals|`. Alert when it passes ~1,000: that is the
  signal groups are being used as folders (one per project/repo), which is the failure
  mode the "keep the registry small" guidance exists to prevent.
- Only if `|effective_principals|` is still pathological after the intersection is a
  precomputed accessible-set worth the complexity. Do not build that speculatively.

*(No negative/`must_not` reformulation is available here: overlap semantics require
enumerating the user's side, unlike the subset semantics of the compartment model that was
rejected. The intersection above is the bound.)*

#### The clearance scheme is workspace-configurable

The Phase 1 backend never named the levels — `spec.md` and `data-model.md` only ever say
`access_level INT (1–5)`. "Public / Restricted / Internal / Confidential / Executive" is a
**mockup convention, not a schema**. Enterprises arrive with their own scheme (3-tier
Public/Internal/Confidential, 4-tier Purview-style, ISO-27001-derived), and forcing five
fixed names onto them is the first thing a security review pushes back on.

**Decision: labels and level count are workspace config; the stored value stays an
integer.**

```yaml
clearance_scheme:                 # workspace setting; default = the 5-level scheme below
  levels:
    - { n: 1, label: "Public",       description: "All workspace members" }
    - { n: 2, label: "Restricted",   description: "Contractors and above" }
    - { n: 3, label: "Internal",     description: "Full-time team and above" }
    - { n: 4, label: "Confidential", description: "Senior leadership" }
    - { n: 5, label: "Executive",    description: "Exec and board only" }
```

Rules:

- `n` is contiguous from 1 and is the value stored in `documents.access_level`, the Qdrant
  payload, and every filter. **Labels never reach the index** — renaming a level is a
  display change with no re-embedding and no migration.
- Level count N ∈ [2, 5]. A 3-tier org defines three and the ladder renders three rungs;
  no wasted or invented levels.
- **Reducing N is destructive and must be an explicit remap, never a silent truncation.**
  Documents sitting at a removed level would otherwise become unreachable (or, worse,
  fall to a lower level and widen access). The admin flow must require a target level for
  every affected document before it commits.
- Raising N within the cap is safe and additive.
- Every surface renders from this config: the workspace ladder, the Library sharing
  selector, clearance badges, and the invite modal's clearance options. No screen hardcodes
  a level name.

**Why the [2,5] ceiling.** Schemes with six or more tiers are rare, and the honest cost of
supporting them is a wider `CHECK (access_level BETWEEN 1 AND 5)` constraint plus a ladder
UI that stops being scannable. If a customer genuinely needs more, widening the constraint
is a one-line migration — do it on demand rather than paying the UI complexity up front.
Above five tiers is usually a sign the org wants *groups*, not more rungs.

#### Enforcement (both layers, unchanged in shape)

- **Postgres RLS:** `... AND access_level <= current_setting('app.clearance')::int AND (allowed_principals = '{}' OR allowed_principals && current_setting('app.principals')::text[])` — `&&` is array-overlap, GIN-indexable.
- **Qdrant:** add `allowed_principals` to the payload + payload-index list
  ([data-model.md](./001-contextengine-mvp/data-model.md) "Payload indexes"); filter
  `must: [ workspace_id == ctx, access_level <= clearance, <empty-or-overlap on principals> ]`.
- **Backfill: none.** `allowed_principals = '{}'` is inert, so every existing Phase-1 row
  behaves exactly as today and authored artifacts default to ladder-only.

#### Rules that fall out of this (all decided, not open)

1. **Both conjuncts always.** Clearance never bypasses ACL; ACL never bypasses clearance.
   An L4 + `group:eng` doc is visible only to L4+ engineers.
2. **No implicit admin read.** Owners/admins **administer** groups (create, grant, revoke,
   view membership) by role, and **read** group-restricted content only via an actual
   grant. The alternative makes AISAT a privilege-escalation path *out of* the customer's
   existing controls the moment their Confluence content lands here — which is the single
   fastest way to lose an enterprise security review.
3. **Break-glass instead of a standing bypass.** Operability (mis-tagged doc, offboarded
   sole owner, legal hold) is served by an explicit, reason-required, time-boxed
   self-grant that writes an audit row and notifies workspace owners — never by a silent
   rank-based override.
4. **Connectors fail closed.** If a connector cannot resolve a record's source ACL, that
   record is **not indexed**. Partial ACL fidelity is worse than no mirroring, because it
   widens access silently.
5. **Mirrored classification is per-source.** A source system has no notion of the L1–L5
   ladder, so each `knowledge_sources` row carries a `default_access_level`, set at
   connector-config time and capped at the configuring admin's own clearance (mirrors the
   existing "tag up to your own level" rule).
6. **Edges follow endpoints.** A `knowledge_edges` row is visible only when **both**
   endpoint documents are visible — otherwise the graph leaks a hidden node's existence
   through its neighbours.
7. **Memory distillation is partitioned by ACL.** Phase 1 stamps a memory's
   `access_level` as the max over contributing chunks ([data-model.md §Memory
   invariant](./001-contextengine-mvp/data-model.md)). Max is wrong for an OR-semantics
   principal set: unioning `{g1}` and `{g2}` would make a memory built from both sources
   readable by someone in *either*. Therefore **never distil one memory across chunks with
   differing principal sets** — partition by `(max access_level, principal set)` and emit
   one memory per signature. This is a correctness rule, not an optimization.
8. **Personal scope is untouched.** `scope='personal'` stays a third, orthogonal
   owner-only check. Do not model it as a group — it is per-user and would grow the
   principal space to O(members).

#### Consequence to schedule

External principals only mean something if a querying user can be resolved to them, so
**IdP group claims / SCIM sync becomes a dependency of this feature**, not an optional
extra. It is a larger lift than the schema change and should be sequenced first.

### Data model

All new tables follow Phase 1 conventions: UUID v7 PKs, `workspace_id NOT NULL` + RLS
on tenant tables, ISO-8601 UTC timestamps.

#### Extension: `documents` (additive columns)

The typed-artifact layer is an overlay on the existing Document entity
([data-model.md](./001-contextengine-mvp/data-model.md)), reusing the existing
LLM-suggested `data_type` seam. All columns are nullable — a plain Phase-1 document
has them all NULL and behaves exactly as before.

| Column | Type | Notes |
|--------|------|-------|
| `allowed_principals` | TEXT[] NOT NULL DEFAULT `'{}'` | **Access axis 2** — namespaced principals (`user:` / `group:` / `ext:`). Empty = inert, clearance alone governs. GIN index; mirrored into the Qdrant chunk payload. See [Access model](#access-model-decided) |
| `artifact_type_id` | UUID NULL | FK → `artifact_types`; typed classification (formalizes `data_type`) |
| `origin` | TEXT NULL | `authored` \| `mirrored`; NULL = plain Phase-1 document |
| `source_system` | TEXT NULL | `git` \| `jira` \| `confluence` \| `internal` (mirrored only) |
| `source_ref` | TEXT NULL | Stable back-link to the origin record (repo path, issue key, page id) |
| `source_version` | TEXT NULL | Origin commit SHA / etag / updated marker, for staleness |
| `synced_at` | TIMESTAMPTZ NULL | Last successful mirror sync |
| `stale` | BOOL NOT NULL DEFAULT false | Set when the origin moved past `source_version` |
| `lifecycle_status` | TEXT NULL | `draft` \| `active` \| `deprecated` \| `superseded` (authored only) |
| `version` | INT NULL | Monotonic per artifact (authored only) |
| `supersedes_id` | UUID NULL | FK → prior `documents.id` this version replaces |

#### `artifact_types` (P) — the taxonomy/ontology (authored)

The registry of typed artifact kinds and their expected shape. Seeded with `biz_rule`,
`requirement`, `spec`, `workflow`, `agent_def`, `system_design`; workspace-extensible.

| Column | Type | Notes |
|--------|------|-------|
| `id` | UUID v7 PK | |
| `workspace_id` | UUID NULL | RLS column; NULL-workspace rows = built-in defaults |
| `code` | TEXT NOT NULL | slug, e.g. `biz_rule` |
| `name`, `description` | TEXT | |
| `schema` | JSONB NULL | Optional field schema for structured extraction/validation |
| `governed` | BOOL NOT NULL | Whether instances require the approval lifecycle |
| `embed_policy` | TEXT NOT NULL DEFAULT `full_body` | `full_body` \| `metadata_only` — how mirrored bodies of this type are indexed (open decision #4) |
| `created_at`, `updated_at` | TIMESTAMPTZ | |

#### `knowledge_edges` (P) — the graph (authored; shared with Mind Map)

The relationships between artifacts — the layer no source system provides, and where
impact analysis lives.

| Column | Type | Notes |
|--------|------|-------|
| `id` | UUID v7 PK | |
| `workspace_id` | UUID NOT NULL | RLS column |
| `source_id` | UUID NOT NULL | FK → `documents.id` |
| `target_id` | UUID NOT NULL | FK → `documents.id` |
| `relation` | TEXT NOT NULL | `depends_on` \| `implements` \| `cites` \| `contradicts` \| `supersedes` \| `owned_by` \| `derived_from` |
| `provenance` | TEXT NOT NULL | `llm_inferred` \| `human_confirmed` \| `declared_in_source` |
| `confidence` | REAL NULL | 0–1 for inferred edges |
| `evidence` | JSONB NULL | retrieval scores / source snippet refs (`result_hash` discipline — no raw content) |
| `confirmed_by` | UUID NULL | user who confirmed a governance-critical edge |
| `created_at` | TIMESTAMPTZ NOT NULL | |

Indexes: `(workspace_id, source_id, relation)` and `(workspace_id, target_id, relation)`
for forward/reverse traversal (impact analysis walks the reverse index).

#### `agent_registry` (P) — the agent catalog (authored; the wedge)

A workspace-scoped catalog of the agents that exist, so agents (and humans) can
discover capabilities. The smallest slice with no canonical competitor.

| Column | Type | Notes |
|--------|------|-------|
| `id` | UUID v7 PK | |
| `workspace_id` | UUID NOT NULL | RLS column |
| `name` | TEXT NOT NULL | |
| `purpose` | TEXT | |
| `capabilities` | TEXT[] | for `get_agent_registry(capability)` filtering |
| `model` | TEXT | e.g. `claude-opus-4-8` |
| `tools` | JSONB | tool list / MCP surface |
| `owner_user_id` | UUID | |
| `source_ref` | TEXT NULL | repo path if the agent def is mirrored from code |
| `document_id` | UUID NULL | FK → `documents.id` if it also has an indexed spec/body |
| `version`, `status` | INT / TEXT | reuses the authored lifecycle |
| `created_at`, `updated_at` | TIMESTAMPTZ | |

#### `knowledge_sources` (K) — external connectors config

Provider-agnostic external source connections per workspace (mirrors the Billing
`billing_customers`/provider pattern).

| Column | Type | Notes |
|--------|------|-------|
| `id` | UUID v7 PK | |
| `workspace_id` | UUID NOT NULL | RLS column |
| `kind` | TEXT NOT NULL | `git` \| `jira` \| `confluence` |
| `config` | JSONB NOT NULL | repo/project/space selectors; **secret refs only**, never raw secrets |
| `default_artifact_type_id` | UUID NULL | how to type incoming records |
| `default_access_level` | INT NOT NULL | L1–L5 stamped on records from this source; capped at the configuring admin's clearance (access-model rule 5) |
| `principal_mapping` | JSONB NULL | How source ACL entities map to `ext:<source>:<id>` principals; `NULL` = connector resolves natively |
| `last_synced_at` | TIMESTAMPTZ NULL | |
| `sync_status` | TEXT | `idle` \| `syncing` \| `error` \| `blocked_acl_unresolved` (fail-closed, rule 4) |
| `created_at`, `updated_at` | TIMESTAMPTZ | |

#### `principal_groups` (K) — the group registry

Workspace-scoped groups, both native and mirrored. Mirrored rows are refreshed by the
connector sync and are read-only in the UI.

| Column | Type | Notes |
|--------|------|-------|
| `id` | UUID v7 PK | |
| `workspace_id` | UUID NOT NULL | RLS column |
| `principal` | TEXT NOT NULL | Canonical form — `group:<uuid>` or `ext:<source>:<id>` |
| `name`, `description` | TEXT | Display only |
| `origin` | TEXT NOT NULL | `native` \| `mirrored` |
| `source_id` | UUID NULL | FK → `knowledge_sources` when `origin='mirrored'` |
| `created_at`, `updated_at` | TIMESTAMPTZ | |

`UNIQUE (workspace_id, principal)`.

#### `principal_grants` (K) — membership, including break-glass

| Column | Type | Notes |
|--------|------|-------|
| `id` | UUID v7 PK | |
| `workspace_id` | UUID NOT NULL | RLS column |
| `user_id` | UUID NOT NULL | Grantee |
| `principal_group_id` | UUID NOT NULL | FK → `principal_groups` |
| `granted_by` | UUID NOT NULL | Never self, except break-glass |
| `break_glass` | BOOL NOT NULL DEFAULT false | Emergency self-grant (rule 3) |
| `reason` | TEXT NULL | **Required** when `break_glass` — audited |
| `expires_at` | TIMESTAMPTZ NULL | **Required** when `break_glass`; session resolution ignores expired rows |
| `created_at`, `revoked_at` | TIMESTAMPTZ | |

Rules: a break-glass insert writes an audit-trail row and publishes a `notify.<ws>`
event to every workspace owner. Mirrored groups' membership is connector-owned — a
native grant into an `ext:` group is rejected, otherwise AISAT silently diverges from
the source system's ACL.

### MCP tool additions (the agent-consumption surface)

Extends the Phase 1 read-only tool set
([contracts/mcp-tools.md](./001-contextengine-mvp/contracts/mcp-tools.md), Categories
A/B/C), still gated by `agent_policies.allowed_tools` and still read-only. New
**Category D — typed knowledge**:

| Tool | Purpose |
|------|---------|
| `get_artifact_by_type(type, status?, domain?, limit?)` | Structured, filterable fetch of typed artifacts (e.g. active specs in a domain) |
| `search_biz_rules(domain?, status='active')` | Convenience wrapper over `get_artifact_by_type('biz_rule', ...)`; the most common agent query |
| `get_agent_registry(capability?)` | Catalog of known agents filtered by capability — the discovery entry point |
| `resolve_dependency_chain(artifact_id, relation?, depth?)` | Walk `knowledge_edges` for dependency/impact traversal ("what breaks if this changes?") |

Every tool applies the same clearance pre-filter as Category A; out-of-scope
nodes/edges are omitted from results.

### REST contract additions (BFF)

To append to [contracts/bff-rest.md](./001-contextengine-mvp/contracts/bff-rest.md);
all authenticated + workspace-scoped:

| Method | Path | Purpose |
|--------|------|---------|
| GET/POST/PATCH | `/artifacts`, `/artifacts/{id}` | Typed-artifact CRUD (authored) + typed/filtered list; POST body includes `artifact_type`, `origin` |
| POST | `/artifacts/{id}/lifecycle` | Transition `draft→active→deprecated` (authored only; admin/owner); records approver |
| GET | `/artifacts/{id}/edges`, `/artifacts/{id}/impact` | Edges + reverse-traversal impact analysis |
| POST/PATCH/DELETE | `/edges`, `/edges/{id}` | Create/confirm/remove edges (`human_confirmed` provenance) |
| CRUD | `/agents`, `/agents/{id}` | Agent registry |
| CRUD | `/knowledge-sources`, `/knowledge-sources/{id}` | Connector config (admin/owner; secrets via secret store) |
| POST | `/knowledge-sources/{id}/sync` | Trigger a manual re-sync |

### NATS subject additions

To append to
[contracts/nats-subjects.md](./001-contextengine-mvp/contracts/nats-subjects.md):

| Subject | Publisher | Consumer | Payload (key fields) |
|---------|-----------|----------|----------------------|
| `knowledge.artifact.updated.<type>.<workspace_id>` | BFF / ingestion worker | **subscribing agents** + internal indexers | `{ artifact_id, type, origin, lifecycle_status, version, change: created\|updated\|deprecated, trace_id }` — the change-subscription backbone for "agents stay current" |
| `ingestion.source.<kind>.<workspace_id>` | connector webhook handler | Python connector worker | `{ source_id, kind, records[], source_version }` → routes into the existing `ingestion.*` pipeline |
| `knowledge.staleness.tick` | scheduled `cmd/worker` | staleness sweeper | periodic re-check of mirrored `source_version`; sets `documents.stale` — reuses the single-owner scheduled-tick pattern ([research.md §14–§15](./001-contextengine-mvp/research.md)) |

### Go / Python worker surface

A provider-agnostic **`KnowledgeSource` port + thin adapters**, mirroring the Phase 2
Billing `PaymentProvider` pattern exactly (adding a source is config + an adapter, not
a product change):

```
knowledge/
  source.go            # KnowledgeSource port: ListChanges / FetchRecord / VerifyWebhook
  sources/
    git.go             # adapter (repo path; commit SHA as source_version)
    jira.go            # adapter (issue key; updated marker)
    confluence.go      # adapter (page id; version)
  sync.go              # webhook → ingestion.source.* → pipeline; staleness sweep
```

Extraction/typing/embedding of mirrored records reuses the Phase 1 Python ingestion
pipeline (`markitdown`, `tagger`, `chunker`) — a connector only produces raw records +
`source_ref`/`source_version`; the existing pipeline does the rest.

### Phase 1 seams (little / no change required)

- **`documents.data_type`** already exists as the LLM-suggested type — the overlay
  formalizes it; the new columns are additive and nullable.
- **`ingestion.*` pipeline** is reused verbatim for connector sync; only the connector
  adapters + the source subject are new.
- **MCP server + `agent_policies.allowed_tools`** already gate read-only tools per
  role — Category D slots in the same way.
- **RLS + Qdrant payload filters** already enforce clearance per document/chunk —
  artifacts and edges reuse the identical pre-filter (SC-001).
- **Mind Map edge model** — this note's `knowledge_edges` is the general table the
  Phase 2 Mind Map renders; build them together so the map reads persisted edges
  instead of a throwaway model.

### Security checklist (delta from the OWASP ruleset)

- [ ] **SC-001** Every typed-artifact query, edge traversal, and registry lookup runs
      **both** access conjuncts (clearance **and** principal overlap) as a *pre-filter* in
      RLS and in the Qdrant payload filter; out-of-scope nodes/edges omitted, not shown
      locked. No post-filtering of ANN results.
- [ ] **AZ1/AZ6 (no implicit admin read)** Owner/admin role grants group *administration*,
      never group *content*. Break-glass self-grants require a reason + expiry, write an
      audit row, and notify all owners (access-model rules 2–3).
- [ ] **Fail-closed connectors** A record whose source ACL cannot be resolved is not
      indexed; the source is marked `blocked_acl_unresolved` rather than importing it
      wide open (rule 4).
- [ ] **Memory ACL partitioning** No memory is distilled across chunks with differing
      principal sets (rule 7) — verify with a test that a two-source memory is never
      injected for a user holding only one of the two groups.
- [ ] **FR-011 / injection** Mirrored external content (Git/Jira/Confluence) is
      untrusted data — same input treatment as retrieved chunks; never executed as
      instructions.
- [ ] **S1/S3** Connector credentials from the secret store/env only;
      `knowledge_sources.config` holds secret *refs*, never raw tokens; never
      client-exposed.
- [ ] **AZ1/AZ6** Lifecycle transitions, edge confirmation, and connector config are
      admin/owner-only; governance-critical edges require `human_confirmed` provenance.
- [ ] **AZ3 (IDOR)** `artifact_id` / `source_id` / `edge_id` resolved via
      `workspace_id` join, never raw ID.
- [ ] **L2** Edge `evidence` stores score/hash refs, not raw source content; honors the
      30-day raw-retention policy.

### Open decisions

1. ~~**Access model.**~~ **RESOLVED 2026-07-22** — keep the L1–L5 ladder, add an
   orthogonal **group-principal ACL** axis, require both conjuncts. Group ACL rather than
   IC-style compartments, because this feature mirrors Git/Jira/Confluence and those
   systems express access as groups. No external policy engine, because retrieval must
   pre-filter inside the vector search. Full specification, including the no-implicit-
   admin-read and fail-closed-connector rules, in
   [Access model (decided)](#access-model-decided) above.
   **Still to confirm at build time:** the exact IdP/SCIM claim carrying external group
   membership. (The former "principal-set cap" is resolved — see the sizing rule under
   [Access model (decided)](#access-model-decided): the bound is
   `user_principals ∩ used_principals`, not a fixed number.)
2. ~~**First connector.**~~ **RESOLVED 2026-07-22** — **Git first.** `source_version` is
   a commit SHA (exact, cheap to diff, no polling ambiguity), repo webhooks are simple to
   verify, and Git is where specs, agent definitions, and system design already live.
   Jira and Confluence follow; both need richer ACL mapping and have fuzzier change
   markers.
3. ~~**Agent defs: authored vs mirrored.**~~ **RESOLVED 2026-07-22** — **mirrored from
   Git is the default and the recommended path; authored is the fallback.** This is the
   feature's own "extraction, not authoring" rule applied to itself: agent definitions
   already exist as files in repos, so retyping them into a form is exactly the manual
   data entry the rule bans, and it guarantees drift the moment the repo moves. Default
   UX = point a Git source at a path glob and the connector extracts definitions.
   Hand-authoring is a form, kept for agents with no repo representation (vendor or SaaS
   agents). Mirrored registry entries are **read-only in AISAT** with a link to the
   source path — see the mirrored-is-read-only principle below.
4. ~~**Mirrored embedding.**~~ **RESOLVED 2026-07-22** — **embed full bodies by
   default**, with a per-type override. Metadata-only indexing would let an agent
   discover *that* a spec exists but not answer from it, which is the opposite of this
   feature's stated goal of giving agents one authoritative place to look things up.
   Staleness is already a solved problem in this design (`source_version` + `stale` +
   the `knowledge.staleness.tick` sweeper), so it is not a reason to under-index.
   Add `artifact_types.embed_policy` ∈ (`full_body` | `metadata_only`), default
   `full_body`; set `metadata_only` for types whose bodies are large and churny (raw
   code files) and better served by a link-out.
   **Staleness behaviour:** a stale record stays retrievable and is badged `stale` in
   results and citations — silently dropping it trades one kind of unreliability for a
   worse one. A record *deleted* at source is tombstoned and removed from the index.
5. ~~**Build ordering vs Mind Map.**~~ **RESOLVED 2026-07-22** — **this layer first, Mind
   Map second.** `knowledge_edges` is a persistence concern that belongs to this note
   (provenance, confidence, human confirmation); the Mind Map is a *renderer* over it.
   Building the map first would mean inventing a throwaway in-memory edge model and then
   migrating it. Ship edges + extraction + the impact API here; the map then reads
   persisted edges from its first commit.

### Surfaces & naming (decided)

Three UI questions blocked mockups for this feature. All three are resolved by one
principle: **this layer adds facets to existing surfaces; it does not add a parallel
section.**

1. **"Agent registry" vs the existing Agents screen — two different things, kept apart.**
   The shipped Agents screen is *runtime*: which devices are connected, credential and
   BYOK routing, running long-horizon tasks and their cost caps. `agent_registry` is
   *catalog*: what agents exist conceptually, their purpose and capabilities, for
   discovery by humans and by other agents via `get_agent_registry`. The relationship is
   "running processes" vs "installed packages".
   **Decision:** the Agents nav item keeps its name and its current meaning — renaming a
   shipped Phase-1 surface for a Phase-2 concern is churn. The registry is **not** a
   second Agents screen: `agent_def` is already a seeded `artifact_type`, so the registry
   is a *facet of the Library* (type = Agent definition), not a new destination. Each
   screen carries a one-line cross-link to the other.
2. **Connector config has a home: Admin → Knowledge.** Connectors hold secret refs and
   are owner/admin-only, which puts them in Admin rather than Library. The same tab holds
   the **artifact-type taxonomy**, since both answer "where does knowledge come from and
   how is it typed". Admin tabs become Usage · Members · Groups · **Knowledge** ·
   Broadcast · Audit.
3. **No new top-level nav; the Library is the artifact browser.** Documents and typed
   artifacts are the same `documents` table with an overlay — splitting them across two
   screens would force a member to know whether a thing is a "document" or an "artifact"
   before they could find it. The Library gains a tab shell (**Documents** · **Mind
   Map**) plus type / origin / lifecycle facets, and artifact detail with edges and
   impact analysis.

**Cross-cutting principle — mirrored is read-only.** Anything mirrored from a source
system (documents, groups, agent definitions) is read-only in AISAT and displays where it
is managed, with a link. Local edits to mirrored records would silently diverge from the
source, which is exactly what makes mirrored ACLs and mirrored content untrustworthy.
This already governs the Groups tab; it now governs artifacts and the agent registry too.

---

## Phase 2 — Tenancy & Delegated Administration

**Status**: Decided 2026-07-22 · **Scope**: the two structural gaps left by the access model

Two questions blocked adoption at the large end: nobody can administer groups at 1,000
people through one central admin, and there was no container above Workspace for
consolidated billing. Both are decided here. The governing goal is that the platform
should impose **no ceremony on a 10-person team and real structure on a 5,000-person org**,
without two code paths.

### Decision 1 — Delegated group administration

**Group ownership is a grant type, not a role.** `principal_grants.grant_type` ∈
(`member` | `owner`); a user may hold both (two rows).

| Grant | Confers | Does **not** confer |
|-------|---------|---------------------|
| `member` | Read access — this is what enters `effective_principals` | Any ability to change membership |
| `owner` | Grant/revoke membership of **that one group**, approve join requests | **Any read access whatsoever** |

The separation is enforced at the data layer, not by convention: principal-set resolution
filters `grant_type = 'member'`, so an ownership row is structurally incapable of leaking
into a retrieval filter. This is the no-implicit-admin-read rule applied one level down —
if owning a group implied reading it, delegation would quietly become a privilege-
escalation path.

Rules:

- **Delegation is per-axis.** A group owner administers the *group* axis only. Clearance
  remains workspace-admin-controlled. Nobody should be able to raise someone's clearance
  by way of owning a group.
- **Owners may appoint co-owners.** Otherwise every ownership change funnels back to the
  central admin, which is the bottleneck being removed. Workspace admins can revoke any
  owner, and every ownership change is audited.
- **Mirrored groups have no owners.** Membership is source-owned; an owner row on an
  `ext:` group is rejected, consistent with mirrored-is-read-only.
- **Group names are workspace-visible; membership lists are not.** Names are visible to
  all members so that access can be *requested*; the member list is visible to members,
  owners, and workspace admins. Documents stay omitted-not-locked — that invariant is
  about content, and a group name is not content.
- **Self-service join requests.** A member browses the group directory, requests access,
  and the group's owner approves or declines. This is the mechanism that actually removes
  the admin bottleneck; without it, delegation just moves the queue.

### Decision 2 — Organization above Workspace

**An `organization` exists above workspace and is an administrative + billing container.
It is explicitly *not* a knowledge boundary change.**

**Workspace remains the hard isolation boundary for content. Cross-workspace retrieval
stays out of scope.** That invariant is the product's most load-bearing security promise,
it is stated in the UI, and it keeps the hot path a single `workspace_id` equality rather
than a set membership. Trading it for convenience would be a bad deal.

The fragmentation worry that motivated this question is answered by guidance, not by
architecture:

> **A workspace is a knowledge domain, not an org-chart node.** Most enterprises should run
> **one** workspace and let clearance + groups do the separation — that is precisely what
> the two axes are for. Multiple workspaces are for genuinely separate knowledge domains:
> agency client isolation, pre-close M&A separation, regulated data residency. Telling
> customers "a workspace per department" would manufacture the fragmentation problem, then
> require cross-workspace search to undo it.

**The organization is always present and usually invisible.** Every workspace belongs to
exactly one org; for a small customer it is auto-created at signup and never surfaced in
the UI until there is a second workspace or an enterprise plan. One code path, no
ceremony for small teams, and — critically — no "bolt an org on top of everything"
migration later, which is the expensive version of this decision.

#### What the organization owns

| Concern | Level | Notes |
|---------|-------|-------|
| Billing (customer, subscription, payments, credit pool) | **Organization** | One contract and one invoice for an enterprise; resolves Billing open decision #3 |
| Identity — SSO / IdP / SCIM connection | **Organization** | One connection, not one per workspace |
| `principal_groups` (the group registry) | **Organization** | A group is a set of *people*, an org-level fact — avoids mirroring one Confluence group into twelve workspaces |
| `allowed_principals` on a record | **Workspace** | Which groups gate *this document* is a workspace fact |
| Policy defaults (`clearance_scheme`, retention) | **Organization**, workspace-overridable | Define once, adjust where needed |
| Documents, chunks, edges, retrieval | **Workspace** | Unchanged. The isolation boundary. |

Groups being org-scoped while ACLs stay workspace-scoped does **not** weaken isolation: a
group grants nothing by itself: it is only meaningful when a workspace-isolated document
references it.

#### Org roles

`org_owner`, `org_admin`, `org_billing`. The no-implicit-read rule extends upward without
exception: **an org admin can create workspaces, manage members, connect the IdP, and pay
the bill — and cannot read a single document in any workspace** unless separately granted
membership there. An org role is administrative reach, never content reach.

#### Schema delta

- `organizations` (K): `id`, `name`, `slug`, `created_at`, `updated_at`
- `workspaces.organization_id` UUID NOT NULL → `organizations`
- Billing entities re-anchor from workspace to organization: `billing_customers`,
  `subscriptions`, `payments`, and `billing_email` all move to `organization_id`
  (`UNIQUE (organization_id, provider)`, etc.)
- `organization_credits` becomes the purchased pool; `workspace_credits` becomes an
  **allocation drawn from it** with an optional per-workspace cap. The Phase 1 three-ceiling
  machinery is unchanged — the workspace pool simply gets topped from the org balance
  instead of directly from a purchase.
- `principal_groups.organization_id` replaces `workspace_id`; `principal_grants` stays
  org-scoped alongside it.

#### Migration note

Existing single-workspace customers get a generated org, `workspaces.organization_id`
backfilled, and billing rows re-pointed. Because the org is created eagerly from day one,
this is a data backfill and never a schema-shape change for anyone onboarded afterwards.

---

## Phase 2 — Agent Access & Accountability

**Status**: Decided 2026-07-23 · **Scope**: agents as first-class principals, agent writes,
and resource-level audit

Phase 1 gave agents a good **read** story and deliberately no **write** story: every MCP
tool is read-only ([contracts/mcp-tools.md](./001-contextengine-mvp/contracts/mcp-tools.md),
FR-012). Three things must be added before an agent can "push data into the right place and
be held accountable for it".

> **Mockup/contract drift found while writing this:** the Agents screen's allowed-tools
> picker lists `ingest_document` and `write_memory`, which Phase 1 does not have. Either the
> picker marks them `Phase 2` or the contract changes — it must not silently imply a
> capability the server refuses.

### Decision 1 — An agent is its own principal, bounded by its owner

Today an agent credential is registered by a member and acts with **that member's** access.
That is the classic confused-deputy default (and, honestly, what most agent platforms still
do): an agent that only needs L2 marketing copy inherits its owner's L5 board access.

**Decision: `agent:<uuid>` becomes a fourth principal form, with its own clearance and group
grants, structurally incapable of exceeding its owner's.**

```
effective_clearance(agent)  = min(agent.clearance, owner.clearance)
effective_principals(agent) = agent.principals ∩ owner.principals
```

Both are computed at token-mint time, never stored. That single choice makes **revocation
follow the human automatically**: demote the owner or revoke their group and the agent loses
the same access on its next token — no cleanup job to forget, and no window in which an
agent outlives its owner's authority.

`agent_registry` gains `clearance` alongside its existing `owner_user_id`, and agent grants
live in `principal_grants` next to human ones — one grant table, one audit story.

### Decision 2 — Write is an explicit capability, never inferred from read

`allowed_principals` answers *who may read this*. Nothing in the model answers *who may
write, at what level, and where*. Being able to read a workspace must never imply being able
to add to it.

`agent_policies` gains a write scope:

| Field | Default | Meaning |
|-------|---------|---------|
| `can_write` | `false` | Master switch. Off = read-only, exactly as Phase 1. |
| `write_ops` | `['create']` | Subset of `create` / `update` / `delete`. |
| `write_max_level` | `1` | Highest `access_level` it may tag; must be ≤ its effective clearance. |
| `writable_principals` | `[]` | Groups it may file into; must be ⊆ its effective principals. |
| `write_artifact_types` | `[]` | Typed artifacts it may create; empty = plain documents only. |

Rules:

- **Create-only by default.** An agent that can overwrite the knowledge base has a far larger
  blast radius than one that can only add to it. `update` and `delete` are separate grants
  and should stay rare.
- **Agent deletes are soft deletes** — always `deleted_at`, never a hard row removal.
- **Writes are metered and audited like any other operation** — same `billing.deduct` path,
  same ledger.

### Decision 3 — Derived content never widens access

The dangerous case is not an agent writing where it shouldn't. It is an agent writing
*correctly* and leaking anyway: it reads an L4 document and a `security`-restricted document,
summarises both, and files the summary at L2 with no group. No rule above was broken, and the
content is now readable by people who could read neither source.

**Decision: any artifact written from retrieved context inherits the envelope of its sources.**

```
access_level(write) ≥ max(access_level of sources)
principals(write)   ⊇ the source principal set   (never merged across differing sets)
```

- The write call carries the `trace_id` of the retrieval that produced it, so the server
  **computes** the envelope from what was actually retrieved rather than trusting the agent's
  declared level.
- An agent may choose to be **more** restrictive than the envelope. It may never choose less.
  (Same shape as "groups narrow, never widen".)
- Sources with differing principal sets are **not merged into one artifact** — partition the
  write, or require a human to tag it. This is the rule already adopted for memory
  distillation; it is stated once here and governs memory, agent writes, and mind-map labels
  alike.

### Decision 4 — Agent-authored content is marked, and governed types land as drafts

Without this, agent output is retrieved by the next agent and treated as indistinguishable
from human-authored source material — the knowledge base slowly fills with its own echoes.

- `documents.created_by_agent_id` UUID NULL, badged in the Library and in chat citations.
- For `governed` artifact types an agent write lands `lifecycle_status = 'draft'` and needs
  human promotion to `active`. This reuses the lifecycle machinery already designed for
  authored artifacts instead of inventing a second review queue.
- Retrieval may filter on it (`exclude_agent_authored`) for evaluation runs and for prompts
  that must cite only human-authored sources.

### Decision 6 — LLM routing is a convenience choice, and it is verified

The product intent is that a member can get an agent running **without obtaining or managing a
provider key** — point it at the AISAT gateway and go — or keep using a provider account they
already have. Metering and moderation are *consequences* of the first option, not its purpose.
Earlier drafts of this note framed routing as a governance control and BYOK as an escape
hatch; that reads as disapproval of a legitimate choice and is corrected here.

**The member picks between exactly two things:**

| Choice | Who supplies the LLM credential | AI calls paid by |
|---|---|---|
| **AISAT gateway** (easiest) | AISAT — the member needs no key | Workspace credits |
| **Own AI provider** | The member's existing provider account, or an agent whose vendor runs its own inference | Their provider / the vendor's plan |

**There is no third option, in the data model or the UI.** An earlier draft offered
"the agent brings its own AI" (Copilot-class) as a separate choice. It earns nothing: for every
behaviour the system cares about it is identical to *own provider* — no AI traffic reaches
AISAT, registration issues an MCP credential with no LLM endpoint, workspace credits cover tool
operations only, and long-horizon tasks are unavailable because the worker holds no key. The
*only* thing that differs is whether the member could switch to the gateway if they wanted to,
which is help-text, not behaviour.

So it is captured as an **optional note under the second option** ("this agent can't be pointed
at a gateway"), explicitly labelled as changing nothing except whether AISAT later suggests a
switch the member cannot make.

#### Data model: one fact, one note — never a three-way mode

An earlier draft proposed three routing modes, and a later draft carried that mistake into the
UI as three radio buttons even after the data model had been corrected to two. Both were wrong
for the same reason: *own key* and *vendor built-in* are operationally identical (no AI traffic
through AISAT), so a third value splits one behaviour across two settings — an admin who
disables one believes they have closed a gap that is still open. It is also unverifiable at
registration, and it grows a new value every time a new arrangement appears. **Keep the UI and
the schema in step: two choices, one optional note.**

```
llm_via_gateway   BOOL   — does AI traffic actually run through AISAT?   ← policy reads this
gateway_optout    TEXT   — 'own_key' | 'vendor_builtin' | NULL
                           member-asserted; drives copy and setup help only, never policy
```

FR-026's "admins MUST be able to disable this mode per workspace" becomes one coherent
setting — *require the AISAT gateway for all agents* — which correctly excludes Copilot-class
agents too.

#### Declared vs observed — the check that matters

`llm_via_gateway` is **not** taken on trust. AISAT knows whether AI calls arrive at its proxy
for a given agent credential, so the declared value is continuously checked against observed
traffic. **A mismatch is a first-class condition, surfaced on the Agents screen.**

This is an **onboarding** safeguard before it is a security one. A member chooses the gateway
precisely to avoid fiddling with keys; if it silently fails to take effect — most often a
provider key still exported in the agent's environment, which takes precedence over
`LLM_BASE_URL` — they get none of the benefit, their credits are not being spent, and every
screen reports the agent as fully metered. The failure mode is not "we cannot see this" but
"we believe we can see this and cannot", which is why it sits beside denied operations rather
than in setup documentation.

### Decision 5 — Resource-level audit, visible to the agent's owner

The Phase 1 trail records *actions* (actor, tool, cost, fingerprint, trace). It cannot answer
the question an agent owner actually asks: **"what did my agent change last week?"**

Audit rows gain:

| Field | Notes |
|-------|-------|
| `actor_type` | `user` \| `agent` \| `system` — an agent is never logged as its owner |
| `actor_id` | the `agent:<uuid>` when `actor_type='agent'` |
| `operation` | `create` \| `read` \| `update` \| `delete` |
| `resource_type`, `resource_id` | what was touched |
| `before_hash`, `after_hash` | for updates — hashes, not bodies (L2 retention discipline) |

- **Reads are logged at query granularity, not per chunk.** One retrieval event with counts,
  not one row per returned chunk — otherwise writes become invisible in the noise.
- **An agent's owner can see their own agent's activity without being a workspace admin.**
  Accountability that requires an admin is accountability nobody exercises. Admins see all
  agents; an owner sees theirs.
- The trail is **append-only and outside the access model**: an agent can never read or
  modify its own audit history.

### How this compares to common practice

- **Read scoping** — already ahead of typical agent platforms, most of which hand an agent
  the creator's full permissions.
- **Agent-as-principal with bounded delegation** — standard *outside* AI (cloud service
  accounts, GitHub App installation tokens, OAuth scopes) and rare *inside* it. Adopting it is
  the biggest single differentiator here.
- **Resource-level audit** — table stakes in enterprise SaaS (directory admin audit logs,
  field history). The Phase 1 action-level trail sits below that bar; Decision 5 meets it.

---

## Phase 4 Scalability and Resilience Hardening

**Original title**: Phase 4 Notes — Scalability & Resilience Hardening
**Status**: Backlog / not started · **Created**: 2026-06-20 · **Plan**: [plan.md](./001-contextengine-mvp/plan.md)

These notes capture the work required to take AISAT-STUDIO from its **Phase 1 MVP
provisioning** (Go BFF 2 replicas, 3 Python worker pods per NATS subject, single
Qdrant/NATS cluster, Postgres primary + 1 read replica — see
[plan.md](./001-contextengine-mvp/plan.md) "Scale/Scope") to **resilient operation under tens of
thousands of concurrent users** doing streaming AI chat and media uploads.

Phase 1 is **architecturally sound** for scale (async NATS seam, single LLM
gateway chokepoint, data-layer isolation, idempotent credit ledger, DLQs,
checkpoints). The items below are the *operational and horizontal-scaling*
mechanisms that were intentionally deferred or left unspecified for the MVP.
None of these are required to demonstrate the Phase 1 product; all are required
before high-concurrency production load.

> **Prerequisite already satisfied:** the five *rework-risk* architectural seams
> that must exist before this phase is purely additive are **locked in Phase 1**
> — JetStream durability, a separable SSE-relay tier, a workspace-partitionable
> credit outbox, a documented Qdrant re-shard trigger, and single-owner scheduled
> work in a dedicated `cmd/worker` role (external CronJob → NATS tick → queue group,
> idempotent atomic claims — so autoscaling never double-fires a timer; see
> [research.md §14–§15](./001-contextengine-mvp/research.md) and [plan.md](./001-contextengine-mvp/plan.md) "Scale/Scope"). Phase 4
> is therefore provisioning + HA + load validation, not redesign.

> Phase map: Phase 1 = Core App · Phase 2 = Evaluation Suite (+ Headroom eval) ·
> Phase 3 = Automated security red-teaming · **Phase 4 = Scale & Resilience
> Hardening (this doc)**.

### P0 — Blocking for high concurrency

#### 1. Worker autoscaling (KEDA on NATS consumer lag)
- **Gap**: Worker pools are fixed at 3 pods/subject; KEDA was explicitly deferred
  to Phase 2 but never actually scheduled
  ([contracts/nats-subjects.md](./001-contextengine-mvp/contracts/nats-subjects.md) "Per-subject scaling").
  A fixed pool turns a traffic spike into unbounded NATS queue depth and rising
  query latency.
- **Do**: Add KEDA `ScaledObject` per NATS subject keyed on consumer lag /
  pending-message count. Define min/max replica bounds per subject
  (`query.agent.*`, `ingestion.*`, `notify.*`, `billing.deduct.*`). Validate
  scale-up/down under synthetic load.

#### 2. SSE connection ceiling & backpressure
- **Gap**: Every chat, every in-progress ingestion, and every notification inbox
  is a **long-lived SSE stream** held on the BFF
  ([contracts/sse-events.md](./001-contextengine-mvp/contracts/sse-events.md)). Tens of thousands of
  concurrent users implies 30k–100k+ simultaneous open connections across only
  2 BFF replicas. No per-instance connection cap, FD budget, idle-timeout, or
  SSE heartbeat policy is specified. **This is the single biggest scaling risk.**
- **Do**: Set a per-BFF-instance max concurrent SSE connection limit + graceful
  rejection (`503` with retry hint) when exceeded; autoscale BFF replicas on
  active-connection count, not just CPU; add SSE keep-alive/heartbeat + server
  idle timeout to reclaim dead connections; load-test concurrent
  chat+ingest+notification streams to find the real per-pod ceiling.

#### 3. Postgres connection pooling (PgBouncer)
- **Gap**: No connection pooler is specified. RLS uses `SET LOCAL
  app.workspace_id` per transaction
  ([data-model.md](./001-contextengine-mvp/data-model.md)), making connection lifecycle critical. At
  high concurrency, `max_connections` exhaustion is a classic failure mode.
- **Do**: Introduce PgBouncer (transaction pooling, compatible with `SET LOCAL`),
  size pools per service, document read/write split to the existing read replica,
  and add replica-lag handling for read-after-write paths.

#### 4. NATS JetStream flow control & load shedding
- **Gap**: No `MaxAckPending`, `ack_wait`, max queue depth, or stream
  retention/limits are specified. A slow consumer (LLM latency spike) can grow
  the stream until memory pressure or redelivery storms occur.
- **Do**: Configure bounded in-flight (`MaxAckPending`), sensible `ack_wait`,
  stream size/age limits, and an explicit overload/load-shedding policy (reject
  new queries with a clear `429`/`503` rather than degrade silently).

### P1 — Important for sustained load & availability

#### 5. Qdrant HA & scale-out
- **Gap**: "Single Qdrant cluster", no sharding, replication, or quantization
  ([plan.md](./001-contextengine-mvp/plan.md)). Dual-collection hybrid search (BM25/SPLADE + dense +
  rerank) on every query is CPU/RAM-heavy; one unreplicated node is a bottleneck
  and a SPOF on the core read path.
- **Do**: Add replication (failover) + sharding plan for the `personal` and
  `workspace` collections; evaluate scalar/product quantization for memory
  headroom; capacity-test hybrid query throughput.

#### 6. Redis high availability
- **Gap**: One Redis cluster with logical DB/key-prefix role separation but no
  documented Sentinel/Cluster failover
  ([research.md §10](./001-contextengine-mvp/research.md)). Redis holds the authoritative hot credit
  balance, LangGraph checkpoints, rate-limit counters, **and** SSE pub/sub — a
  loss degrades billing, streaming, and recovery at once.
- **Do**: Execute the Phase-2-anticipated split into independent clusters per
  durability profile; add Sentinel/Cluster failover; verify cold-start
  rehydration and hourly reconciliation behave correctly across a failover.
  **Locks are not the correctness boundary** (DB constraints are — [research.md §10/§15](./001-contextengine-mvp/research.md));
  the Cluster-specific work is: hash-tag each workspace's keys onto one slot,
  accept `DECRBY` balance drift as an RPO/reconcile concern, and treat
  rate-limit counters + the opaque session store as fail-safe.

#### 7. Operational resilience primitives
- **Gap**: No readiness/liveness probes, graceful drain (esp. for in-flight SSE
  on deploy/rollout), or hot-path request timeouts are documented.
- **Do**: Add `/healthz` liveness + `/readyz` readiness probes for every service;
  implement graceful shutdown that drains/relays SSE before termination; set
  explicit timeouts on synchronous hot-path calls (DB, Redis, downstream HTTP).

#### 8. S3 / ingestion burst handling
- **Gap**: Direct-to-S3 presigned upload keeps payloads off app servers (good),
  but there's no documented throttle on presign issuance or ingestion-fan-in
  rate. A media-upload burst from thousands of users can flood
  `ingestion.*` subjects faster than the fixed worker pool drains.
- **Do**: Rate-limit presign issuance per workspace/user; ensure ingestion
  autoscaling (item 1) covers burst fan-in; confirm DLQ + retry behavior under
  sustained backlog.

### P2 — Validation & guardrails

#### 9. Load & soak testing harness
- **Gap**: No throughput target (RPS/QPS), no concurrency target, and no
  load-test plan exist. The only stated budget is API p95 < 200ms (non-LLM)
  ([plan.md](./001-contextengine-mvp/plan.md) "Performance Goals").
- **Do**: Define explicit SLOs (target concurrent users, RPS, SSE connections,
  p95/p99 per path). Build a k6/locust harness for the critical journeys:
  - Concurrent streaming chat (sustained open SSE + token streaming).
  - Media-upload bursts (presign → S3 → ingestion fan-in).
  - Mixed steady-state (chat + ingest + notifications + credit deducts).
  Run soak tests to surface connection leaks, queue growth, and replica-lag.

#### 10. Per-tenant fairness / noisy-neighbor isolation
- **Gap**: Credit ceilings bound *cost*, but nothing bounds a single workspace's
  share of *compute* (worker slots, Qdrant CPU, DB connections) under contention.
- **Do**: Add per-workspace concurrency fairness (e.g., per-tenant in-flight
  query cap or weighted queueing) so one heavy tenant can't starve others.

### Cross-references
- Existing strengths to preserve: async query path
  ([research.md §6](./001-contextengine-mvp/research.md)), idempotent credit ledger
  ([research.md §3](./001-contextengine-mvp/research.md)), one-hop LLM fallback + circuit breaker
  ([contracts/llm-gateway.md](./001-contextengine-mvp/contracts/llm-gateway.md)), DLQs + heartbeat
  re-queue ([contracts/nats-subjects.md](./001-contextengine-mvp/contracts/nats-subjects.md),
  [data-model.md](./001-contextengine-mvp/data-model.md)), partitioned tables
  ([data-model.md](./001-contextengine-mvp/data-model.md)).
- These items add **horizontal scale + HA + operational hardening** on top of
  that foundation; they do not change the Phase 1 contracts.


