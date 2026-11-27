from typing import Annotated, Literal

from fastapi import APIRouter, Depends, HTTPException
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel

from app import firebase_service

Role = Literal["planner", "approver"]
ROLES = ("planner", "approver")
bearer = HTTPBearer(auto_error=False)
router = APIRouter()


class AuthenticatedUser(BaseModel):
    uid: str
    email: str | None
    role: Role


def authenticated_user(
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer)],
) -> AuthenticatedUser:
    if credentials is None:
        raise HTTPException(401, "Firebase ID token required", {"WWW-Authenticate": "Bearer"})

    try:
        claims = firebase_service.verify_token(credentials.credentials)
    except firebase_service.InvalidToken:
        raise HTTPException(401, "Invalid Firebase ID token", {"WWW-Authenticate": "Bearer"}) from None
    except firebase_service.FirebaseUnavailable:
        raise HTTPException(503, "Authentication service unavailable") from None

    role = claims.get("role")
    if role not in ROLES:
        raise HTTPException(403, "Unauthorized role")

    return AuthenticatedUser(uid=claims["uid"], email=claims.get("email"), role=role)


@router.get("/auth/me", response_model=AuthenticatedUser)
def auth_me(user: Annotated[AuthenticatedUser, Depends(authenticated_user)]) -> AuthenticatedUser:
    return user
