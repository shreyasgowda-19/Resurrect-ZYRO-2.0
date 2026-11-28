# Operational workspace foundation

T8.1 introduced a separate operational dashboard. T8.2 adds Planner-only material management. The demo API and its existing routes retain their behavior. Operational selection never redirects to demo storage or demo routes.

## Single-laptop workflow

M2 can edit both stacks for the approved T8.1 change on the backend branch. Member 1 retains frontend review and Member 2 retains backend review. For independent work, use the respective frontend and backend branches on M2. Review shared changes before committing or pushing. Integrate reviewed changes through pull requests into main.

## Firestore schema and access

| Path | Contents |
| --- | --- |
| `zyro_workspaces/{workspace_id}` | `name` and `inventory` containing version, manufacturing facts, recent events and alerts |
| `zyro_workspaces/{workspace_id}/members/{firebase_uid}` | `role` (planner or approver) and explicit boolean `active` |

The workspace ID is a server-generated lowercase UUID without hyphens. Provisioning accepts a workspace name, an as-of date, and explicit Firebase UID-to-role assignments. The initial inventory is version 1 with workspace plant metadata and empty materials, suppliers, supply lots, orders, events, and alerts. No demo rows are copied.

Both GET endpoints check the verified Firebase UID and active membership in the requested workspace. An operational member is authorized by their workspace role independently of the legacy demo role claim. The server rejects unsafe UID document identifiers. Membership and the workspace document are read in one read-only transaction. Missing workspaces and unauthorized workspaces produce the same 403 response.

The internal provisioning method uses create-only writes in one transaction for the workspace and all memberships. It is intended for a trusted administrator using server credentials. T8.1 provided read-only operational routes. There is no public provisioning route. T8.2 permits material metadata writes only; operational events, approvals and POs remain outside this phase. Any future operational event, decision, audit, or idempotency records belong under that same workspace root. Existing demo write paths and version and replay checks remain in place.

The Flutter client uses the FastAPI API with a Firebase token and makes no direct Firestore calls. Review deployed Firestore Security Rules before rollout to ensure browsers cannot access operational roots directly. This change neither deploys rules nor verifies the deployed rules.

## Test locally on M2

Run mocked operational tests and the full regression suites using the existing installed dependencies. These tests do not provision live workspaces.

```cmd
cd /d C:\Users\archa\Resurrect-ZYRO-2.0\backend
.venv\Scripts\python.exe -m pytest -q tests/test_workspaces.py
.venv\Scripts\python.exe -m pytest -q
.venv\Scripts\python.exe -m pip check
cd ..\frontend
C:\src\flutter\bin\flutter.bat test --no-pub test\operational_workspace_test.dart
C:\src\flutter\bin\flutter.bat test --no-pub
```

With the usual local backend credentials configured, start the API as before.

```cmd
cd /d C:\Users\archa\Resurrect-ZYRO-2.0\backend
.venv\Scripts\python.exe -m uvicorn app.main:app --host 127.0.0.1 --port 8000
```

In a second CMD terminal:

```cmd
cd /d C:\Users\archa\Resurrect-ZYRO-2.0\frontend
C:\src\flutter\bin\flutter.bat run -d chrome --web-hostname localhost --web-port 3000 --dart-define=API_BASE_URL=http://localhost:8000
```

Open `http://localhost:3000/?workspace=<workspace-id>` and sign in with a provisioned member. Only use an already authorized operational workspace ID. No workspace was created in live Firestore during implementation. Without an operational workspace, use the mocked tests above. Open the URL without the query parameter for the existing demo dashboard.

A selected workspace shows an explicit loading, empty, stale, or unavailable state. The client refuses unexpected workspace IDs and demo-mode payloads. It retains the last valid snapshot when a refresh fails transiently and marks it stale. A 401 or 403 clears the displayed snapshot. The current workspace role comes from the authenticated state response. The exact wire format and errors are documented in `contracts/api-v1.md`.


## T8.2 materials

The operational workspace document keeps its existing inventory facts and adds a material_metadata map, keyed by material ID. The map stores reorder threshold and nullable description. Existing records without metadata read as threshold zero and no description. The workspace's material_mutations and material_audit subcollections record request replay results and metadata edits. Each accepted write updates inventory, version, mutation record and audit in one Firestore transaction. Demo collections are untouched.

### Manual verification

Use an explicitly approved test operational workspace and separate Planner and Approver users. The old T8.1 read-only launcher on port 8002 intentionally blocks writes. Start the updated normal app on a free port, for example 8003, from the CMD session with the existing server-side Firebase credentials configured.

```cmd
cd /d C:\Users\archa\Resurrect-ZYRO-2.0\backend
.venv\Scripts\python.exe -m uvicorn app.main:app --host 127.0.0.1 --port 8003
```

Serve the updated Flutter frontend from the allowed origin http://localhost:3000 when that port is available. Leave existing demo servers alone. In a second CMD session with the existing public Firebase Web configuration in environment variables:

```cmd
cd /d C:\Users\archa\Resurrect-ZYRO-2.0\frontend
C:\src\flutter\bin\flutter.bat run -d chrome --no-pub --web-hostname localhost --web-port 3000 --dart-define=API_BASE_URL=http://localhost:8003 --dart-define=FIREBASE_API_KEY=%FIREBASE_API_KEY% --dart-define=FIREBASE_APP_ID=%FIREBASE_APP_ID% --dart-define=FIREBASE_MESSAGING_SENDER_ID=%FIREBASE_MESSAGING_SENDER_ID% --dart-define=FIREBASE_PROJECT_ID=%FIREBASE_PROJECT_ID% --dart-define=FIREBASE_AUTH_DOMAIN=%FIREBASE_AUTH_DOMAIN%
```

1. Open http://localhost:3000/?workspace=<workspace-id> and sign in as Planner. Note the initial version.
2. Select **Add Material**. Enter a unique SKU such as QA-001, a material name, unit, reorder threshold, and optional description. Save. Verify zero physical stock, the new metadata, and one version increment.
3. Select the edit icon next to the material. Change its threshold or description and save. Refresh. Verify the saved fields, one more version increment, and the unchanged stock.
4. Try adding the same SKU with different letter casing. Expect a duplicate message and no version increment. Invalid forms must stay unsent.
5. Sign in as Approver in a separate browser profile. Confirm the material is visible and neither Add nor Edit is available. In automated tests, direct mutation attempts as an Approver or non-member return 403.
6. Use the test commands below to verify stale-version rejection, repeated requests, cross-workspace isolation and audit rollback without making live writes.

```cmd
cd /d C:\Users\archa\Resurrect-ZYRO-2.0\backend
.venv\Scripts\python.exe -m pytest -q tests/test_workspace_materials.py
cd ..\frontend
C:\src\flutter\bin\flutter.bat test --no-pub test\operational_materials_test.dart
```

### T8.2 live checkpoint

The operator confirmed the duplicate SKU message in the live dashboard. A read-only comparison found workspace version 5 with three zero-stock materials, four matching material audit and mutation records attributed to an active Planner, and zero purchase orders. Both demo inventories, purchase orders, and audit timestamps matched their baselines. Live authenticated Approver write rejection and deployed Firestore Security Rules remain unverified. Isolated tests cover role rejection, audit rollback, duplicate and cross-workspace writes.
