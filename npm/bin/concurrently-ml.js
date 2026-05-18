#!/usr/bin/env node

const { existsSync } = require("node:fs");
const { dirname, join, resolve } = require("node:path");
const { spawn } = require("node:child_process");
const { constants } = require("node:os");

const packageRoot = resolve(__dirname, "..", "..");
const binaryName = process.platform === "win32" ? "concurrently-ml.exe" : "concurrently-ml";
const platformPackage = `@pierback/concurrently-ml-${process.platform}-${process.arch}`;
const localBinaryPath = join(packageRoot, "_build", "default", "bin", "main.exe");
const packagedBinaryPath = join(packageRoot, "concurrently-ml");
const candidates = sourceCheckout()
  ? [localBinaryPath, platformBinaryPath(), packagedBinaryPath]
  : [platformBinaryPath(), localBinaryPath, packagedBinaryPath];

function platformBinaryPath() {
  try {
    const packageJsonPath = require.resolve(`${platformPackage}/package.json`);
    return join(dirname(packageJsonPath), "bin", binaryName);
  } catch (_error) {
    return undefined;
  }
}

function sourceCheckout() {
  return existsSync(join(packageRoot, ".git"));
}

const binaryPath = candidates.find((candidate) => candidate && existsSync(candidate));

if (!binaryPath) {
  console.error(
    `No concurrently-ml native binary was found for ${process.platform}-${process.arch}. Install the matching optional platform package or run \`npm run compile\` from the package root.`
  );
  process.exit(127);
}

const signalExitCodes = new Map([
  ["SIGHUP", 129],
  ["SIGINT", 130],
  ["SIGTERM", 143],
]);

const signalExitCode = (signal) => {
  const signalNumber = constants.signals[signal];
  if (typeof signalNumber === "number") {
    return 128 + signalNumber;
  }

  return 1;
};

const child = spawn(binaryPath, process.argv.slice(2), {
  cwd: process.cwd(),
  env: process.env,
  stdio: "inherit",
});

let childExited = false;

const forwardSignal = (signal) => {
  if (!childExited) {
    child.kill(signal);
  }
};

for (const signal of signalExitCodes.keys()) {
  process.on(signal, () => forwardSignal(signal));
}

child.on("error", (error) => {
  console.error(error.message);
  process.exit(127);
});

child.on("exit", (code, signal) => {
  childExited = true;

  if (signal) {
    process.exit(signalExitCode(signal));
  }

  process.exit(code ?? 1);
});
