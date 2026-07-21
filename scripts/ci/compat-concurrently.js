#!/usr/bin/env node

const { existsSync } = require("node:fs");
const { cpus } = require("node:os");
const { resolve } = require("node:path");
const { spawnSync } = require("node:child_process");
const {
  createCliCommandRunner,
} = require("./concurrently-compat/cli-command-runner");
const { createCliCases } = require("./concurrently-compat/cli-cases");
const { createCliFixtures } = require("./concurrently-compat/cli-fixtures");
const {
  createPlatformCommands,
} = require("./concurrently-compat/platform-commands");
const {
  assertEqual,
  assertEquivalentCliResult,
} = require("./concurrently-compat/compat-comparison");
const {
  runNativeApiSmoke,
} = require("./concurrently-compat/native-api-suite");
const upstreamReference = require("./upstream-reference.json");
const npmConcurrentlyVersion = upstreamReference.version;
const nativeApiExplicitShell = process.platform === "win32" ? "cmd.exe" : "/bin/sh";
const localBinary = resolve("_build", "default", "bin", "main.exe");
const cliCommandRunner = createCliCommandRunner({
  localBinary,
  npmConcurrentlyVersion,
});
const platformCommands = createPlatformCommands();
const { shellQuote } = platformCommands;
const cliFixtures = createCliFixtures({ shellQuote });
const oneSlotPercentage = `${100 / (2 * Math.max(1, cpus().length))}%`;
const compatWatchdog = startCompatWatchdog("compat harness", 900000);

if (!existsSync(localBinary)) {
  throw new Error(`missing local binary: ${localBinary}; run npm run compile first`);
}

const cases = createCliCases({
  commands: platformCommands,
  fixtures: cliFixtures,
  oneSlotPercentage,
});

(async () => {
  try {
    for (const testCase of cases) {
      const local = await cliCommandRunner.runLocal(testCase);
      const npm = await cliCommandRunner.runUpstream(testCase);

      assertEquivalentCliResult(testCase, local, npm);
      console.log(`compat ok: ${testCase.name} (${testCase.upstream})`);
    }
    await runNativeApiSmoke({
      assertEqual,
      cliCommandRunner,
      commands: platformCommands,
      nativeApiExplicitShell,
    });
  } finally {
    cliFixtures.cleanup();
    platformCommands.cleanup();
  }
})().catch((error) => {
  console.error(error);
  process.exit(1);
}).finally(() => {
  clearTimeout(compatWatchdog);
  const exitWatchdog = startCompatWatchdog("compat harness post-completion exit", 5000);
  exitWatchdog.unref();
});

function startCompatWatchdog(label, defaultTimeoutMs) {
  const timeoutMs = Number(process.env.CONCURRENTLY_ML_COMPAT_TIMEOUT_MS ?? defaultTimeoutMs);
  return setTimeout(() => {
    console.error(`${label} timed out after ${timeoutMs}ms`);
    for (const handle of process._getActiveHandles()) {
      console.error(`active handle: ${describeActiveHandle(handle)}`);
    }
    dumpProcessTableForDiagnostics();
    process.exit(1);
  }, timeoutMs);
}

function describeActiveHandle(handle) {
  const name = handle?.constructor?.name ?? typeof handle;
  if (name === "ChildProcess") {
    return `${name} pid=${handle.pid ?? "<none>"} exitCode=${handle.exitCode ?? "<none>"}`;
  }
  if (name === "Socket") {
    return `${name} local=${handle.localAddress ?? "<none>"} remote=${handle.remoteAddress ?? "<none>"}`;
  }
  return name;
}

function dumpProcessTableForDiagnostics() {
  if (process.platform === "win32") {
    return;
  }
  const result = spawnSync("ps", ["-eo", "pid,ppid,pgid,stat,comm,args"], {
    encoding: "utf8",
  });
  if (result.error) {
    console.error(`process table unavailable: ${result.error.message}`);
    return;
  }
  if (result.status !== 0) {
    console.error(`process table unavailable: ${result.stderr.trim()}`);
    return;
  }
  console.error(`process table at watchdog timeout (node pid ${process.pid}):`);
  console.error(result.stdout.trimEnd());
}
