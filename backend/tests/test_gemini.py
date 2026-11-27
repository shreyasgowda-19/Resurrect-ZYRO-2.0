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


def test_structured_provider_quota_is_classified_and_retries_disabled(monkeypatch):
    from google import genai
    from google.genai import errors

    class MockClient:
        def __init__(self, *, http_options, **kwargs):
            assert http_options.timeout == 8000
            assert http_options.retry_options.attempts == 1
            self.models = self

        def __enter__(self):
            return self

        def __exit__(self, *args):
            return None

        def generate_content(self, **kwargs):
            raise errors.ClientError(429, {"error": {"message": "private provider detail"}})

    monkeypatch.setenv("GEMINI_API_KEY", "testing-placeholder")
    monkeypatch.setenv("GEMINI_MODEL", "gemini-3.1-flash-lite")
    monkeypatch.setattr(genai, "Client", MockClient)
    with pytest.raises(gemini_service.GeminiUnavailable) as raised:
        gemini_service.generate_structured("test selection", {"type": "object"})
    assert raised.value.reason == "provider_quota"
    assert "private provider detail" not in str(raised.value)
