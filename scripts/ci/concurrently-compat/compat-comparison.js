const {
  normalizeSignal,
  normalizeStatus,
  normalizeStderr,
  normalizeStdout,
} = require("./cli-normalizers");

function assertEqual(actual, expected, label) {
  if (actual !== expected) {
    throw new Error(
      `${label}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`
    );
  }
}

function assertEquivalentCliResult(testCase, local, upstream) {
  assertEqual(
    normalizeStatus(testCase, local.status),
    normalizeStatus(testCase, upstream.status),
    `${testCase.name} exit status`
  );
  assertEqual(
    normalizeSignal(testCase, local.signal),
    normalizeSignal(testCase, upstream.signal),
    `${testCase.name} signal`
  );
  assertEqual(
    normalizeStdout(testCase, local.stdout),
    normalizeStdout(testCase, upstream.stdout),
    `${testCase.name} stdout`
  );
  assertEqual(
    normalizeStderr(testCase, local.stderr),
    normalizeStderr(testCase, upstream.stderr),
    `${testCase.name} stderr`
  );
}

module.exports = { assertEqual, assertEquivalentCliResult };
