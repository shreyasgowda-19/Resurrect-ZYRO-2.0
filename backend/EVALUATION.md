# T6-B backend evaluation

## Reproduce

From `backend` in Windows CMD, run the isolated evaluation. It compares expected results against the real allocator, event and recovery logic, and proposal store using an in-memory transaction adapter. A mismatch exits nonzero.

```cmd
.venv\Scripts\python.exe -B -m scripts.evaluate_manufacturing --samples 21
```

With the usual server-side Firebase credentials configured, run the optional read-only benchmark. `--gemini-smoke` makes at most one actual provider request when both Gemini environment variables are present.

```cmd
.venv\Scripts\python.exe -B -m scripts.benchmark_inventory_reads --samples 3 --gemini-smoke
```

## Manufacturing outcomes

All ten scenarios matched their explicitly defined expectations. They use the fixed 2026-12-01 demo, with one additional, lower-priority synthetic order to test allocation effects.

| Scenario | Expected result | Observed result |
| --- | --- | --- |
| Normal availability | 600 physical + 400 incoming Copper units, 1,000 allocated, 0 net | Same. ORD-1042 projected delivery Dec 8, slack +2, on track |
| Supplier delivery delay | Dec 11 delivery, slack -1, critical | Same |
| Material shortage | ORD-1046 short 30 resin units, critical | Same |
| Demand increase | ORD-1042 short 200 Copper units, delivery unavailable | Same |
| Stock discrepancy | 550 physical Copper units, ORD-1042 short 50 | Same |
| Strategy simulation | Expedite and alternate supplier each project Dec 8 delivery | Same. Both outcomes were hypothetical |
| Impact on other orders | ORD-EVAL-LOW gets a Dec 11 projection and remains critical | Same. No other order changed in the alternate-supplier simulation |
| Human approval and recovery | Version 3, +400 incoming, physical stock unchanged, Dec 8 delivery | Same. Slack returned to +2 and risk to on track |
| Duplicate PO prevention | Three decision replays, one PO total, zero duplicates | Same. Inventory remained unchanged after replay |
| Stale approval rejection | HTTP-equivalent 409 with STALE_VERSION, inventory unchanged | Same, through the production proposal store |

For ORD-1042, projected delivery moved from Dec 8 to Dec 11 during disruption and returned to Dec 8 after authorized demo recovery. Slack improved by three calendar days from the disrupted state. The approval added 400 incoming units and changed the outcome of one other synthetic order, ORD-EVAL-LOW. It gained a Dec 11 projection while remaining critical. These are modeled effects in synthetic data.

## Isolated performance

Windows 11 build 26200, Python 3.15.2. Measurements use `perf_counter`. The p95 uses nearest rank.

| Operation | Samples | Median | p95 |
| --- | ---: | ---: | ---: |
| Inventory engine, standard fixture | 21 | 0.425 ms | 0.725 ms |
| Full ten-scenario evaluation with in-memory transactions | 21 | 19.191 ms | 26.150 ms |

## Live Firestore read baseline and comparison

Version 3, measured before and after the targeted change with the same Windows/Python environment. Each row used three sequential samples per run. In-process HTTP tests used a local authentication override to isolate storage and app timing. AI latency rows use simulated immediate provider failure. No live business records were written.

| Endpoint | HTTP | Returned docs before / after | Collection queries before / after | Median before / after | p95 before / after |
| --- | ---: | ---: | ---: | ---: | ---: |
| GET /state | 200 | 1 / 1 | 0 / 0 | 190.190 / 125.671 ms | 241.340 / 127.753 ms |
| GET /proposals | 200 | 6 / 6 | 3 / 3 | 647.893 / 670.223 ms | 664.616 / 670.754 ms |
| POST /ai/ask, fallback | 200 | 6 / 6 | 3 / 3 | 710.294 / 602.918 ms | 784.808 / 681.081 ms |
| GET /ai/briefing, fallback | 200 | 6 / 6 | 3 / 3 | 636.999 / 608.566 ms | 739.802 / 622.899 ms |
| POST /ai/ask, stale version | 409 | 6 / 1 | 3 / 0 | 682.125 / 425.688 ms | 769.889 / 426.559 ms |

Each request performed one direct SDK document get. The board queries returned one proposal, one PO and three audits on this dataset. The counts are observed SDK operations and returned documents. They do not include index reads, any minimum query charges, or transaction RPCs and should not be treated as billed read counts. With three samples each p95 is the maximum, and endpoint timing variation without a code-path change is not a measured speedup.

The stale request now compares `expected_version` to the inventory document inside the same read-only transaction, before loading board data. It still returns the same structured 409. Valid requests retain the previous board consistency and freshness behavior. A successful or long-running provider attempt can require the existing second consistent read to catch approval changes that leave inventory version unchanged. The benchmark did not measure that path with a genuine provider. No authorization or inventory caching was introduced. TLS configuration and approval mutation transactions were untouched.

`/state` already reads one document with bounded event and alert summaries, so it was left alone. The proposal board still scans proposals to preserve all pending records and the latest completed history. A larger archive may warrant an indexed query design and separate measurement.

## Provider and verification limits

The optional Gemini smoke check found missing environment configuration and did not send a request. Genuine Gemini mode remains unverified in this session. Field selection was not relaxed. The in-memory approval adapter exercises production store and idempotency logic without measuring Firestore write latency or distributed contention.

Final validation used the complete backend suite, `pip check`, and `git diff --check`.
