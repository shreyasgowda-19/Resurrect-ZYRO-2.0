from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.auth import router as auth_router
from app.inventory.state import router as state_router

app = FastAPI(title="Inventory API", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:3000"],
    allow_methods=["GET"],
    allow_headers=["Authorization"],
)


app.include_router(auth_router)
app.include_router(state_router)


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok", "service": "inventory-api"}
