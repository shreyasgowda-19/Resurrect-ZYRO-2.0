from app.gemini_service import GeminiUnavailable, check_connectivity


def main() -> int:
    try:
        check_connectivity()
    except GeminiUnavailable as error:
        print(error)
        return 1

    print("Gemini returned the expected connectivity response.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
