#!/usr/bin/env node

"use strict";

const {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
} = require("node:fs");
const { tmpdir } = require("node:os");
const { join, resolve } = require("node:path");
const { spawn, spawnSync } = require("node:child_process");

if (process.platform !== "win32") {
  throw new Error("smoke-windows-native must run on Windows");
}

const binary = resolve("_build", "default", "bin", "main.exe");
if (!existsSync(binary)) {
  throw new Error(`missing local binary: ${binary}; run npm run compile first`);
}

const tempDir = mkdtempSync(join(tmpdir(), "concurrently-ml-windows-"));

(async () => {
  try {
    smokeCwdEnvAndOutput();
    smokeStdin();
    smokeFailureExitStatus();
    await smokeProcessTreeCleanup();
    console.log("windows native smoke ok");
  } finally {
    rmSync(tempDir, { recursive: true, force: true });
  }
})().catch((error) => {
  console.error(error);
  process.exit(1);
});

function smokeCwdEnvAndOutput() {
  const command = nodeEvalCommand(
    "process.stdout.write('cwd:'+process.cwd()+'\\n');" +
      "process.stdout.write('env:'+process.env.CONCURRENTLY_WINDOWS_SMOKE+'\\n');" +
      "process.stderr.write('err:ok\\n')"
  );
  const result = runSync(["--no-color", command], {
    cwd: tempDir,
    env: { CONCURRENTLY_WINDOWS_SMOKE: "ok" },
  });
  assertEqual(result.status, 0, "cwd/env command status", result);
  assertEqual(result.stderr, "", "cwd/env stderr");
  assertEqual(
    result.stdout,
    `[0] cwd:${tempDir}\n` +
      "[0] env:ok\n" +
      "[0] err:ok\n" +
      `[0] ${command} exited with code 0\n`,
    "cwd/env stdout"
  );
}

function smokeStdin() {
  const command = nodeEvalCommand(
    "process.stdin.once('data',function(data){process.stdout.write(data);process.exit(0)})"
  );
  const result = runSync(["--no-color", "-i", command], {
    input: "stdin-ok\n",
  });
  assertEqual(result.status, 0, "stdin command status", result);
  assertEqual(result.stderr, "", "stdin stderr");
  assertEqual(
    result.stdout,
    `[0] stdin-ok\n[0] ${command} exited with code 0\n`,
    "stdin stdout"
  );
}

function smokeFailureExitStatus() {
  const command = nodeEvalCommand("process.exit(7)");
  const result = runSync(["--no-color", command]);
  assertEqual(result.status, 1, "failure command status", result);
  assertEqual(result.stderr, "", "failure stderr");
  assertEqual(
    result.stdout,
    `[0] ${command} exited with code 7\n`,
    "failure stdout"
  );
}

async function smokeProcessTreeCleanup() {
  const marker = join(tempDir, "child.pid");
  const command = nodeEvalCommand(
    "const cp=require('child_process');" +
      "const fs=require('fs');" +
      "const child=cp.spawn(process.execPath," +
      "['-e','setInterval(function(){},1000)'],{stdio:'ignore'});" +
      "fs.writeFileSync(process.env.CONCURRENTLY_WINDOWS_TREE_MARKER," +
      "String(child.pid));" +
      "setInterval(function(){},1000)"
  );
  const child = spawn(binary, ["--no-color", command], {
    cwd: tempDir,
    env: {
      ...process.env,
      CONCURRENTLY_WINDOWS_TREE_MARKER: marker,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stdout = "";
  let stderr = "";
  let nativeClosed = false;
  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");
  child.on("close", () => {
    nativeClosed = true;
  });
  child.stdout.on("data", (chunk) => {
    stdout += chunk;
  });
  child.stderr.on("data", (chunk) => {
    stderr += chunk;
  });

  try {
    await waitForFile(marker, 5000);
    const childPid = Number(readFileSync(marker, "utf8"));
    if (!Number.isInteger(childPid) || childPid <= 0) {
      throw new Error(
        `invalid child pid marker: ${readFileSync(marker, "utf8")}`
      );
    }

    const closed = waitForClose(child, 5000);
    child.kill("SIGTERM");
    await closed;
    await sleep(750);

    if (pidIsRunning(childPid)) {
      try {
        process.kill(childPid);
      } catch (_error) {
        // Best-effort cleanup before failing the smoke.
      }
      throw new Error(
        `job-object cleanup left child process ${childPid} running\nstdout:\n${stdout}\nstderr:\n${stderr}`
      );
    }
  } finally {
    if (!nativeClosed) {
      child.kill("SIGKILL");
    }
  }
}

function runSync(args, options = {}) {
  const result = spawnSync(binary, args, {
    cwd: options.cwd ?? resolve("."),
    encoding: "utf8",
    env: { ...process.env, ...(options.env ?? {}) },
    input: options.input ?? "",
    stdio: ["pipe", "pipe", "pipe"],
    timeout: 15000,
  });
  if (result.error) {
    throw result.error;
  }
  return result;
}

function nodeEvalCommand(source) {
  return `node -e "${source.replaceAll('"', '\\"')}"`;
}

function pidIsRunning(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (_error) {
    return false;
  }
}

function waitForFile(path, timeoutMs) {
  const startedAt = Date.now();
  return new Promise((resolvePromise, rejectPromise) => {
    const check = () => {
      if (existsSync(path)) {
        resolvePromise();
        return;
      }
      if (Date.now() - startedAt >= timeoutMs) {
        rejectPromise(new Error(`timed out waiting for ${path}`));
        return;
      }
      setTimeout(check, 25);
    };
    check();
  });
}

function waitForClose(child, timeoutMs) {
  return new Promise((resolvePromise, rejectPromise) => {
    const timeout = setTimeout(() => {
      child.kill("SIGKILL");
      rejectPromise(new Error("timed out waiting for native process to exit"));
    }, timeoutMs);
    child.on("close", () => {
      clearTimeout(timeout);
      resolvePromise();
    });
    child.on("error", (error) => {
      clearTimeout(timeout);
      rejectPromise(error);
    });
  });
}

function sleep(ms) {
  return new Promise((resolvePromise) => {
    setTimeout(resolvePromise, ms);
  });
}

function assertEqual(actual, expected, label, detail) {
  if (actual !== expected) {
    const suffix = detail
      ? `\nstdout:\n${detail.stdout}\nstderr:\n${detail.stderr}`
      : "";
    throw new Error(
      `${label}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}${suffix}`
    );
  }
}
