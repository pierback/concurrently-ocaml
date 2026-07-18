const { resolve } = require("node:path");
const { runNativeApiCustomInput } = require("./native-api-custom-input");
const { runNativeApiCustomOutput } = require("./native-api-custom-output");
const { runNativeApiCustomPolicy } = require("./native-api-custom-policy");
const {
  runNativeApiCustomTermination,
} = require("./native-api-custom-termination");
const { createDiscardSink } = require("./native-api-support");

let nativeApiCustomSpawnPhase = "not started";

async function runNativeApiCustomSpawnWithTimeout(context) {
  const defaultTimeoutMs = process.platform === "win32" ? 120000 : 30000;
  const timeoutMs = Number(
    process.env.CONCURRENTLY_ML_COMPAT_TIMEOUT_MS ?? defaultTimeoutMs
  );
  let timer;
  try {
    await Promise.race([
      runNativeApiCustomSpawnSmoke(context),
      new Promise((_, reject) => {
        timer = setTimeout(() => {
          reject(
            new Error(
              `native JS API custom spawn timed out after ${timeoutMs}ms at ${nativeApiCustomSpawnPhase}`
            )
          );
        }, timeoutMs);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

function nativeApiCustomSpawnProgress(phase) {
  nativeApiCustomSpawnPhase = phase;
  console.log(`compat progress: native JS API custom spawn ${phase}`);
}

async function runNativeApiCustomSpawnSmoke({
  assertEqual,
  commands,
  nativeApiExplicitShell,
}) {
  const api = require(resolve("index.js"));
  const sink = createDiscardSink();
  const shared = {
    api,
    assertEqual,
    nativeApiCustomSpawnProgress,
    sink,
  };

  await runNativeApiCustomOutput({
    ...shared,
    commands,
    nativeApiExplicitShell,
  });
  await runNativeApiCustomPolicy({ ...shared, commands });
  await runNativeApiCustomInput(shared);
  await runNativeApiCustomTermination(shared);
  console.log("compat ok: native JS API custom spawn");
}

module.exports = { runNativeApiCustomSpawnWithTimeout };
