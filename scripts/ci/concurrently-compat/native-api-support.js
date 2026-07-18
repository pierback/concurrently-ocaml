const { spawnSync } = require("node:child_process");
const { Writable } = require("node:stream");

const synchronousWaitState = new Int32Array(new SharedArrayBuffer(4));
// deno-lint-ignore no-control-regex
const stripAnsiColors = (text) => text.replace(/\u001b\[[0-9;]*m/g, "");

const waitForSync = (predicate, timeoutMs) => {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    const remainingMs = deadline - Date.now();
    if (remainingMs <= 0) {
      break;
    }
    Atomics.wait(synchronousWaitState, 0, 0, Math.min(2, remainingMs));
  }
};

function createOutputCapture() {
  let output = "";
  const stream = new Writable({
    write(chunk, _encoding, callback) {
      output += chunk.toString();
      callback();
    },
  });

  return {
    stream,
    read() {
      return output;
    },
  };
}

function createDiscardSink() {
  return new Writable({
    write(_chunk, _encoding, callback) {
      callback();
    },
  });
}

function restoreEnvironmentValue(name, value) {
  if (value === undefined) {
    delete process.env[name];
  } else {
    process.env[name] = value;
  }
}

function waitFor(predicate, timeoutMs, label) {
  const startMs = Date.now();
  return new Promise((resolvePromise, rejectPromise) => {
    const poll = () => {
      if (predicate()) {
        resolvePromise();
        return;
      }
      if (Date.now() - startMs >= timeoutMs) {
        rejectPromise(new Error(label));
        return;
      }
      setTimeout(poll, 20);
    };
    poll();
  });
}

function processRunning(pid) {
  if (!Number.isInteger(pid)) {
    return false;
  }
  if (process.platform === "win32") {
    try {
      process.kill(pid, 0);
      return true;
    } catch (_error) {
      return false;
    }
  }
  const result = spawnSync("ps", ["-p", String(pid), "-o", "stat="], {
    encoding: "utf8",
  });
  if (result.status !== 0) {
    return false;
  }
  return !result.stdout.trim().startsWith("Z");
}

function forceKillProcessForTest(pid) {
  if (!Number.isInteger(pid)) {
    return;
  }
  if (process.platform === "win32") {
    spawnSync("taskkill", ["/pid", String(pid), "/T", "/F"], { stdio: "ignore" });
    return;
  }
  try {
    process.kill(pid, "SIGKILL");
  } catch (_error) {
    // The process may already have exited.
  }
}

module.exports = {
  createDiscardSink,
  createOutputCapture,
  forceKillProcessForTest,
  processRunning,
  restoreEnvironmentValue,
  stripAnsiColors,
  waitFor,
  waitForSync,
};
