#!/usr/bin/env node

"use strict";

const { existsSync } = require("node:fs");
const { spawnSync } = require("node:child_process");
const { resolve } = require("node:path");

const binary = resolve("_build", "default", "bin", "main.exe");
if (!existsSync(binary)) {
  throw new Error(
    `native binary is missing at ${binary}; run \`npm run build\` first`
  );
}

const target = hostTarget();
runNpmScript("package:platform", [
  "--",
  "--target",
  target,
  "--platform",
  process.platform,
  "--arch",
  process.arch,
  "--binary",
  binary,
]);
runNpmScript("smoke:npm-install", [
  "--",
  "--target",
  target,
  "--platform",
  process.platform,
  "--arch",
  process.arch,
]);

function hostTarget() {
  if (process.platform === "darwin") {
    assertSupportedArch();
    return `darwin-${process.arch}`;
  }

  if (process.platform === "linux") {
    assertSupportedArch();
    if (!isGlibcLinux()) {
      throw new Error(
        "host npm install smoke is only supported for Linux GNU until a real musl build target exists"
      );
    }
    return `linux-${process.arch}-gnu`;
  }

  throw new Error(
    `host npm install smoke is not supported on ${process.platform}; Windows packages are withheld until a Windows backend exists`
  );
}

function assertSupportedArch() {
  if (process.arch !== "x64" && process.arch !== "arm64") {
    throw new Error(`unsupported npm smoke architecture: ${process.arch}`);
  }
}

function isGlibcLinux() {
  try {
    const header = process.report?.getReport?.().header ?? {};
    return Boolean(header.glibcVersionRuntime || header.glibcVersionCompiler);
  } catch (_error) {
    return false;
  }
}

function runNpmScript(script, args) {
  const npm = process.platform === "win32" ? "npm.cmd" : "npm";
  const result = spawnSync(npm, ["run", script, ...args], {
    cwd: resolve("."),
    encoding: "utf8",
    stdio: "inherit",
  });
  if (result.error) {
    throw result.error;
  }
  if (result.status !== 0) {
    throw new Error(`npm run ${script} exited ${result.status}`);
  }
}
