from typing import Annotated

from fastapi import APIRouter, Depends, Request
from fastapi.exceptions import RequestValidationError
from fastapi.routing import APIRoute
from starlette.exceptions import HTTPException
from starlette.responses import JSONResponse

from app.auth import AuthenticatedUser, authenticated_user
from app.inventory.events import Event, EventError, EventResult
from app.inventory.store import FirestoreInventoryStore, StateUnavailable, inventory_store


class EventRoute(APIRoute):
    def get_route_handler(self):
        handle = super().get_route_handler()

        async def event_handler(request: Request):
            try:
                return await handle(request)
            except RequestValidationError:
                error = EventError(422, "INVALID_EVENT", "Check the event type and payload fields.")
            except HTTPException as exc:
                codes = {401: "UNAUTHENTICATED", 403: "FORBIDDEN", 503: "SERVICE_UNAVAILABLE"}
                if exc.status_code not in codes:
                    raise
                return JSONResponse(
                    status_code=exc.status_code,
                    content={"detail": {"code": codes[exc.status_code], "message": exc.detail}},
                    headers=exc.headers,
                )
            except EventError as exc:
                error = exc
            except StateUnavailable as exc:
                error = EventError(503, "SERVICE_UNAVAILABLE", str(exc))
            return JSONResponse(
                status_code=error.status,
                content={"detail": {"code": error.code, "message": str(error)}},
            )

        return event_handler


router = APIRouter(route_class=EventRoute)


def planner(user: Annotated[AuthenticatedUser, Depends(authenticated_user)]) -> AuthenticatedUser:
    if user.role != "planner":
        raise HTTPException(403, "Only planners can submit events.")
    return user


@router.post("/events", response_model=EventResult, responses={
    401: {"description": "Missing or invalid Firebase ID token"},
    403: {"description": "Planner role required"},
    404: {"description": "Referenced entity not found"},
    409: {"description": "Stale version or conflicting event ID"},
    422: {"description": "Invalid event data or operation"},
    503: {"description": "Required service unavailable"},
})
def submit_event(
    event: Event,
    user: Annotated[AuthenticatedUser, Depends(planner)],
    store: Annotated[FirestoreInventoryStore, Depends(inventory_store)],
) -> EventResult:
    return store.submit(event, user.uid)
