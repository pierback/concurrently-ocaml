#!/usr/bin/env node

const { constants } = require("node:os");
const { runNative } = require("../lib/native");

const forwardedSignals = ["SIGHUP", "SIGINT", "SIGTERM"];

const signalExitCode = (signal) => {
  const signalNumber = constants.signals[signal];
  if (typeof signalNumber === "number") {
    return 128 + signalNumber;
  }

  return 1;
};

let child;
try {
  child = runNative(process.argv.slice(2));
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

for (const signal of forwardedSignals) {
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
