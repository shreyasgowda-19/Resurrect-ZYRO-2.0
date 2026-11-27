from app.inventory.store import FirestoreInventoryStore, StateUnavailable


def main() -> int:
    try:
        created = FirestoreInventoryStore().initialize()
    except StateUnavailable as error:
        print(error)
        return 1
    print("Created demo inventory at version 1." if created else "Demo inventory already exists.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
