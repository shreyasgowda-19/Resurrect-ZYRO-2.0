from argparse import ArgumentParser

from app.auth import ROLES
from app.firebase_service import PROJECT_ID, firebase_app


def main() -> int:
    parser = ArgumentParser(description="Assign a role to an existing Firebase user.")
    parser.add_argument("uid")
    parser.add_argument("role", choices=ROLES)
    args = parser.parse_args()

    from firebase_admin import auth

    try:
        app = firebase_app()
        user = auth.get_user(args.uid, app=app)
        claims = dict(user.custom_claims or {})
        claims["role"] = args.role
        auth.set_custom_user_claims(user.uid, claims, app=app)
    except Exception as error:
        print(f"Role assignment failed ({type(error).__name__}).")
        return 1

    print(f"Role saved in {PROJECT_ID}. Refresh the user's Firebase ID token.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
