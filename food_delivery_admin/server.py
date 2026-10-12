"""Run uvicorn server:app instead of main:app to add Telegram authentication."""
from main import app
from auth_api import router

app.include_router(router)
