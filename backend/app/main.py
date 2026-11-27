import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app import gemini_service
from app.auth import router as auth_router
from app.copilot_api import router as copilot_router
from app.inventory.event_api import router as event_router
from app.inventory.proposal_api import router as proposal_router
from app.inventory.recovery_api import router as recovery_router
from app.inventory.state import router as state_router

@asynccontextmanager
async def lifespan(_app: FastAPI):
    key_present, model_present = gemini_service.configuration_presence()
    logging.getLogger("uvicorn.error").info(
        "copilot configuration gemini_key_present=%s gemini_model_present=%s provider_deadline_seconds=%.1f",
        key_present, model_present, gemini_service.COPILOT_TIMEOUT_SECONDS,
    )
    yield


app = FastAPI(title="Inventory API", version="1.0.0", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:3000"],
    allow_methods=["GET", "POST"],
    allow_headers=["Authorization", "Content-Type"],
)


app.include_router(auth_router)
app.include_router(state_router)
app.include_router(event_router)
app.include_router(recovery_router)
app.include_router(proposal_router)
app.include_router(copilot_router)


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok", "service": "inventory-api"}
