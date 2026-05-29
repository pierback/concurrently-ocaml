#!/usr/bin/env node

const { existsSync } = require("node:fs");
const { resolve, sep } = require("node:path");
const { spawnSync } = require("node:child_process");

const npmConcurrentlyVersion = "10.0.0";
const localBinary = resolve("_build", "default", "bin", "main.exe");

const options = parseOptions(process.argv.slice(2));
const npmConcurrentlyBinary = resolveNpmConcurrentlyBinary();

if (!existsSync(localBinary)) {
  throw new Error(`missing local binary: ${localBinary}; run npm run compile first`);
}

const workloads = [
  {
    name: "version",
    args: ["--version"],
    expectStdoutBytes: undefined,
  },
  {
    name: `${options.commandCount} short commands`,
    args: [
      "--raw",
      "--no-color",
      ...Array.from({ length: options.commandCount }, () => "printf x"),
    ],
    expectStdoutBytes: options.commandCount,
  },
  {
    name: `${options.lineCount} streamed lines`,
    args: [
      "--raw",
      "--no-color",
      `node -e "for(let i=0;i<${options.lineCount};i++)console.log('line'+i)"`,
    ],
    expectStdoutBytes: streamedOutputBytes(options.lineCount),
  },
];

for (const workload of workloads) {
  warmup(localBinary, workload);
  warmup(npmConcurrentlyBinary, workload);

  const nativeSamples = [];
  const npmSamples = [];
  for (let iteration = 0; iteration < options.iterations; iteration += 1) {
    nativeSamples.push(measure(localBinary, workload).durationMs);
    npmSamples.push(measure(npmConcurrentlyBinary, workload).durationMs);
  }

  printResult(workload.name, nativeSamples, npmSamples);
}

function parseOptions(args) {
  const values = {
    iterations: 9,
    commandCount: 24,
    lineCount: 1000,
  };
  for (let index = 0; index < args.length; index += 2) {
    const key = args[index];
    const value = args[index + 1];
    if (!key || !key.startsWith("--") || value === undefined) {
      throw new Error(
        "usage: perf-concurrently [--iterations N] [--commands N] [--lines N]"
      );
    }
    if (key === "--iterations") {
      values.iterations = boundedInteger(value, key, 1, 100);
    } else if (key === "--commands") {
      values.commandCount = boundedInteger(value, key, 1, 200);
    } else if (key === "--lines") {
      values.lineCount = boundedInteger(value, key, 1, 50000);
    } else {
      throw new Error(`unknown option: ${key}`);
    }
  }
  return values;
}

function boundedInteger(value, label, minimum, maximum) {
  if (!/^\d+$/.test(value)) {
    throw new Error(`${label} must be an integer`);
  }
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < minimum || parsed > maximum) {
    throw new Error(`${label} must be between ${minimum} and ${maximum}`);
  }
  return parsed;
}

function warmup(binary, workload) {
  measure(binary, workload);
}

function measure(binary, workload) {
  const startedAt = process.hrtime.bigint();
  const result = spawnSync(binary, workload.args, {
    cwd: resolve("."),
    encoding: "buffer",
    env: { ...process.env, NO_COLOR: "1" },
    stdio: ["ignore", "pipe", "pipe"],
    timeout: 30000,
  });
  const endedAt = process.hrtime.bigint();

  if (result.error) {
    throw result.error;
  }
  if (result.status !== 0) {
    throw new Error(
      `${binary} ${workload.name} exited ${result.status}\nstdout:\n${result.stdout.toString("utf8")}\nstderr:\n${result.stderr.toString("utf8")}`
    );
  }
  if (result.stderr.length !== 0) {
    throw new Error(
      `${binary} ${workload.name} wrote stderr:\n${result.stderr.toString("utf8")}`
    );
  }
  if (
    workload.expectStdoutBytes !== undefined &&
    result.stdout.length !== workload.expectStdoutBytes
  ) {
    throw new Error(
      `${binary} ${workload.name} stdout length: expected ${workload.expectStdoutBytes}, got ${result.stdout.length}`
    );
  }

  return { durationMs: Number(endedAt - startedAt) / 1_000_000 };
}

function streamedOutputBytes(lineCount) {
  let bytes = 0;
  for (let index = 0; index < lineCount; index += 1) {
    bytes += Buffer.byteLength(`line${index}\n`);
  }
  return bytes;
}

function printResult(name, nativeSamples, npmSamples) {
  const nativeStats = stats(nativeSamples);
  const npmStats = stats(npmSamples);
  const speedup = npmStats.medianMs / nativeStats.medianMs;
  console.log(
    [
      name,
      `native median ${formatMs(nativeStats.medianMs)}`,
      `npm median ${formatMs(npmStats.medianMs)}`,
      `median speedup ${speedup.toFixed(2)}x`,
      `native mean ${formatMs(nativeStats.meanMs)}`,
      `npm mean ${formatMs(npmStats.meanMs)}`,
      `native min ${formatMs(nativeStats.minMs)}`,
      `npm min ${formatMs(npmStats.minMs)}`,
    ].join(" | ")
  );
}

function stats(samples) {
  if (samples.length === 0) {
    throw new Error("empty sample set");
  }
  const sorted = [...samples].sort((left, right) => left - right);
  const sum = sorted.reduce((total, value) => total + value, 0);
  return {
    medianMs: sorted[Math.floor(sorted.length / 2)],
    meanMs: sum / sorted.length,
    minMs: sorted[0],
  };
}

function formatMs(value) {
  return `${value.toFixed(2)}ms`;
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
    throw new Error("which concurrently returned no binary path");
  }
  return binary;
}

function resolveLocalPinnedConcurrentlyBinary() {
  const configured = process.env.CONCURRENTLY_BIN;
  if (configured) {
    const configuredBinary = resolveVoltaShim(configured);
    if (!isPinnedConcurrentlyVersion(configuredBinary)) {
      throw new Error(
        `CONCURRENTLY_BIN must point to concurrently@${npmConcurrentlyVersion}`
      );
    }
    return configuredBinary;
  }

  const which = spawnSync("which", ["concurrently"], {
    cwd: resolve("."),
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  });
  const binary = resolveVoltaShim(which.stdout.trim().split(/\r?\n/).pop());
  if (!binary) {
    return null;
  }

  return isPinnedConcurrentlyVersion(binary) ? binary : null;
}

function resolveVoltaShim(binary) {
  if (!binary || !binary.includes(`${sep}.volta${sep}bin${sep}`)) {
    return binary;
  }

  const result = spawnSync("volta", ["which", "concurrently"], {
    cwd: resolve("."),
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  });
  if (result.status !== 0) {
    return binary;
  }

  return result.stdout.trim().split(/\r?\n/).pop() || binary;
}

function isPinnedConcurrentlyVersion(binary) {
  const version = spawnSync(binary, ["--version"], {
    cwd: resolve("."),
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  });
  if (version.status !== 0) {
    return false;
  }

  const actual = version.stdout.trim();
  return actual === npmConcurrentlyVersion;
}
