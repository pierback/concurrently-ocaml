"use strict";

const { existsSync } = require("node:fs");
const { dirname, join, resolve } = require("node:path");
const { spawn } = require("node:child_process");

const packageRoot = resolve(__dirname, "..", "..");

const binaryName = process.platform === "win32" ? "concurrently-ml.exe" : "concurrently-ml";
const platformTargetName = platformTarget();
const platformPackage = `@pierback/concurrently-ml-${platformTargetName}`;

const localBinaryPath = join(packageRoot, "_build", "default", "bin", "main.exe");
const packagedBinaryPath = join(packageRoot, "concurrently-ml");

const resolvePlatformBinaryPath = () => {
  try {
    const packageJsonPath = require.resolve(`${platformPackage}/package.json`);
    return join(dirname(packageJsonPath), "bin", binaryName);
  } catch (_error) {
    return undefined;
  }
};

const sourceCheckout = () => existsSync(join(packageRoot, ".git"));

const candidateBinaryPaths = () =>
  sourceCheckout()
    ? [localBinaryPath, resolvePlatformBinaryPath(), packagedBinaryPath]
    : [resolvePlatformBinaryPath(), localBinaryPath, packagedBinaryPath];

const resolveBinaryPath = () => {
  const binaryPath = candidateBinaryPaths().find(
    (candidate) => candidate && existsSync(candidate)
  );
  if (!binaryPath) {
    throw new Error(
      `No concurrently-ml native binary was found for ${platformTargetName}. Install the matching optional platform package or run \`npm run compile\` from the package root.`
    );
  }
  return binaryPath;
};

function platformTarget() {
  if (process.platform === "linux") {
    return `${process.platform}-${process.arch}-${linuxLibc()}`;
  }
  return `${process.platform}-${process.arch}`;
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

const runNative = (args, options = {}) =>
  spawn(resolveBinaryPath(), args, {
    cwd: options.cwd ?? process.cwd(),
    env: options.env ?? process.env,
    stdio: options.stdio ?? "inherit",
  });

module.exports = {
  runNative,
  resolveBinaryPath,
};
