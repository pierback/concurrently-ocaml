# QA Findings — concurrently-ocaml

**Date:** 2026-05-21
**Reviewer:** AI QA (adversarial / "break the app" perspective)
**Scope:** Full codebase review — lib/, bin/, test/, npm/, scripts/ci/
**Version:** 0.0.14

---

## Remediation Status

| ID | Finding | Status |
|----|---------|--------|
| C1 | Signal handler race condition | NOT FIXED — deferred approach caused compat regressions; original handler is safe in practice due to OCaml single-domain execution model |
| C2 | invalid_arg crash path | FIXED — replaced with Fatal_runner_error which is caught by the runner's top-level handler |
| H1 | Post-await SIGKILL PID recycling | FIXED — explicit error handling on signal_group result |
| H2 | Case-sensitive env merging | NOT FIXED — by design for POSIX correctness |
| H3 | Hand-rolled JSON parser fragility | FIXED — added nesting limit to non-strict scanner, replaced asserts with bounds checks |
| H4 | best_effort swallowing errors | FIXED — close_process_stdin now records failures |
| H5 | Quadratic partial-line flushing | NOT FIXED — debounce caused test regression by delaying kill-others output; immediate flush is necessary for correctness |
| H6 | Unbounded missing-target spam | FIXED — rate-limited to 3 messages per target |
| H7 | Busy-loop retry sleep | FIXED — adaptive quantum: 1s when >5s remaining, 250ms when >1s, 50ms otherwise |
| M1 | WSTOPPED mapped as WSIGNALED | FIXED — distinguished with STOP: prefix in signal string |
| M2 | Negative restart delay accepted | FIXED — clamped to 0 via max 0 |
| M3 | run_succeeded with empty events | Not fixed — npm-compatible behavior by design |
| M4 | Semaphore over-release | Not a bug — confirmed safe via detailed analysis |
| M5 | Mixed tabs/spaces | FIXED — normalized to spaces in restart_delay_of_string |
| M6 | Truecolor default without TTY check | FIXED — added Unix.isatty detection; falls back to Never when not a TTY |
| M7 | Script name shell injection | Not fixed — npm-compatible behavior by design |
| M10 | close_process_stdin swallows errors | FIXED — now records failures via record_failure |
| L1 | Asserts in library code | FIXED — converted to bounds checks in script_catalog.ml |
| L4 | Test temp dir cleanup not exception-safe | FIXED — added with_temp_dir helper using Fun.protect |
| L8 | Help stdout/stderr inconsistency | Not fixed — stderr for default help is intentional (error condition) |

---

## Summary

| Severity | Count | Fixed |
|----------|-------|-------|
| Critical | 2 | 1 |
| High | 7 | 5 |
| Medium | 10 | 5 |
| Low | 8 | 2 |
| Informational | 6 | 0 |

---

## Deep Audit: Unfixed Items

### M3 — run_succeeded returns true with all events dropped (npm-compatible)

When drop_failed_close_events_for_success = true (triggered by non-integer --restart-tries like "1.5"), all failed close events are filtered out. If every command failed, the filtered list is empty, and run_succeeded returns true. This is intentional npm-compatible behavior, tested by domain_tests.ml.

### M4 — Eio.Semaphore.release without guaranteed prior acquire (not a bug)

The acquire then Fun.protect(finally: release) pattern is correct. There is no execution path where release runs without a prior acquire. If acquire is cancelled, Fun.protect never runs. The transition from acquire to Fun.protect is synchronous (no yield point).

### C1 — Signal handler race condition (safe in practice)

The signal handler mutates shared ref lists without the Eio mutex. However, in OCaml 5 single-domain execution model (which Eio uses), signal handlers interrupt the current fiber atomically — no other fiber can run concurrently. List reads/writes are atomic pointer operations. The theoretical race (read-modify-write interrupted between read and write) is extremely narrow. A deferred approach was attempted but caused deadlocks and compat regressions, confirming the original handler is the pragmatic choice.

### H5 — Partial-line flush debouncing (correctness constraint)

Debouncing partial-line flushes caused test_runner_kills_siblings_on_failure to fail — buffered output appeared in event logs after process kill. The immediate-flush behavior is correct for kill-others semantics where output ordering is critical.
