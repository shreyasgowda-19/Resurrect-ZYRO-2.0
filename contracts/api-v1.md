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
