import os


class GeminiUnavailable(RuntimeError):
    pass


def check_connectivity() -> None:
    prompt = "Reply with exactly this phrase: Gemini connectivity confirmed"
    response = generate_text(prompt)
    if response.strip().rstrip(".").casefold() != "gemini connectivity confirmed":
        raise GeminiUnavailable("Gemini returned an unexpected diagnostic response.")


def generate_text(prompt: str) -> str:
    api_key = os.environ.get("GEMINI_API_KEY", "").strip()
    model = os.environ.get("GEMINI_MODEL", "").strip()
    if not api_key or not model:
        raise GeminiUnavailable("Set GEMINI_API_KEY and GEMINI_MODEL.")

    import httpx2
    from google import genai
    from google.genai import errors, types

    try:
        with genai.Client(api_key=api_key, http_options=types.HttpOptions(timeout=15000)) as client:
            response = client.models.generate_content(model=model, contents=prompt)
    except errors.APIError as error:
        if error.code in (401, 403):
            message = "Gemini rejected the API credentials or project access."
        elif error.code == 429:
            message = "Gemini quota or rate limit exceeded."
        else:
            message = "Gemini API request failed."
        raise GeminiUnavailable(message) from None
    except (httpx2.TransportError, OSError):
        raise GeminiUnavailable("Gemini network request failed.") from None

    if not response.text or not response.text.strip():
        raise GeminiUnavailable("Gemini returned no text.")
    return response.text
