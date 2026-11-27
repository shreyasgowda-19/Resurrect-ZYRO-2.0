import pytest

from app import gemini_service


def test_gemini_failure(monkeypatch):
    def generate(prompt):
        raise gemini_service.GeminiUnavailable("Mocked Gemini outage.")

    monkeypatch.setattr(gemini_service, "generate_text", generate)
    with pytest.raises(gemini_service.GeminiUnavailable, match="Mocked Gemini outage"):
        gemini_service.check_connectivity()


def test_gemini_requires_local_configuration(monkeypatch):
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    with pytest.raises(gemini_service.GeminiUnavailable, match="GEMINI_API_KEY"):
        gemini_service.check_connectivity()
