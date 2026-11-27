from uuid import uuid4

from app.firebase_service import PROJECT_ID, firestore_client


def main() -> int:
    try:
        from google.api_core.exceptions import AlreadyExists

        document = firestore_client().collection("_zyro_connectivity_checks").document(uuid4().hex)
        payload = {"purpose": "connectivity-diagnostic"}
        clean_up = True
        try:
            document.create(payload, retry=None, timeout=10)
            if document.get(timeout=10).to_dict() != payload:
                raise RuntimeError("Unexpected diagnostic payload.")
        except AlreadyExists:
            clean_up = False
            raise
        finally:
            if clean_up:
                try:
                    document.delete(timeout=10)
                except Exception:
                    print(f"Firestore cleanup failed. Check diagnostic document {document.path}.")
                    raise
        if document.get(timeout=10).exists:
            raise RuntimeError("Diagnostic document still exists.")
    except Exception as error:
        print(f"Firestore diagnostic failed ({type(error).__name__}).")
        return 1

    print(f"Firestore write, read, and delete verified in {PROJECT_ID}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
