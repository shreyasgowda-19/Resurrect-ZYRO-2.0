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
