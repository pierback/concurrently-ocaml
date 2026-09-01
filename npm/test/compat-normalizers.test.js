const assert = require("node:assert/strict");
const test = require("node:test");

const {
  normalizeNodeTimeoutWarningStderr,
} = require("../../scripts/ci/concurrently-compat/cli-normalizers");

test("normalizes Node timeout coercion warnings without hiding application stderr", () => {
  const stderr = [
    "before",
    "(node:12345) TimeoutNaNWarning: NaN is not a number.",
    "Timeout duration was set to 1.",
    "(Use `node --trace-warnings ...` to show where the warning was created)",
    "(node:54321) TimeoutNegativeWarning: -1 is a negative number.",
    "Timeout duration was set to 1.",
    "(Use `node --trace-warnings ...` to show where the warning was created)",
    "after",
    "",
  ].join("\n");

  assert.equal(normalizeNodeTimeoutWarningStderr(stderr), "before\nafter\n");
});

test("preserves unrelated Node warnings", () => {
  const stderr = [
    "(node:12345) ExperimentalWarning: feature is experimental.",
    "(Use `node --trace-warnings ...` to show where the warning was created)",
    "",
  ].join("\n");

  assert.equal(normalizeNodeTimeoutWarningStderr(stderr), stderr);
});
