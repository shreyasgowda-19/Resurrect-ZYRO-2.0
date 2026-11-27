# Deterministic demo inventory

The fictional Riverside Electrical Assembly plant uses a snapshot date of 2026-12-01. The snapshot contains six raw materials, four suppliers, ten open customer orders, and six incoming supply lots.

- Physical on-hand stock is available on the snapshot date. The incoming total includes only confirmed outstanding lots with an ETA on or after that date. Unconfirmed, cancelled, received, and overdue unreceived lots are excluded. Once received, a lot belongs in the physical count.
- Orders sort by priority (high, medium, low), requested delivery date (CRD), creation timestamp, and order ID. Each material is allocated from physical stock first, then from eligible lots ordered by ETA and lot ID. Reservations commit only when every requirement can be fulfilled. A failed order reports exact shortages and leaves stock available to later orders.
- Net availability equals physical on-hand plus eligible incoming minus committed reservations. Reserving stock does not change the physical count.
- Readiness is the latest availability date across all reservations for an order. Add production calendar days for the ship date and transit calendar days for delivery. Slack equals CRD minus projected delivery. An unresolved shortage leaves readiness, shipment, delivery, and slack null.
- An open order is delayed if its CRD has passed. Otherwise, a shortage or negative slack is critical, slack of zero or one is at risk, and slack of two or more is on track.

For ORD-1042, the engine reserves 600 on-hand copper units and 400 incoming units. The baseline ships on 2026-12-07, delivers on 2026-12-08, and has two days of slack. A three-day ETA slip shifts delivery to 2026-12-11 and makes the order critical.

## Persisted demonstration

The API uses the Firestore document `zyro_demo_inventory/current`. It stores raw demo facts, the authoritative version, and the latest 20 events and risk alerts. The `events` subcollection stores the complete accepted event history, including the original normalized request and actor UID for replay checks. The `alerts` subcollection stores escalation records independently of the bounded response history. Each event transaction updates all affected records atomically.

Run the initializer from `backend\` in Windows CMD, using the demo project's Application Default Credentials.

```cmd
set "GOOGLE_APPLICATION_CREDENTIALS=%USERPROFILE%\zyro-secrets\firebase-admin.json"
.venv\Scripts\python.exe -m scripts.init_demo_inventory
```

The initializer creates version 1 only if the authoritative document is absent. API startup and GET requests never initialize or reset the state. If the network uses a certificate authority trusted by Windows that gRPC cannot find, configure `GRPC_DEFAULT_SSL_ROOTS_FILE_PATH` and `REQUESTS_CA_BUNDLE` to a trusted PEM bundle for that terminal.

The Copper demo lot is `LOT-01`. Submit a `supplier_eta_update` to move its ETA from 2026-12-05 to 2026-12-08. At version 1, this produces version 2 and escalates `ORD-1042` from `on_track` to `critical`. Alerts include the triggering change and the resulting delivery slack, shortages, or overdue CRD.

For receipts, each unit increases physical on-hand and decreases the lot's outstanding quantity. The lot becomes received at zero outstanding units. Zeroing an existing material requirement retains the requirement for future changes, and an order with no positive requirements is ready on the demo date.

## Recovery recommendations and simulation

T3 considers at-risk, critical, and delayed orders and offers single actions only when the same allocation engine improves the target outcome. It compares risk severity first and earlier delivery within the same risk category. An overdue order can still benefit from earlier delivery while remaining delayed. A candidate can affect other orders because the allocator recalculates the entire snapshot.

- Expedite a confirmed existing lot with a future ETA. The hypothetical scenario brings the ETA forward by up to three calendar days, with arrival no earlier than the day after the snapshot date. The lot ID and outstanding quantity are unchanged.
- The only modeled alternate capability is explicitly synthetic. Existing demo supplier `SUP-02` can hypothetically supply up to 400 Copper units in four calendar days. The scenario adds a new incoming lot and leaves on-hand stock unchanged. Supplier capacity, willingness, actual lead time, currency, and incremental cost are unverified. Unknown costs and currency are returned as null.

The simulation endpoint rebuilds candidates from the current snapshot before accepting an ID. If an event changes the version, refresh the state and request recommendations again. Each scenario is conditional on the stated assumptions. The endpoints leave Firestore, supplier communications, and purchase-order creation untouched.

## Proposal decisions and demo procurement

Proposals bind the target order, recommendation, and inventory version. Planners submit them without mutating inventory. Approvers review the stored evidence. The server regenerates that evidence for approval against the proposal's original version and the current facts. Only an approval that creates a demo purchase order increments inventory version.

The inventory document has four additional Firestore subcollections.

| Subcollection | Contents |
| --- | --- |
| `proposals` | Deterministic proposal records and complete recommendation and simulation evidence |
| `proposal_decisions` | Normalized decision request, approver UID, and original response for replay |
| `purchase_orders` | Demo PO, associated incoming lot ID, and explicit synthetic supplier commitment marker |
| `proposal_audit` | Append-only audit records from backend transactions |

The same Firestore transaction persists the decision, audit records, and any PO and inventory updates. All reads occur before writes. The PO contributes incoming supply as confirmed only within the demo model, and the allocator recalculates the whole inventory. Physical stock changes only through existing inventory events. Expedite authorization records the approver's decision while preserving the lot ETA until a confirmation event.

The list endpoint uses one read-only transaction for a consistent inventory version, proposal statuses, and history. It reads all demo proposals so pending proposals cannot be hidden by the 20-record completed history limit. PO and audit displays each show the most recent 20 records. The underlying audit and decision records are retained.

## Read-only AI copilot

The copilot reads inventory and the proposal, purchase order, and audit view in one Firestore read-only transaction. It checks freshness again before responding. A stale question returns HTTP 409. If approvals change at the same inventory version, the copilot renders the refreshed facts locally. Briefings have no client-supplied version and use the refreshed view when it changes.

Gemini receives up to 40 allowlisted manufacturing terms and metadata for up to 24 evidence options. It receives no raw questions, evidence summaries, business values, actor identities, tokens, or credentials in the prompt. It returns one focus label and up to six opaque evidence IDs. The backend rejects unknown or duplicate IDs, unexpected fields, and unsupported focus labels, and renders all answer text from verified evidence. The Gemini request uses an eight-second transport and wall-clock deadline, with one SDK attempt and at most one provider call in flight per process. An immediate provider failure uses the current consistent read for fallback. Successful selections and longer attempts recheck freshness. Uvicorn logs only configuration presence, processing durations, outcome categories, and response mode. Timeouts, quota errors, and invalid responses use deterministic fallback. Missing authoritative data returns HTTP 503.

Recommendation simulations are hypothetical. Demo POs represent simulated supplier commitments. Unknown costs remain unavailable. Event and approval evidence is drawn from the existing bounded recent-history views, and the local question parser supports a limited manufacturing vocabulary. Neither endpoint exposes tools or writes business data.

Use the existing server-side `GEMINI_API_KEY` and `GEMINI_MODEL` configuration. The T0-documented model is `gemini-3.1-flash-lite`. From `backend\` in Windows CMD, run the existing connectivity diagnostic with the key already set privately.

```cmd
set "GEMINI_MODEL=gemini-3.1-flash-lite"
.venv\Scripts\python.exe -m scripts.check_gemini
```
