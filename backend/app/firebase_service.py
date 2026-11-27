import os
from threading import Lock

PROJECT_ID = "zyro-inventory-intelligence"
_app_lock = Lock()


class FirebaseUnavailable(RuntimeError):
    pass


class InvalidToken(ValueError):
    pass


def firebase_app():
    if os.environ.get("FIREBASE_AUTH_EMULATOR_HOST") or os.environ.get("FIRESTORE_EMULATOR_HOST"):
        raise FirebaseUnavailable("Firebase emulator settings are incompatible with this project.")

    import firebase_admin
    from firebase_admin import credentials
    from google.auth.exceptions import DefaultCredentialsError

    with _app_lock:
        try:
            app = firebase_admin.get_app(PROJECT_ID)
        except ValueError:
            credential = credentials.ApplicationDefault()
            try:
                if credential.project_id != PROJECT_ID:
                    raise FirebaseUnavailable("Firebase credential project does not match.")
                app = firebase_admin.initialize_app(
                    credential, {"projectId": PROJECT_ID}, name=PROJECT_ID
                )
            except (DefaultCredentialsError, OSError, ValueError):
                raise FirebaseUnavailable("Firebase credentials are unavailable.") from None

        if app.project_id != PROJECT_ID:
            raise FirebaseUnavailable("Firebase app project does not match.")
        return app


def verify_token(token: str) -> dict:
    from firebase_admin import auth, exceptions
    from google.auth.exceptions import GoogleAuthError

    try:
        return auth.verify_id_token(token, app=firebase_app(), check_revoked=True)
    except (
        auth.InvalidIdTokenError,
        auth.RevokedIdTokenError,
        auth.UserDisabledError,
        auth.UserNotFoundError,
        ValueError,
    ):
        raise InvalidToken("Invalid Firebase ID token.") from None
    except (exceptions.FirebaseError, GoogleAuthError, OSError):
        raise FirebaseUnavailable("Firebase authentication is unavailable.") from None


def firestore_client():
    from firebase_admin import firestore

    return firestore.client(app=firebase_app())
