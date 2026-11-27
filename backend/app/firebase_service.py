import logging
import os
import ssl
import sys
from pathlib import Path
from tempfile import TemporaryDirectory
from threading import Lock

PROJECT_ID = "zyro-inventory-intelligence"
_app_lock = Lock()
_windows_roots: TemporaryDirectory | None = None
logger = logging.getLogger("uvicorn.error")


class FirebaseUnavailable(RuntimeError):
    pass


class InvalidToken(ValueError):
    pass


def configure_windows_tls() -> None:
    """Use Windows-trusted CAs when no explicit bundle is set for an SDK."""
    global _windows_roots
    if sys.platform != "win32":
        return
    names = ("GRPC_DEFAULT_SSL_ROOTS_FILE_PATH", "REQUESTS_CA_BUNDLE")
    missing = [name for name in names if not os.environ.get(name)]
    if not missing:
        return

    if _windows_roots is None:
        certs = ssl.create_default_context().get_ca_certs(binary_form=True)
        if not certs:
            return
        directory = TemporaryDirectory(prefix="zyro-firebase-ca-")
        try:
            path = Path(directory.name) / "roots.pem"
            path.write_text("".join(ssl.DER_cert_to_PEM_cert(cert) for cert in certs), encoding="ascii")
        except OSError:
            directory.cleanup()
            raise
        _windows_roots = directory
    path = Path(_windows_roots.name) / "roots.pem"
    for name in missing:
        os.environ[name] = str(path)


def log_firebase_failure(operation: str, error: Exception) -> None:
    """Log fixed categories and status codes, never SDK messages or payloads."""
    status = getattr(getattr(error, "grpc_status_code", None), "name", None)
    code = getattr(error, "code", None)
    status = status or (str(code) if isinstance(code, int) else "-")
    name = type(error).__name__
    message = str(error).casefold()
    if "certificate_verify_failed" in message or "unable to get local issuer certificate" in message:
        reason = "tls_trust"
    elif status in ("RESOURCE_EXHAUSTED", "429"):
        reason = "quota_or_rate_limit"
    elif status in ("DEADLINE_EXCEEDED", "504"):
        reason = "deadline"
    elif name.endswith("CredentialsError") or status in ("UNAUTHENTICATED", "PERMISSION_DENIED", "401", "403"):
        reason = "credentials_or_permissions"
    elif name == "ValidationError":
        reason = "stored_data_validation"
    else:
        reason = "service_error"
    logger.warning("firebase operation=%s reason=%s exception=%s status=%s", operation, reason, name, status)


def firebase_app():
    if os.environ.get("FIREBASE_AUTH_EMULATOR_HOST") or os.environ.get("FIRESTORE_EMULATOR_HOST"):
        raise FirebaseUnavailable("Firebase emulator settings are incompatible with this project.")

    import firebase_admin
    from firebase_admin import credentials
    from google.auth.exceptions import DefaultCredentialsError

    with _app_lock:
        try:
            configure_windows_tls()
        except OSError as error:
            log_firebase_failure("windows_tls_setup", error)
            raise FirebaseUnavailable("Firebase TLS configuration is unavailable.") from None
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
            except (DefaultCredentialsError, OSError, ValueError) as error:
                log_firebase_failure("initialize_credentials", error)
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
    except (exceptions.FirebaseError, GoogleAuthError, OSError) as error:
        log_firebase_failure("verify_id_token", error)
        raise FirebaseUnavailable("Firebase authentication is unavailable.") from None


def firestore_client():
    from firebase_admin import firestore

    return firestore.client(app=firebase_app())
