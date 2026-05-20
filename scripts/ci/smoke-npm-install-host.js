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
  target.name,
  "--platform",
  process.platform,
  "--arch",
  process.arch,
  ...target.libcArgs,
  "--binary",
  binary,
]);
runNpmScript("smoke:npm-install", [
  "--",
  "--target",
  target.name,
  "--platform",
  process.platform,
  "--arch",
  process.arch,
  ...target.libcArgs,
]);

function hostTarget() {
  if (process.platform === "darwin") {
    assertSupportedArch();
    return { name: `darwin-${process.arch}`, libcArgs: [] };
  }

  if (process.platform === "linux") {
    assertSupportedArch();
    const libc = linuxLibc();
    return {
      name: `linux-${process.arch}-${libc}`,
      libcArgs: ["--libc", libc],
    };
  }

  throw new Error(
    `host native package smoke is not supported on ${process.platform}; run npm run smoke:windows-js for the Windows drop-in package route`
  );
}

function assertSupportedArch() {
  if (process.arch !== "x64" && process.arch !== "arm64") {
    throw new Error(`unsupported npm smoke architecture: ${process.arch}`);
  }
}

function linuxLibc() {
  try {
    const header = process.report?.getReport?.().header ?? {};
    if (header.glibcVersionRuntime || header.glibcVersionCompiler) {
      return "gnu";
    }
  } catch (_error) {
    return "musl";
  }
  return "musl";
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
