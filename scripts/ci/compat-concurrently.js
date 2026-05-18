#!/usr/bin/env node

const { existsSync, mkdtempSync, rmSync, writeFileSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { resolve } = require("node:path");
const { spawn, spawnSync } = require("node:child_process");

const npmConcurrentlyVersion = "9.2.1";
const localBinary = resolve("_build", "default", "bin", "main.exe");
const npmConcurrentlyBinary = resolveNpmConcurrentlyBinary();
const inputEchoCommand =
  "node -e \"process.stdin.once('data',d=>{process.stdout.write(d);process.exit(0)})\"";
const firstInputEchoCommand =
  "node -e \"process.stdin.once('data',d=>{process.stdout.write('first:'+d);process.exit(0)})\"";
const secondInputEchoCommand =
  "node -e \"process.stdin.once('data',d=>{process.stdout.write('second:'+d);process.exit(0)})\"";
const forceBasicColorEnv = { NO_COLOR: null, FORCE_COLOR: "1" };
const forceTruecolorEnv = { NO_COLOR: null, FORCE_COLOR: "3" };
const shortcutFixture = createShortcutFixture();
const restartFixture = createRestartFixture();

if (!existsSync(localBinary)) {
  throw new Error(`missing local binary: ${localBinary}; run npm run compile first`);
}

const cases = [
  {
    name: "version long option",
    upstream: "bin/concurrently.spec.ts --version",
    args: ["--version"],
    normalizeStdout: normalizeVersionStdout,
  },
  {
    name: "version short lowercase option",
    upstream: "bin/concurrently.spec.ts -v",
    args: ["-v"],
    normalizeStdout: normalizeVersionStdout,
  },
  {
    name: "version short uppercase option",
    upstream: "bin/concurrently.spec.ts -V",
    args: ["-V"],
    normalizeStdout: normalizeVersionStdout,
  },
  {
    name: "help long option",
    upstream: "bin/concurrently.spec.ts --help",
    args: ["--help"],
  },
  {
    name: "help short option",
    upstream: "bin/concurrently.spec.ts -h",
    args: ["-h"],
  },
  {
    name: "single success close notification",
    upstream: "src/flow-control/log-exit.spec.ts",
    args: ["--no-color", "printf smoke"],
  },
  {
    name: "failed command close notification",
    upstream: "src/flow-control/log-exit.spec.ts",
    args: ["--no-color", "sh -c 'exit 3'"],
  },
  {
    name: "raw suppresses close notification",
    upstream: "bin/concurrently.spec.ts does not log extra output with --raw",
    args: ["--no-color", "--raw", "printf one"],
  },
  {
    name: "hidden command suppresses close notification",
    upstream: "bin/concurrently.spec.ts --hide by index",
    args: ["--no-color", "--hide", "0", "printf hidden"],
  },
  {
    name: "hidden named command suppresses output",
    upstream: "bin/concurrently.spec.ts --hide by name",
    args: [
      "--no-color",
      "-g",
      "-n",
      "api,worker",
      "--hide",
      "api",
      "printf hidden",
      "printf visible",
    ],
  },
  {
    name: "multiple hidden named commands suppress all output",
    upstream: "bin/concurrently.spec.ts --hide by comma-separated names",
    args: [
      "--no-color",
      "-g",
      "-n",
      "api,worker",
      "--hide",
      "worker,api",
      "printf hidden",
      "printf visible",
    ],
  },
  {
    name: "names select default prefix",
    upstream: "bin/concurrently.spec.ts --names prefixes with names",
    args: ["--no-color", "-g", "-n", "api,worker", "printf api", "printf worker"],
  },
  {
    name: "deprecated name separator warning",
    upstream: "bin/concurrently.spec.ts --name-separator deprecation warning",
    args: [
      "--no-color",
      "-g",
      "--names",
      "foo|bar",
      "--name-separator",
      "|",
      "printf foo",
      "printf bar",
    ],
  },
  {
    name: "timings lifecycle and summary table",
    upstream: "lib/flow-control/log-timings.ts",
    args: ["--no-color", "--timings", "printf one"],
    normalizeStdout: normalizeTimingsStdout,
  },
  {
    name: "timings named command summary table",
    upstream: "lib/flow-control/log-timings.spec.ts mapCloseEventToTimingInfo",
    args: ["--no-color", "--timings", "-n", "api", "printf one"],
    normalizeStdout: normalizeTimingsStdout,
  },
  {
    name: "timings hidden command summary table",
    upstream: "lib/flow-control/log-timings.ts with logger hide rules",
    args: ["--no-color", "--timings", "--hide", "0", "printf one"],
    normalizeStdout: normalizeTimingsStdout,
  },
  {
    name: "timings raw mode suppresses lifecycle and summary",
    upstream: "lib/logger.ts raw command/global event suppression",
    args: ["--no-color", "--timings", "--raw", "printf one"],
  },
  {
    name: "timings grouped output and sorted table",
    upstream: "lib/flow-control/log-timings.spec.ts sorted timings summary",
    args: [
      "--no-color",
      "--timings",
      "-g",
      "-n",
      "slow,fast",
      "node -e \"setTimeout(()=>process.stdout.write('slow'),80)\"",
      "printf fast",
    ],
    normalizeStdout: normalizeTimingsStdout,
  },
  {
    name: "timings failed command lifecycle and table",
    upstream: "lib/flow-control/log-timings.ts complete or error event timing",
    args: ["--no-color", "--timings", "sh -c 'exit 2'"],
    normalizeStdout: normalizeTimingsStdout,
  },
  {
    name: "timings restart attempts final table",
    upstream: "lib/flow-control/log-timings.ts retry close timing",
    args: ["--no-color", "--timings", "--restart-tries", "1", "exit 1"],
    normalizeStdout: normalizeTimingsStdout,
  },
  {
    name: "timings custom timestamp format",
    upstream: "lib/flow-control/log-timings.ts timestampFormat",
    args: ["--no-color", "--timings", "--timestamp-format", "SSS", "printf one"],
    normalizeStdout: normalizeTimingsStdout,
  },
  {
    name: "timings kill-on-fail signal table",
    upstream: "lib/flow-control/log-timings.ts killed close timing",
    args: ["--no-color", "--timings", "--kill-others-on-fail", "sleep 1", "exit 1"],
    normalizeStdout: normalizeTimingsStdout,
  },
  {
    name: "colored default reset prefix",
    upstream: "dist/src/defaults.js prefixColors reset",
    args: ["printf one"],
    env: forceBasicColorEnv,
  },
  {
    name: "colored red bold prefix",
    upstream: "dist/src/logger.js getChalkPath red.bold",
    args: ["-c", "red.bold", "printf one"],
    env: forceBasicColorEnv,
  },
  {
    name: "colored hex prefix truecolor",
    upstream: "dist/src/logger.js chalk.hex",
    args: ["-c", "#336699", "printf one"],
    env: forceTruecolorEnv,
  },
  {
    name: "colored short hex prefix truecolor",
    upstream: "dist/src/logger.js chalk.hex short form",
    args: ["-c", "#f00", "printf one"],
    env: forceTruecolorEnv,
  },
  {
    name: "colored invalid prefix falls back to reset",
    upstream: "dist/src/logger.js getChalkPath fallback",
    args: ["-c", "bogus", "printf one"],
    env: forceBasicColorEnv,
  },
  {
    name: "colored background foreground modifier prefix",
    upstream: "dist/src/logger.js getChalkPath bgRed.white.bold",
    args: ["-c", "bgRed.white.bold", "printf one"],
    env: forceTruecolorEnv,
  },
  {
    name: "colored bright foreground modifier prefix",
    upstream: "dist/src/logger.js getChalkPath gray.dim",
    args: ["-c", "gray.dim", "printf one"],
    env: forceTruecolorEnv,
  },
  {
    name: "colored hidden modifier prefix",
    upstream: "dist/src/logger.js getChalkPath hidden",
    args: ["-c", "hidden", "printf one"],
    env: forceTruecolorEnv,
  },
  {
    name: "command prefix length truncates command",
    upstream: "bin/concurrently.spec.ts specifies custom prefix length",
    args: [
      "--no-color",
      "-g",
      "-p",
      "command",
      "-l",
      "6",
      "printf alpha",
      "printf beta",
    ],
  },
  {
    name: "template prefix is not bracketed",
    upstream: "src/logger.spec.ts logs with templated prefixFormat",
    args: ["--no-color", "-g", "-p", "{index}:{name}", "-n", "api", "printf templated"],
  },
  {
    name: "none prefix removes prefix markers",
    upstream: "src/logger.spec.ts logs with no prefix",
    args: ["--no-color", "-g", "-p", "none", "printf bare"],
  },
  {
    name: "npm shortcut default name",
    upstream: "dist/src/command-parser/expand-shortcut.js npm:<script>",
    cwd: shortcutFixture.cwd,
    args: ["--no-color", "-g", "npm:print"],
  },
  {
    name: "npm shortcut preserves explicit name",
    upstream: "dist/src/command-parser/expand-shortcut.js commandInfo.name",
    cwd: shortcutFixture.cwd,
    args: ["--no-color", "-g", "-n", "custom", "npm:print"],
  },
  {
    name: "mixed shortcut and literal default prefixes",
    upstream: "dist/src/command-parser/expand-shortcut.js default name only for shortcut",
    cwd: shortcutFixture.cwd,
    args: ["--no-color", "-g", "npm:print", "printf normal"],
  },
  {
    name: "shortcut accepts passthrough script name with spaces",
    upstream: "dist/src/command-parser/expand-shortcut.js before expand-arguments.js",
    cwd: shortcutFixture.cwd,
    args: ["--no-color", "-P", "npm:{1}", "--", "client build"],
  },
  {
    name: "npm wildcard shortcut expands package scripts",
    upstream: "dist/src/command-parser/expand-wildcard.js npm run <script*>",
    cwd: shortcutFixture.cwd,
    args: ["--no-color", "-g", "npm:build-*"],
  },
  {
    name: "npm wildcard shortcut prefixes explicit name",
    upstream: "dist/src/command-parser/expand-wildcard.js commandInfo.name prefix",
    cwd: shortcutFixture.cwd,
    args: ["--no-color", "-g", "-n", "pre", "npm:build-*"],
  },
  {
    name: "npm wildcard shortcut omission filter",
    upstream: "dist/src/command-parser/expand-wildcard.js omission filter",
    cwd: shortcutFixture.cwd,
    args: ["--no-color", "-g", "npm:build-*(!css)"],
  },
  {
    name: "npm wildcard shortcut no matches exits cleanly",
    upstream: "dist/src/command-parser/expand-wildcard.js empty expansion",
    cwd: shortcutFixture.cwd,
    args: ["--no-color", "-g", "npm:no-match-*"],
  },
  {
    name: "no-match wildcard still runs teardown",
    upstream: "bin/concurrently.spec.ts --teardown with empty expansion",
    cwd: shortcutFixture.cwd,
    args: ["--no-color", "--teardown", "printf bye", "npm:no-match-*"],
  },
  {
    name: "pad prefix uses longest label",
    upstream: "bin/concurrently.spec.ts --pad-prefix",
    args: [
      "--no-color",
      "-g",
      "--pad-prefix",
      "-n",
      "foo,barbaz",
      "printf foo",
      "printf bar",
    ],
  },
  {
    name: "grouped passthrough placeholders",
    upstream: "src/command-parser/expand-arguments.spec.ts",
    args: [
      "--no-color",
      "-g",
      "-P",
      "printf '%s\\n' {1}",
      "printf '%s\\n' {@}",
      "printf '%s\\n' {*}",
      "--",
      "hello world",
      "--flag",
    ],
  },
  {
    name: "passthrough disabled treats arguments as commands",
    upstream: "bin/concurrently.spec.ts --passthrough-arguments disabled",
    args: ["--no-color", "-g", "printf '{1}'", "--", "printf arg"],
  },
  {
    name: "finite restart logs restart notification",
    upstream: "bin/concurrently.spec.ts --restart-tries",
    args: ["--no-color", "--restart-tries", "1", "exit 1"],
  },
  {
    name: "negative restart tries retry until success",
    upstream: "bin/concurrently.spec.ts --restart-tries negative retry forever",
    cwd: restartFixture.cwd,
    args: [
      "--no-color",
      "--restart-tries",
      "-1",
      "--restart-after",
      "0",
      restartFixture.command,
    ],
    env: { CONCURRENTLY_RESTART_MARKER: restartFixture.marker },
    prepare: restartFixture.reset,
  },
  {
    name: "teardown logs start and exit status",
    upstream: "bin/concurrently.spec.ts --teardown",
    args: ["--no-color", "--teardown", "printf bye", "printf hey"],
  },
  {
    name: "teardown raw suppresses status lines",
    upstream: "src/logger.spec.ts logGlobalEvent raw mode",
    args: ["--no-color", "--raw", "--teardown", "printf bye", "printf hey"],
  },
  {
    name: "kill others default success projection",
    upstream: "bin/concurrently.spec.ts --kill-others",
    args: ["--no-color", "-k", "printf ok", "sleep 1"],
  },
  {
    name: "kill others success first projection",
    upstream: "bin/concurrently.spec.ts exiting conditions --success first",
    args: ["--no-color", "-k", "-s", "first", "printf ok", "sleep 1"],
  },
  {
    name: "kill others skips queued commands after success",
    upstream: "src/concurrently.spec.ts maxProcesses with killOthers",
    args: ["--no-color", "-k", "-m", "1", "printf ok", "printf queued"],
  },
  {
    name: "kill others on fail",
    upstream: "bin/concurrently.spec.ts --kill-others-on-fail",
    args: ["--no-color", "--kill-others-on-fail", "sleep 1", "exit 1"],
  },
  {
    name: "kill others skips queued commands after failure",
    upstream: "src/concurrently.spec.ts maxProcesses with killOthersOn failure",
    args: [
      "--no-color",
      "--kill-others-on-fail",
      "-m",
      "1",
      "exit 1",
      "printf queued",
    ],
  },
  {
    name: "kill others raw output",
    upstream: "src/logger.spec.ts logGlobalEvent raw mode",
    args: ["--no-color", "--raw", "-k", "printf ok", "sleep 1"],
  },
  {
    name: "max processes serializes command start",
    upstream: "src/concurrently.spec.ts maxProcesses",
    args: ["--no-color", "-g", "-m", "1", "printf one", "printf two"],
  },
  {
    name: "max processes waits for restart exhaustion",
    upstream: "concurrently --help max-processes restart note",
    cwd: restartFixture.cwd,
    args: [
      "--no-color",
      "-m",
      "1",
      "--restart-tries",
      "1",
      "--restart-after",
      "0",
      restartFixture.command,
      "printf second",
    ],
    env: { CONCURRENTLY_RESTART_MARKER: restartFixture.marker },
    prepare: restartFixture.reset,
  },
  {
    name: "handle input forwards to default command",
    upstream: "bin/concurrently.spec.ts --handle-input default target",
    args: ["--no-color", "-i", inputEchoCommand],
    input: "stop\n",
    inputDelayMs: 250,
  },
  {
    name: "handle input routes by command index",
    upstream: "bin/concurrently.spec.ts --handle-input specified process",
    args: ["--no-color", "-g", "-i", firstInputEchoCommand, secondInputEchoCommand],
    inputWrites: [
      { delayMs: 250, input: "1:two\n" },
      { delayMs: 300, input: "0:one\n" },
    ],
  },
  {
    name: "default input target routes unprefixed input",
    upstream: "bin/concurrently.spec.ts --default-input-target",
    args: [
      "--no-color",
      "-g",
      "-i",
      "--default-input-target",
      "1",
      firstInputEchoCommand,
      secondInputEchoCommand,
    ],
    inputWrites: [
      { delayMs: 250, input: "two\n" },
      { delayMs: 300, input: "0:one\n" },
    ],
  },
];

(async () => {
  try {
    for (const testCase of cases) {
      const local = await runLocal(testCase);
      const npm = await runNpm(testCase);

      assertEqual(local.status, npm.status, `${testCase.name} exit status`);
      assertEqual(local.signal, npm.signal, `${testCase.name} signal`);
      assertEqual(
        normalizeStdout(testCase, local.stdout),
        normalizeStdout(testCase, npm.stdout),
        `${testCase.name} stdout`
      );
      assertEqual(local.stderr, npm.stderr, `${testCase.name} stderr`);
      console.log(`compat ok: ${testCase.name} (${testCase.upstream})`);
    }
  } finally {
    shortcutFixture.cleanup();
    restartFixture.cleanup();
  }
})().catch((error) => {
  console.error(error);
  process.exit(1);
});

function runLocal(testCase) {
  return run(localBinary, testCase.args, testCase);
}

function runNpm(testCase) {
  return run(npmConcurrentlyBinary, testCase.args, testCase);
}

function resolveNpmConcurrentlyBinary() {
  const local = resolveLocalPinnedConcurrentlyBinary();
  if (local) {
    return local;
  }

  const result = spawnSync("npm", [
    "exec",
    "--yes",
    "--package",
    `concurrently@${npmConcurrentlyVersion}`,
    "--",
    "which",
    "concurrently",
  ], {
    cwd: resolve("."),
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });

  if (result.error) {
    throw result.error;
  }
  if (result.status !== 0) {
    throw new Error(
      `failed to resolve concurrently@${npmConcurrentlyVersion}\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`
    );
  }

  const binary = result.stdout.trim().split(/\r?\n/).pop();
  if (!binary) {
    throw new Error(`which concurrently returned no binary path`);
  }
  return binary;
}

function resolveLocalPinnedConcurrentlyBinary() {
  const configured = process.env.CONCURRENTLY_BIN;
  if (configured) {
    assertPinnedConcurrentlyVersion(configured);
    return configured;
  }

  const which = spawnSync("which", ["concurrently"], {
    cwd: resolve("."),
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  });
  const binary = which.stdout.trim().split(/\r?\n/).pop();
  if (!binary) {
    return null;
  }

  return assertPinnedConcurrentlyVersion(binary) ? binary : null;
}

function assertPinnedConcurrentlyVersion(binary) {
  const version = spawnSync(binary, ["--version"], {
    cwd: resolve("."),
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  });
  if (version.status !== 0) {
    return false;
  }

  const actual = version.stdout.trim();
  if (actual !== npmConcurrentlyVersion) {
    if (process.env.CONCURRENTLY_BIN) {
      throw new Error(
        `CONCURRENTLY_BIN must point to concurrently@${npmConcurrentlyVersion}, got ${actual}`
      );
    }
    return false;
  }
  return true;
}

function run(command, args, testCase) {
  if (testCase.prepare) {
    testCase.prepare();
  }

  if (testCase.inputDelayMs !== undefined || testCase.inputWrites !== undefined) {
    return runAsync(command, args, testCase);
  }

  const result = spawnSync(command, args, {
    cwd: testCase.cwd ?? resolve("."),
    encoding: "utf8",
    env: environmentFor(testCase),
    input: testCase.input ?? "",
    stdio: ["pipe", "pipe", "pipe"],
    timeout: testCase.timeoutMs ?? 5000,
  });

  if (result.error) {
    throw new Error(`${testCase.name}: ${result.error.message}`);
  }

  return {
    status: result.status,
    signal: result.signal,
    stdout: result.stdout,
    stderr: result.stderr,
  };
}

function runAsync(command, args, testCase) {
  return new Promise((resolvePromise, rejectPromise) => {
    const child = spawn(command, args, {
      cwd: testCase.cwd ?? resolve("."),
      env: environmentFor(testCase),
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    let settled = false;
    let inputTimers = [];
    const timeout = setTimeout(() => {
      if (settled) {
        return;
      }
      settled = true;
      child.kill("SIGKILL");
      rejectPromise(new Error(`${testCase.name}: timed out`));
    }, testCase.timeoutMs ?? 5000);

    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", (error) => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timeout);
      inputTimers.forEach(clearTimeout);
      rejectPromise(new Error(`${testCase.name}: ${error.message}`));
    });
    child.on("close", (status, signal) => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timeout);
      inputTimers.forEach(clearTimeout);
      resolvePromise({ status, signal, stdout, stderr });
    });

    const inputWrites =
      testCase.inputWrites ?? [ { delayMs: testCase.inputDelayMs, input: testCase.input ?? "" } ];
    inputWrites.forEach((write, index) => {
      inputTimers.push(setTimeout(() => {
        child.stdin.write(write.input);
        if (index === inputWrites.length - 1) {
          child.stdin.end();
        }
      }, write.delayMs));
    });
  });
}

function createShortcutFixture() {
  const cwd = mkdtempSync(resolve(tmpdir(), "concurrently-ocaml-compat-"));
  writeFileSync(
    resolve(cwd, "package.json"),
    JSON.stringify(
      {
        scripts: {
          print: "printf shortcut",
          "client build": "printf spaced",
          "build-css": "printf css",
          "build-js": "printf js",
        },
      },
      null,
      2
    )
  );
  return {
    cwd,
    cleanup() {
      rmSync(cwd, { force: true, recursive: true });
    },
  };
}

function createRestartFixture() {
  const cwd = mkdtempSync(resolve(tmpdir(), "concurrently-ocaml-restart-"));
  const marker = resolve(cwd, "attempt.state");
  const command =
    "node -e 'const fs=require(\"fs\");const p=process.env.CONCURRENTLY_RESTART_MARKER;if(fs.existsSync(p)){process.stdout.write(\"ok\");process.exit(0)}fs.writeFileSync(p,\"1\");process.exit(1)'";
  return {
    cwd,
    marker,
    command,
    reset() {
      rmSync(marker, { force: true });
    },
    cleanup() {
      rmSync(cwd, { force: true, recursive: true });
    },
  };
}

function environmentFor(testCase) {
  const env = { ...process.env, NO_COLOR: "1" };
  if (testCase.env) {
    for (const [key, value] of Object.entries(testCase.env)) {
      if (value === null) {
        delete env[key];
      } else {
        env[key] = value;
      }
    }
  }
  return env;
}

function assertEqual(actual, expected, label) {
  if (actual !== expected) {
    throw new Error(
      `${label}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`
    );
  }
}

function normalizeStdout(testCase, stdout) {
  return testCase.normalizeStdout ? testCase.normalizeStdout(stdout) : stdout;
}

function normalizeVersionStdout(stdout) {
  return stdout.replace(/^\d+\.\d+\.\d+\n$/, "<version>\n");
}

function normalizeTimingsStdout(stdout) {
  const timestampPattern = /\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}/g;
  return stdout
    .replace(timestampPattern, "<timestamp>")
    .replace(/started at \d{3}/g, "started at <timestamp>")
    .replace(/stopped at \d{3}/g, "stopped at <timestamp>")
    .replace(/after [\d,]+ms/g, "after <duration>ms")
    .split("\n")
    .map(normalizeTimingsTableRow)
    .join("\n");
}

function normalizeTimingsTableRow(line) {
  if (!line.startsWith("--> │")) {
    return line;
  }

  const cells = line
    .slice("--> ".length)
    .split("│")
    .slice(1, -1)
    .map((cell) => cell.trim());
  if (cells.length !== 5 || !/^\d[\d,]*$/.test(cells[1])) {
    return line;
  }

  cells[1] = "<duration>";
  return `--> │ ${cells.join(" │ ")} │`;
}
