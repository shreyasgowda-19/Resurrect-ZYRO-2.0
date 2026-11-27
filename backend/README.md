# Backend integration diagnostics

Run the commands from `backend\` in Windows CMD after the Firebase and Gemini SDK dependencies are installed.

- `GOOGLE_APPLICATION_CREDENTIALS` points to the Firebase service-account JSON outside the repository. Use credentials for `zyro-inventory-intelligence`.
- `GEMINI_API_KEY` comes from your local environment. Keep the key out of the repository and frontend.
- Set `GEMINI_MODEL` to `gemini-3.1-flash-lite`. Google lists this as a stable model with a free tier. Use a free-tier project for the diagnostic.

```cmd
if defined GEMINI_API_KEY (echo GEMINI_API_KEY is set) else (echo GEMINI_API_KEY is missing)
set "GOOGLE_APPLICATION_CREDENTIALS=%USERPROFILE%\zyro-secrets\firebase-admin.json"
set "GEMINI_MODEL=gemini-3.1-flash-lite"
.venv\Scripts\python.exe -m scripts.check_firestore
.venv\Scripts\python.exe -m scripts.check_gemini
.venv\Scripts\python.exe -m pytest -v
.venv\Scripts\python.exe -m pip check
```

The Firestore diagnostic uses a UUID in `_zyro_connectivity_checks` and verifies deletion after the read. The Gemini diagnostic sends a fixed prompt with no business data.

To assign a role locally, use credentials with permission to update Firebase Auth users and pass the UID of an existing user. For example, use `.venv\Scripts\python.exe -m scripts.assign_role FIREBASE_UID planner`. Supported roles are `planner` and `approver`. Have the user refresh their ID token after a role change.
