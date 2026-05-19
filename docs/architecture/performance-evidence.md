# Performance Evidence

This document records repeatable native-vs-npm measurements for the CLI parity
goal. The benchmark command is:

```sh
npm run perf:concurrently
```

The harness compares the local native binary at `_build/default/bin/main.exe`
against pinned `concurrently@9.2.1`. It validates each run exits cleanly, writes
no stderr, and produces the expected bounded stdout byte count for output-heavy
workloads. Timings are host-dependent evidence, not CI pass/fail thresholds.

## 2026-05-19 Darwin arm64

Command:

```sh
npm run perf:concurrently
```

Result:

| Workload | Native median | npm median | Median speedup | Native mean | npm mean | Native min | npm min |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `--version` | 14.11ms | 231.14ms | 16.38x | 13.60ms | 248.63ms | 10.17ms | 210.31ms |
| 24 raw short commands | 195.42ms | 448.49ms | 2.29x | 201.66ms | 438.75ms | 187.08ms | 368.68ms |
| 1000 raw streamed lines | 135.97ms | 350.46ms | 2.58x | 134.03ms | 366.42ms | 123.95ms | 332.19ms |
