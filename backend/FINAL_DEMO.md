# T7-B final backend demo runbook

## Backend setup and startup

Use Python 3.15.2 and the pinned backend dependencies. Work in Windows CMD.

```cmd
cd /d C:\Users\archa\Resurrect-ZYRO-2.0\backend
python -m venv .venv
.venv\Scripts\python.exe -m pip install -r requirements.txt
set "GOOGLE_APPLICATION_CREDENTIALS=%USERPROFILE%\zyro-secrets\firebase-admin.json"
```

Reuse the existing virtual environment if it is already installed. `GOOGLE_APPLICATION_CREDENTIALS` must point to the approved service-account file for `zyro-inventory-intelligence`. Keep it outside the repository. The API uses Firebase ID tokens from the team's existing sign-in workflow. Gemini is optional. Set `GEMINI_API_KEY` privately in this same CMD session and set `GEMINI_MODEL` to the configured model. The T0-documented model is `gemini-3.1-flash-lite`.

To display the already recovered, authoritative demo or perform a historical walkthrough, start the normal backend. Treat this demo as read-only during the presentation.

```cmd
.venv\Scripts\python.exe -m uvicorn app.main:app --host 127.0.0.1 --port 8000
```

From another terminal, check the backend and open its OpenAPI documentation.

```cmd
curl.exe -i http://127.0.0.1:8000/health
curl.exe -i http://127.0.0.1:8000/state
```

Expect HTTP 200 and `{"status":"ok","service":"inventory-api"}` from `/health`, and HTTP 401 from an unauthenticated state request. Health checks the API process. A successful signed-in dashboard load checks authentication and Firestore. Swagger UI is at `http://127.0.0.1:8000/docs`.

## Fresh judges' demo

**Obtain explicit approval before creating an isolated Firestore namespace or submitting demo changes.** The default recovered dataset is `zyro_demo_inventory/current`. This launcher serves a distinct document such as `zyro_demo_inventory/t7-demo-judges-round-01`. The existing inventory, event, alert, proposal, PO, decision, and audit paths all resolve below the selected root. Creating a namespace fails if it already exists. Starting the server only reads the selected namespace.

After approval, run these commands in the configured backend CMD. Choose a different name for each fresh run.

```cmd
.venv\Scripts\python.exe -m scripts.run_isolated_demo initialize judges-round-01 --confirm-create
.venv\Scripts\python.exe -m scripts.run_isolated_demo serve judges-round-01 --port 8001
```

Only proceed once startup prints `Serving isolated demo t7-demo-judges-round-01 at version 1 on port 8001`. Check `http://127.0.0.1:8001/health`. Use Swagger UI at `http://127.0.0.1:8001/docs` or point the dashboard's existing `API_BASE_URL` launch setting to `http://127.0.0.1:8001`. Confirm the browser frontend is served from `http://localhost:3000` for the configured CORS policy. The isolated backend binds to loopback. It must run on the same machine as the browser for this procedure. Use a planner and a different approver Firebase user.

1. As planner, read `GET /state` on port 8001. Confirm version 1, ORD-1042 on track, projected delivery 2026-12-08, slack +2 calendar days.
2. Submit `POST /events` on port 8001 with a new event ID. This moves the Copper lot arrival three days later.

   ```json
   {"event_id":"judges-delay-01","event_type":"supplier_eta_update","expected_version":1,"payload":{"lot_id":"LOT-01","new_eta":"2026-12-08"}}
   ```

3. Reload state. Expect version 2, a critical-risk alert, projected delivery 2026-12-11, and slack -1.
4. Send `{"order_id":"ORD-1042","expected_version":2}` to `POST /recommendations`. Compare the expedite option and the synthetic alternate-supplier option. Use the latter's actual returned ID with `order_id` and `expected_version` in `POST /simulate`. Expect modeled delivery 2026-12-08 and risk on track. The original inventory stays at version 2.
5. As planner, send the same version-2 order and alternate-supplier recommendation ID to `POST /proposals`. Copy the returned proposal ID. The inventory stays at version 2.
6. As a different approver, review the saved evidence in `GET /proposals` and submit `POST /proposals/{proposal_id}/decision` on port 8001.

   ```json
   {"decision_id":"judges-approve-01","decision":"approve","expected_version":2,"reason":"Reviewed modeled recovery and demo supplier assumptions.","acknowledge_demo_assumptions":true}
   ```

7. Confirm version 3 and one demo PO. It contributes 400 incoming Copper units. Physical stock remains 600. ORD-1042 returns to projected delivery 2026-12-08, slack +2, and risk on track. Review persistent submission, approval, and PO-creation audit records. Repeat the identical decision as the same actor only if demonstrating replay. Expect `duplicate`, version 3, and one PO.
8. Stop the isolated server when finished. The namespace remains available for review. Use a new approved namespace for another fresh run.

## Gemini verification

Run these commands from the same configured CMD used to start the backend. The checks print presence flags and outcomes only.

```cmd
if defined GEMINI_API_KEY (echo GEMINI_API_KEY present) else (echo GEMINI_API_KEY missing)
set "GEMINI_MODEL=gemini-3.1-flash-lite"
.venv\Scripts\python.exe -m scripts.check_gemini
.venv\Scripts\python.exe -B -c "import asyncio; from app.copilot_api import select_with_gemini; from app.copilot_evidence import Fact; r=asyncio.run(select_with_gemini(('order',),'current','planner',(Fact('order','smoke','Synthetic selector test','current'),))); print('outcome=',r.outcome,'validated=',r.selection is not None,'provider_ms=',round(r.provider_seconds*1000,1),'validation_ms=',round(r.validation_seconds*1000,1)); raise SystemExit(0 if r.selection else 1)"
```

The first diagnostic checks basic provider connectivity. The structured diagnostic uses the existing evidence validator and eight-second deadline, with a single harmless evidence option. Expect `outcome=verified` and `validated=True` only if the provider returned a valid reference.

To check the running app, sign in through the existing Firebase workflow as a planner or approver. Ask **How was ORD-1042 recovered?** in the version-3 dashboard. Alternatively, from CMD, use the following read-only probe against the recovered backend on port 8000. Enter the valid ID token only at the hidden prompt. For the isolated backend, use port 8001 after recovery.

```cmd
.venv\Scripts\python.exe -B -c "import json,time; from getpass import getpass; from urllib.request import Request,urlopen; token=getpass('Firebase ID token (hidden): '); data=json.dumps(dict(question='How was ORD-1042 recovered?',order_id='ORD-1042',expected_version=3)).encode(); request=Request('http://127.0.0.1:8000/ai/ask',data=data,headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'}); start=time.perf_counter(); response=urlopen(request,timeout=20); body=json.load(response); print('http=',response.status,'mode=',body['mode'],'version=',body['version'],'ms=',round((time.perf_counter()-start)*1000,1),'evidence=',[(e['evidence_id'],e['source_type']) for e in body['evidence']]); raise SystemExit(0 if body['mode']=='gemini' else 1)"
```

A healthy result has HTTP 200, version 3, `mode=gemini`, and grounded evidence distinguishing the historical delay from the current recovery. The backend rejects unsupported references and emits safe timing and outcome categories. Configuration failure, quota limits, timeout, and invalid selections use `deterministic_fallback`. In this verification session both Gemini variables were absent, so the structured smoke stopped locally after 3.6 ms with `configuration_missing`. No provider call was sent and genuine authenticated `mode=gemini` remains unverified.

## Troubleshooting and recovery

- **Port in use:** Run `netstat -ano | findstr :8000` or `netstat -ano | findstr :8001`. Identify the listener using `tasklist /FI "PID eq <pid>"` with the actual PID. Stop only your own backend from its terminal, or select an unused port and use the matching dashboard URL.
- **Firestore TLS or 503:** The Windows fallback uses trusted system roots and preserves explicitly configured CA bundles. TLS certificate and hostname checks remain enabled. For managed networks, use an organization-approved PEM with `GRPC_DEFAULT_SSL_ROOTS_FILE_PATH` and `REQUESTS_CA_BUNDLE`. Review the redacted `tls_trust`, credentials, quota, or deadline logs, then restart from the configured terminal. Health can remain 200 while a data route returns 503.
- **Authentication or CORS:** A missing or invalid Firebase token returns 401. An unauthorized role returns 403. Use the correct project and the exact `http://localhost:3000` frontend origin. A stale approval returns 409. Refresh state and generate a new proposal instead of replaying a decision with edited inputs.
- **Provider issue:** Continue with the explicitly labeled deterministic fallback. Keep the Firebase deployment and demo data intact.
- **No permission to seed or live flow fails:** Use the recovered version-3 dashboard in read-only mode to walk through the saved critical-risk alert, proposal simulation, approved demo PO, and audits. If Firestore itself is unavailable, run the offline evaluator below. The synthetic version-1 through version-3 sequence exercises the same allocator and approval logic with in-memory storage.

```cmd
.venv\Scripts\python.exe -B -m scripts.evaluate_manufacturing --samples 21
```

## Observed verification and limits

- Read-only Firestore check returned version 3. ORD-1042 was on track with projected delivery 2026-12-08, one demo PO, and three audit records. No new Firestore namespace was initialized.
- Health returned 200. Protected inventory, proposals, and briefing routes returned 401 without a token. CORS preflight allowed `http://localhost:3000` and rejected the unlisted `http://127.0.0.1:3000` origin.
- Source review confirmed revoked-token checks and role-based proposal controls. Backend tests cover unauthorized and stale approvals, duplicate events and POs, rollback, read-only AI, and provider failure. The local Git history scan found no matching private-key, service-account, GitHub-token, or JWT patterns across 33 reachable commits. Pattern scanning does not prove the absence of every possible secret.
- Final suite: 119 tests passed. `pip check` and `git diff --check` passed. The ten-scenario isolated evaluation matched its expected outcomes.
- The launcher was tested without creating or resetting Firestore documents. Authorized isolated-cloud initialization and a fresh signed-in judges' run remain operator steps. No actual supplier is contacted. All supplier commitments and recovery improvements are synthetic.
