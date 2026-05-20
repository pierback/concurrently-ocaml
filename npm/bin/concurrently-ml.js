#!/usr/bin/env node

const { constants } = require("node:os");
const { runNative } = require("../lib/native");

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

let child;
try {
  child = runForPlatform(process.argv.slice(2));
} catch (error) {
  console.error(error.message);
  process.exit(127);
}

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

function runForPlatform(args) {
  return runNative(args);
}
