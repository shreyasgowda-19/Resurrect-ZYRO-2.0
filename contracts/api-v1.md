# Inventory API v1

Local base URL: `http://127.0.0.1:8000`.

From `backend/`, start the server with:

```powershell
.\.venv\Scripts\python.exe -m uvicorn app.main:app --host 127.0.0.1 --port 8000
```

## Health check

| Method | Path | Expected status | Response content type |
| --- | --- | --- | --- |
| GET | `/health` | `200 OK` | `application/json` |

```json
{
  "status": "ok",
  "service": "inventory-api"
}
```

Interactive API documentation is available at `/docs`.

## Current user

Send `GET /auth/me` with `Authorization: Bearer FIREBASE_ID_TOKEN`.

| Status | Meaning |
| --- | --- |
| 200 OK | Valid Firebase ID token with a `planner` or `approver` custom claim |
| 401 Unauthorized | Missing or invalid Firebase ID token |
| 403 Forbidden | Valid token without an authorized role |
| 503 Service Unavailable | Firebase authentication is temporarily unavailable |

A successful response has content type `application/json`.

```json
{
  "uid": "firebase-user-id",
  "email": "planner@example.com",
  "role": "planner"
}
```

The `email` field is null when the verified ID token has no email claim.

## Inventory state

Send `GET /state` with `Authorization: Bearer FIREBASE_ID_TOKEN`. The authorized roles are `planner` and `approver`.

| Status | Meaning |
| --- | --- |
| 200 OK | Read-only synthetic inventory snapshot |
| 401 Unauthorized | Missing or invalid Firebase ID token |
| 403 Forbidden | Valid token without an authorized role |
| 503 Service Unavailable | A required service is unavailable |

Example excerpt from the HTTP 200 JSON response. The full snapshot includes all six materials and ten orders.

```json
{
  "version": 1,
  "as_of_date": "2026-12-01",
  "data_mode": "demo",
  "materials": [
    {
      "material_id": "MAT-COPPER",
      "name": "Copper",
      "unit": "busbar blanks",
      "on_hand": 600,
      "incoming": 400,
      "allocated": 1000,
      "net_available": 0
    }
  ],
  "orders": [
    {
      "order_id": "ORD-1042",
      "customer": "Demo Harbor Switchgear",
      "priority": "high",
      "crd": "2026-12-10",
      "material_ready_date": "2026-12-05",
      "projected_ship_date": "2026-12-07",
      "projected_delivery_date": "2026-12-08",
      "slack_days": 2,
      "risk": "on_track",
      "shortages": []
    }
  ]
}
```

Priorities are `high`, `medium`, and `low`. Risk values are `on_track`, `at_risk`, `critical`, and `delayed`.

Dates use `YYYY-MM-DD`. Quantities are non-negative integers, while `net_available` is an integer. Unavailable readiness, ship and delivery dates, and slack are `null`. Each shortage contains `material_id` and the integer fields `required`, `available`, and `shortage`. Availability for a shortage is evaluated when that order is considered.

Incoming totals include confirmed outstanding lots with an ETA on or after the snapshot date. The backend is authoritative for inventory and risk calculations. The frontend displays these values as returned. T2 serves a persisted demonstration snapshot and extends the response as described below.

## Demonstration events and persisted state

T2 preserves all existing `GET /state` fields. The response adds:

| Field | Entry fields |
| --- | --- |
| `supply_lots` | `lot_id`, `material_id`, `supplier_id`, `eta`, `remaining_quantity`, `status` |
| `order_requirements` | `order_id`, `material_id`, `required_quantity` |
| `recent_events` | `event_id`, `event_type`, `summary`, `version`, `recorded_at` |
| `alerts` | `alert_id`, `order_id`, `previous_risk`, `new_risk`, `message`, `event_id`, `version` |

`recent_events` and `alerts` each contain up to 20 entries, newest version first. `recorded_at` is a UTC timestamp. The demo uses `data_mode="demo"` and `as_of_date="2026-12-01"`. `GET /state` reads Firestore without modifying it and returns HTTP 503 when the persisted state cannot be read. The frontend polls every five seconds while the authenticated dashboard is active and refreshes immediately after event success. All business calculations come from the backend. Flutter accesses business data through the API.

### Submit an event

Send `POST /events` with `Content-Type: application/json` and `Authorization: Bearer FIREBASE_ID_TOKEN`. Planners can submit events. Approvers can read the state.

| `event_type` | Payload | Constraints |
| --- | --- | --- |
| `supplier_eta_update` | `lot_id`, `new_eta` | Confirmed lot with outstanding quantity. ETA on or after the demo date. |
| `material_receipt` | `lot_id`, `quantity` | Positive integer no greater than the outstanding quantity. |
| `stock_adjustment` | `material_id`, `quantity_delta` | Signed, nonzero integer. Stock cannot become negative. |
| `order_change` | `order_id` with `new_crd`, `material_id` plus `new_required_quantity`, or both changes | Existing order and existing requirement. Required quantity is a non-negative integer. |

Use calendar dates in `YYYY-MM-DD` format. Every accepted event increments the version once. An identical replay by the same actor returns HTTP 200 with status `duplicate` and the original applied version. An identical replay uses the original request body, including its `expected_version`.

Example request for the demo Copper lot at version 1.

```json
{
  "event_id": "demo-copper-eta-delay",
  "event_type": "supplier_eta_update",
  "expected_version": 1,
  "payload": {"lot_id": "LOT-01", "new_eta": "2026-12-08"}
}
```

```json
{"event_id": "demo-copper-eta-delay", "status": "applied", "version": 2}
```

On replay:

```json
{"event_id": "demo-copper-eta-delay", "status": "duplicate", "version": 2}
```

| Status | Meaning |
| --- | --- |
| 401 | Missing or invalid authentication |
| 403 | Unauthorized role |
| 404 | Referenced entity or existing requirement not found |
| 409 | Stale expected version or conflicting event ID |
| 422 | Invalid event data or invalid business operation |
| 503 | Required service unavailable |

Event errors contain a stable code and a message. A stale event returns HTTP 409 with this response.

```json
{"detail": {"code": "STALE_VERSION", "message": "Refresh the dashboard before submitting another event."}}
```

## Recommendations and what-if simulation

Planners and approvers can use both endpoints with a Firebase Bearer ID token. Each request reads a single authoritative snapshot and requires its current `expected_version`. Both endpoints are read-only.

### `POST /recommendations`

```json
{"order_id":"ORD-1042","expected_version":2}
```

The response includes `order_id`, `version`, `data_mode`, and `recommendations`. An empty array means the backend found no modeled improvement using the supported actions. Example excerpt for the demo after `LOT-01` is delayed to 2026-12-08.

```json
{
  "order_id": "ORD-1042",
  "version": 2,
  "data_mode": "demo",
  "recommendations": [
    {
      "recommendation_id": "rec-9c5609ce75920e06e014db074dd0c789b06c4c14e51d1e56a3ccff2e61965699",
      "action_type": "expedite_existing_lot",
      "title": "Explore expediting LOT-01",
      "explanation": "If the proposed ETA 2026-12-05 is achieved, the modeled delivery is 2026-12-08 (on_track). Recovery depends on the stated assumptions.",
      "material_id": "MAT-COPPER",
      "supplier_id": "SUP-01",
      "lot_id": "LOT-01",
      "quantity": 400,
      "proposed_eta": "2026-12-05",
      "estimated_incremental_cost": null,
      "currency": null,
      "assumptions": [
        "Synthetic demo scenario assumes up to three days of acceleration. Supplier willingness and fees are unverified.",
        "Incremental cost and currency are unknown."
      ],
      "evidence": [
        "Order ORD-1042 has high priority and CRD 2026-12-10.",
        "MAT-COPPER: 1000 required and 1000 committed to this order in the snapshot.",
        "Baseline projected delivery: 2026-12-11 (critical).",
        "Confirmed lot LOT-01 from Demo Allied Metals has 400 outstanding, ETA 2026-12-08."
      ]
    }
  ]
}
```

The other supported action is `alternate_supplier_po`, which has `lot_id: null`. A recommendation ID binds the version, order, and canonical action parameters. Use the ID returned for the current snapshot.

### `POST /simulate`

```json
{
  "order_id":"ORD-1042",
  "recommendation_id":"rec-9c5609ce75920e06e014db074dd0c789b06c4c14e51d1e56a3ccff2e61965699",
  "expected_version":2
}
```

The response includes `order_id`, `recommendation_id`, `version`, `hypothetical: true`, `before`, `after`, `affected_orders`, `estimated_incremental_cost`, `currency`, `assumptions`, and `warnings`. Each outcome contains `projected_ship_date`, `projected_delivery_date`, `slack_days`, and `risk`. Each affected order provides `order_id`, `before`, and `after`. Only other orders with changed outcomes are included. Dates use `YYYY-MM-DD`. Missing projected dates and slack, and unknown cost and currency, are `null`.

| Status | Meaning |
| --- | --- |
| 401 | Missing or invalid Firebase ID token |
| 403 | Unauthorized role |
| 404 | Unknown order or recommendation for the current snapshot |
| 409 | Stale snapshot version |
| 422 | Invalid request |
| 503 | Required service unavailable |

Errors use `{"detail":{"code":"STALE_VERSION","message":"Refresh the dashboard before requesting a new calculation."}}` or the corresponding error code and message.
