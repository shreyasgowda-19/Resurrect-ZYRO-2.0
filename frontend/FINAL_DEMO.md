# Final Frontend Demo Guide

## Start the application

Use the Flutter SDK installed for the project. From the repository root:

```powershell
cd frontend
flutter pub get
flutter run -d chrome --web-port 3000 `
  --dart-define=API_BASE_URL=http://localhost:8000 `
  --dart-define=FIREBASE_API_KEY=<firebase-web-api-key> `
  --dart-define=FIREBASE_APP_ID=<firebase-web-app-id> `
  --dart-define=FIREBASE_MESSAGING_SENDER_ID=<sender-id> `
  --dart-define=FIREBASE_PROJECT_ID=<firebase-project-id>
```

The four `FIREBASE_*` values shown are required Firebase **web app** configuration values. `FIREBASE_AUTH_DOMAIN`, `FIREBASE_STORAGE_BUCKET`, and `FIREBASE_MEASUREMENT_ID` can be added as Dart defines if the registered web app uses them. Obtain them from the approved Firebase project configuration; never place them in source control or use a Firebase Admin/service-account JSON file in the browser. The app defaults `API_BASE_URL` to `http://localhost:8000` and accepts another backend host through that Dart define; do not bake a temporary host into source.

The backend must be reachable from the browser and allow the frontend's exact origin through CORS. The current backend configuration allows `http://localhost:3000`. If the web app uses a different origin/port, coordinate its CORS allowlist with the backend owner rather than changing an API contract here.

## Port 3000 troubleshooting

If port 3000 is already occupied, inspect the listener in PowerShell:

```powershell
Get-NetTCPConnection -LocalPort 3000 -State Listen
```

Stop only a process you own and recognize. Alternatively, choose a free port; coordinate the resulting browser origin with the backend owner because CORS is origin-specific. Check that the backend health endpoint is reachable at the configured host and port. A Firebase setup screen means one or more required web defines are missing; it does not indicate a successful login.

## Planner and approver demonstration

Use approved planner and approver accounts and an explicitly isolated demo dataset. Keep recovered production/demo records such as ORD-1042 read-only; do not submit events or proposals against them. Actions are subject to backend authentication, role, and version checks.

1. Sign in as a planner and open the manufacturing dashboard. Review inventory and customer orders, including the customer request date, projected delivery, delivery slack, and risk explanation.
2. In the isolated scenario, submit the supplier delay event. Review the resulting risk and available recovery recommendations.
3. Run a what-if simulation. Explain the before/after projection and any collateral effects as hypothetical outcomes, not supplier commitments.
4. Submit the selected planner proposal.
5. Sign out, sign in with a separate approver account, and review the pending proposal and its snapshot/version. Approve or reject it with the required reason and acknowledgement.
6. Show the resulting demo purchase order and audit history. The purchase order is a simulated demonstration record; no real supplier is contacted. Return to the dashboard and show the recalculated delivery projection.
7. Demonstrate logout and, if useful, sign in with each role to show the role-specific briefing and permissions.

## Copilot questions

Try questions suited to the selected role, for example:

- "Which orders need attention, and why?"
- "Why is ORD-1042 at risk?" (read-only inspection only unless using an isolated scenario)
- "What evidence supports this supplier delay?"
- "Which proposals need approval?" (approver account)

Point out the evidence records and response mode shown with each answer. "Gemini AI" identifies the Gemini response mode; "Evidence-based fallback" identifies the deterministic fallback using verified backend data. Answers are read-only and grounded in backend evidence; suggested actions do not execute automatically.

## Final automated checks

- Flutter test suite: **63 tests passed**.
- Flutter analyze: completed with 8 informational `material.dart` deprecation notices and no analyzer errors.
- Flutter web build: succeeded; the Wasm dry run also succeeded.
- `git diff --check`: passed for tracked changes. This guide was new and untracked during that check; its trailing whitespace was checked separately and passed.

## Browser verification results

On 2026-11-28, headless Chrome 158 loaded `http://localhost:3000/` successfully (HTTP 200, title `ZYRO Inventory Intelligence`) and displayed the Firebase setup-required screen. The browser console error check found no errors on that page. Required Firebase web configuration was not available in the run environment, so login, authenticated navigation, order details, proposal history, Copilot responses, and their backend requests were **not verified in a real browser**. The configured backend health endpoint returned `{"status":"ok","service":"inventory-api"}` in a read-only check. No mutation was made. This is a browser page-load smoke check, not end-to-end success.

### Manual browser checklist

- [ ] Start with approved Firebase web defines, configured backend host, and isolated demo data.
- [ ] Check browser console and network panel for authentication, CORS, and API errors.
- [ ] Verify planner login, dashboard navigation, order detail dates/slack/risk, and read-only Copilot answer/evidence/mode.
- [ ] Exercise event, recommendation, simulation, and proposal flow only in the isolated scenario.
- [ ] Verify separate approver login, proposal decision, demo purchase order, audit record, and recalculated projection.
- [ ] Background/foreground the tab and confirm refresh resumes; check stale/retry UI during an intentional temporary API outage.
- [ ] Log out and confirm authenticated access and polling timers stop.

## Known limitations and backup demonstration

- Authenticated browser E2E remains unverified until approved Firebase web configuration, role accounts, and an isolated backend scenario are available.
- No live Gemini response was demonstrated in this browser run. The UI distinguishes Gemini mode from deterministic evidence-based fallback mode when a backend response is available.
- The scheduled polling request reduction in `T6-F-EVALUATION.md` is a calculation from the client schedule, not measured Firestore reads or billing. This final browser run did not measure Firestore usage.
- Do not mutate the recovered ORD-1042 dataset. If the live demo environment is unavailable, use the existing Flutter widget tests and approved mocked fixtures to explain the screens and flows, and label that presentation as a mock/offline walkthrough. Do not describe it as live backend or browser verification.
