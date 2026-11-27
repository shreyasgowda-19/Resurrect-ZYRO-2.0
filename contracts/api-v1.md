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

Incoming totals include confirmed outstanding lots with an ETA on or after the snapshot date. The backend is authoritative for inventory and risk calculations. The frontend displays these values as returned. The demo uses a fixed version and does not read or write business data in Firestore. Real-time events and persistent versions are reserved for T2.
