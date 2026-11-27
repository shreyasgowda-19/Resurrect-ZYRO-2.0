# Deterministic demo inventory

The fictional Riverside Electrical Assembly plant uses a snapshot date of 2026-12-01. The snapshot contains six raw materials, four suppliers, ten open customer orders, and six incoming supply lots.

- Physical on-hand stock is available on the snapshot date. The incoming total includes only confirmed outstanding lots with an ETA on or after that date. Unconfirmed, cancelled, received, and overdue unreceived lots are excluded. Once received, a lot belongs in the physical count.
- Orders sort by priority (high, medium, low), requested delivery date (CRD), creation timestamp, and order ID. Each material is allocated from physical stock first, then from eligible lots ordered by ETA and lot ID. Reservations commit only when every requirement can be fulfilled. A failed order reports exact shortages and leaves stock available to later orders.
- Net availability equals physical on-hand plus eligible incoming minus committed reservations. Reserving stock does not change the physical count.
- Readiness is the latest availability date across all reservations for an order. Add production calendar days for the ship date and transit calendar days for delivery. Slack equals CRD minus projected delivery. An unresolved shortage leaves readiness, shipment, delivery, and slack null.
- An open order is delayed if its CRD has passed. Otherwise, a shortage or negative slack is critical, slack of zero or one is at risk, and slack of two or more is on track.

For ORD-1042, the engine reserves 600 on-hand copper units and 400 incoming units. The baseline ships on 2026-12-07, delivers on 2026-12-08, and has two days of slack. A three-day ETA slip shifts delivery to 2026-12-11 and makes the order critical.
