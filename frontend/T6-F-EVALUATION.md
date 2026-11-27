# T6-F Frontend Evaluation

## Polling request calculations

Counts below describe steady-state foreground dashboard polling. Startup, health checks, Copilot calls, user actions, and retry requests are excluded.

| Schedule | State requests/min | Proposal requests/min | Total API requests/min |
| --- | ---: | ---: | ---: |
| Before: both every 5 seconds | 12 | 12 | 24 |
| After: state every 10 seconds, proposals every 15 seconds | 6 | 4 | 10 |

The schedule reduces calculated foreground polling requests by 14 per minute, or **58.3%**. Polling is paused while the app is not resumed and both resources refresh when it resumes. Proposals poll independently of inventory version changes.

The previous diagnostic's approximately 84 Firestore document reads per minute is an estimate, not a measured metric. No Firestore instrumentation or live read measurement was available, so this report makes no before-and-after claim for document reads.

## Refresh and recovery behavior

- Successful manufacturing events immediately refresh state and proposals. Proposal submissions refresh proposals, and approval decisions refresh both state and proposals.
- Temporary network, timeout, and HTTP 503 failures retain the last successful data and mark it stale. Automatic retry delays increase from 2 to 4, 8, 16, then cap at 30 seconds. A successful retry restores normal polling.
- State and proposal refreshes do not overlap. Timers stop on widget disposal and while the application is inactive. A manual dashboard refresh and an approval-list refresh remain available.
- Regression coverage verifies polling intervals, overlapping refresh prevention, pause/resume, independent proposal polling, action refreshes, stale-data indication, 503/network recovery, and timer cleanup.

## Verification results

- Flutter tests: **63 passed**, including all 60 existing tests.
- Flutter analyze: no analyzer warnings or errors; command exited with status 1 because the installed Flutter SDK emitted eight informational `material.dart` deprecation notices.
- Flutter web build: **succeeded**. Flutter's Wasm dry run also succeeded.
- `git diff --check`: passed.

Testing used Flutter widget tests with mocked API responses and a local web compilation. No browser end-to-end session, live backend recovery, or Firestore document-read measurement was run.
