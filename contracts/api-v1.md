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

## Human approval and demo purchase orders

All three endpoints require a Firebase Bearer ID token. Use `POST /recommendations` to obtain a canonical recommendation ID for the current snapshot.

### `POST /proposals`

Planners submit an order, recommendation, and expected inventory version.

```json
{
  "order_id": "ORD-1042",
  "recommendation_id": "rec-e055092ec625a4378dd2d20f3e024106b91599eaa866d415cdd200c86f94eab4",
  "expected_version": 2
}
```

HTTP 200 returns `status` (`created` or `duplicate`), the current inventory `version`, and a `proposal` object. The same planner can repeat the identical request and receive the existing proposal. The proposal stores the server-generated recommendation and simulation. Submission leaves the inventory version and facts unchanged.

### `GET /proposals`

Planners and approvers receive `version`, `proposals`, `purchase_orders`, and `audit_logs`. All pending proposals appear first, followed by up to 20 completed proposals. Each group is ordered newest submission first, with descending proposal ID as the tie breaker. Purchase orders and audit logs are each limited to 20 and ordered newest first, with descending document ID as the tie breaker.

A proposal contains `proposal_id`, `order_id`, `recommendation_id`, `action_type`, `snapshot_version`, `status`, `is_stale`, `created_by`, `created_at`, `recommendation`, `simulation`, `decided_by`, `decided_at`, `decision_reason`, `purchase_order_id`, and `execution_status`. Status is `pending`, `approved`, or `rejected`. Execution status is `not_executed`, `demo_po_created`, or `awaiting_supplier_confirmation`. Pending proposals are stale when their snapshot version differs from the current version. Decision details and PO ID are null until applicable.

A purchase order contains `purchase_order_id`, `proposal_id`, `order_id`, `supplier_id`, `material_id`, `quantity`, `expected_delivery_date`, `estimated_incremental_cost`, `currency`, `status`, `created_by`, and `created_at`. Status is always `demo_created`. Expected delivery uses `YYYY-MM-DD`, unknown cost and currency are null, and timestamps use ISO 8601.

An audit entry contains `audit_id`, `action`, `actor_uid`, `actor_role`, `proposal_id`, `timestamp`, `version`, and `summary`. Actions are `proposal_submitted`, `proposal_approved`, `proposal_rejected`, `purchase_order_created`, and `expedite_authorized`.

### `POST /proposals/{proposal_id}/decision`

Approvers supply a unique decision ID. Both approval and rejection require a reason. An approval also requires acknowledgment of the synthetic supplier assumptions and a different UID from the proposal creator.

```json
{
  "decision_id": "copper-decision-001",
  "decision": "approve",
  "expected_version": 2,
  "reason": "Reviewed the modeled recovery and supplier assumptions.",
  "acknowledge_demo_assumptions": true
}
```

HTTP 200 returns `status` (`applied` or `duplicate`), `version`, the decided `proposal`, and `purchase_order` (null where applicable). Retrying the identical decision with the same approver and decision ID returns the original result and version, even if newer inventory versions exist.

Alternate-supplier approval creates one demo PO and one synthetic incoming lot and increments inventory version once. Rejection and expedite authorization leave the version and facts unchanged. An authorized expedite waits for confirmation. An actual or explicitly simulated confirmation can later be recorded through the existing supplier ETA event. A stale pending proposal can be rejected using the current version.

| Status | Meaning |
| --- | --- |
| 401 | Missing or invalid authentication |
| 403 | Unauthorized role or self-approval |
| 404 | Unknown proposal or recommendation |
| 409 | Stale version, evidence mismatch, existing proposal conflict, or incompatible decision |
| 422 | Invalid request |
| 503 | Required service unavailable |

Errors use the existing `{"detail":{"code":"...","message":"..."}}` envelope.

## Manufacturing AI copilot

Both endpoints require a Firebase Bearer ID token for a planner or approver. They only read backend data.

### `POST /ai/ask`

Send a question of 1 to 1000 characters and the current inventory version. `order_id` may be null. A recognizable order ID in the question can also identify the order.

```json
{"question":"Why was ORD-1042 at risk?","order_id":"ORD-1042","expected_version":3}
```

HTTP 200 returns `version`, `role`, `mode`, `answer`, `evidence`, `suggested_questions`, and `warnings`. The mode is `gemini` when a verified Gemini selection is used, or `deterministic_fallback` when the backend selects evidence. Evidence entries contain `evidence_id`, `source_type`, `source_id`, and `summary`. Source types are `inventory`, `order`, `supplier`, `event`, `alert`, `recommendation`, `simulation`, `proposal`, `purchase_order`, and `audit`.

### `GET /ai/briefing`

HTTP 200 returns `version`, `role`, `mode`, `headline`, `summary`, `insights`, and `warnings`. Each insight contains `title`, `description`, `severity` (`info`, `warning`, or `critical`), `order_id` (nullable), `evidence`, and `suggested_question`.

Planner briefings prioritize order risk, shortages, supplier delays, and recovery. Approver briefings prioritize pending and stale proposals, demo POs, and audit status. Current risk, historical changes, and hypothetical recovery evidence are labeled separately.

| Status | Meaning |
| --- | --- |
| 401 | Missing or invalid authentication |
| 403 | Unauthorized role |
| 404 | Unknown order |
| 409 | The expected inventory version is stale |
| 422 | Invalid request |
| 503 | Firebase authentication service or authoritative backend data unavailable |

Errors use the existing `{"detail":{"code":"...","message":"..."}}` envelope. If a freshness recheck detects a proposal or approval change without an inventory version change, the response uses refreshed backend evidence and reports `deterministic_fallback`.

## T8.1 operational workspaces

The existing demonstration endpoints retain their contracts. An operational request always names its workspace in the route. Workspace IDs are lowercase, 32-character hexadecimal UUIDs generated by the backend during provisioning.

Both routes below require a Firebase Bearer ID token. The backend verifies the token and derives the caller's planner or approver role from active membership keyed by the verified Firebase UID. Client-supplied role values and the demo role claim do not grant operational access.

### GET /workspaces/{workspace_id}

HTTP 200:

```json
{"workspace_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","name":"Manufacturing workspace","role":"planner","data_mode":"operational"}
```

`workspace_id` and `name` are strings. `role` is `planner` or `approver`. `data_mode` is always `operational`.

### GET /workspaces/{workspace_id}/state

HTTP 200 returns the same inventory fields and item shapes as `GET /state`, with `workspace_id` and the caller's current workspace `role` added, and `data_mode` set to `operational`. A newly provisioned workspace begins at version 1 with an explicit calendar date and empty inventory lists.

```json
{
  "workspace_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "role": "approver",
  "version": 1,
  "as_of_date": "2026-12-01",
  "data_mode": "operational",
  "materials": [],
  "orders": [],
  "supply_lots": [],
  "order_requirements": [],
  "recent_events": [],
  "alerts": []
}
```

| Status | Meaning |
| --- | --- |
| 401 | Missing or invalid Firebase ID token |
| 403 | Workspace unavailable to the caller, including unknown workspace, missing or inactive membership, or invalid workspace role |
| 422 | Malformed workspace ID |
| 503 | Authentication or operational storage unavailable, including invalid stored workspace data |

Errors use `{"detail":{"code":"...","message":"..."}}`. Both routes are read-only. No public provisioning, operational mutation, or workspace discovery endpoint is introduced in T8.1. The dashboard treats HTTP 200 with empty lists as an empty workspace and marks retained data stale after a transient failure. A 401 or 403 invalidates the displayed data. No operational failure falls back to demonstration data.

## T8.2 operational materials

The operational state endpoint adds `reorder_threshold` (non-negative integer) and `description` (nullable string) to each material. Demo responses retain their existing shape.

- `POST /workspaces/{workspace_id}/materials` creates a material. Send `material_id`, `name`, `unit`, `reorder_threshold`, `expected_version`, and `mutation_id`. `description` is optional. The new material has zero physical stock.
- `PATCH /workspaces/{workspace_id}/materials/{material_id}` edits metadata. Send `expected_version`, `mutation_id`, and at least one of `name`, `unit`, `reorder_threshold`, or `description`. Null clears the description. The ID and stock cannot be edited.

IDs are case-insensitive and stored in uppercase. They must contain 1 to 64 letters, digits, dots, underscores, or hyphens, starting with a letter or digit. Names and units have limits of 120 and 32 characters. Descriptions have a limit of 500 characters. Reorder thresholds are integers from 0 to 9007199254740991. Mutation IDs are nonempty strings up to 128 characters.

Both endpoints require Firebase authentication and an active Planner membership in the selected workspace. HTTP 200 returns `status` (`applied` or `duplicate`), `workspace_id`, `version`, and `material` (same shape as the operational state material). A successful write increments the version once. An identical retry by the same actor with the same mutation ID returns the original result even if the version has advanced.

| Status | Meaning |
| --- | --- |
| 401 | Missing or invalid authentication |
| 403 | Workspace unavailable to caller or Planner membership required |
| 404 | Material to edit does not exist |
| 409 | Stale version, duplicate material ID, or mutation ID conflict |
| 422 | Invalid input, including a stock field or an immutable ID in an edit body |
| 503 | Authentication or workspace storage unavailable |

Errors use the existing structured `detail` envelope. Mutation IDs and audit entries are scoped to the workspace. Both are written atomically with the inventory change.
