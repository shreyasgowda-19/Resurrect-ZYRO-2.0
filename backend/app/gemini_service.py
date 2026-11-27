import os

COPILOT_TIMEOUT_SECONDS = 8.0


class GeminiUnavailable(RuntimeError):
    def __init__(self, message: str, reason: str = "provider_unavailable"):
        super().__init__(message)
        self.reason = reason


def configuration_presence() -> tuple[bool, bool]:
    return tuple(bool(os.environ.get(name, "").strip()) for name in ("GEMINI_API_KEY", "GEMINI_MODEL"))


def check_connectivity() -> None:
    prompt = "Reply with exactly this phrase: Gemini connectivity confirmed"
    response = generate_text(prompt)
    if response.strip().rstrip(".").casefold() != "gemini connectivity confirmed":
        raise GeminiUnavailable("Gemini returned an unexpected diagnostic response.")


def generate_text(prompt: str) -> str:
    return _generate(prompt)


def generate_structured(prompt: str, schema: dict) -> str:
    return _generate(prompt, schema)


def _generate(prompt: str, schema: dict | None = None) -> str:
    api_key = os.environ.get("GEMINI_API_KEY", "").strip()
    model = os.environ.get("GEMINI_MODEL", "").strip()
    if not api_key or not model:
        raise GeminiUnavailable("Set GEMINI_API_KEY and GEMINI_MODEL.", "configuration_missing")

    import httpx2
    from google import genai
    from google.genai import errors, types

    http_options = types.HttpOptions(
        timeout=int(COPILOT_TIMEOUT_SECONDS * 1000) if schema is not None else 15000,
        retry_options=types.HttpRetryOptions(attempts=1),
    )
    config = None
    if schema is not None:
        config = types.GenerateContentConfig(
            response_mime_type="application/json",
            response_json_schema=schema,
            max_output_tokens=256,
        )
    try:
        with genai.Client(api_key=api_key, vertexai=False, http_options=http_options) as client:
            response = client.models.generate_content(model=model, contents=prompt, config=config)
    except errors.APIError as error:
        if error.code in (401, 403):
            message, reason = "Gemini rejected the API credentials or project access.", "provider_auth"
        elif error.code == 429:
            message, reason = "Gemini quota or rate limit exceeded.", "provider_quota"
        else:
            message, reason = "Gemini API request failed.", "provider_http_error"
        raise GeminiUnavailable(message, reason) from None
    except (httpx2.TimeoutException, TimeoutError):
        raise GeminiUnavailable("Gemini network request timed out.", "provider_timeout") from None
    except (httpx2.TransportError, OSError, ValueError):
        raise GeminiUnavailable("Gemini network request failed.") from None

    if not response.text or not response.text.strip():
        raise GeminiUnavailable("Gemini returned no text.", "provider_empty_response")
    return response.text
