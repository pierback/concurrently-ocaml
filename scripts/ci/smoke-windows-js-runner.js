#!/usr/bin/env node

"use strict";

const {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} = require("node:fs");
const { tmpdir } = require("node:os");
const { basename, join, resolve } = require("node:path");
const { spawnSync } = require("node:child_process");

if (process.platform !== "win32") {
  throw new Error("Windows JS runner smoke must run on a Windows host");
}
if (process.arch !== "x64" && process.arch !== "arm64") {
  throw new Error(`unsupported Windows smoke architecture: ${process.arch}`);
}

const packageRoot = resolve(".");
const rootPackage = JSON.parse(readFileSync(resolve("package.json"), "utf8"));
const publicPackageName = "concurrently";
const tempDir = mkdtempSync(join(tmpdir(), "concurrently-ml-windows-js-"));
const npmCacheDir = join(tempDir, "npm-cache");

try {
  const rootTarball = npmPack(packageRoot, tempDir);
  const projectDir = join(tempDir, "project");
  mkdirProject(projectDir);
  npmRun(
    [
      "install",
      "--ignore-scripts",
      "--no-audit",
      "--no-fund",
      "--prefer-offline",
      `${publicPackageName}@file:${rootTarball}`,
    ],
    projectDir
  );

  const installedRootDir = join(projectDir, "node_modules", publicPackageName);
  assertFile(join(installedRootDir, "npm", "lib", "upstream-cli.js"));
  const upstreamCli = require(join(
    installedRootDir,
    "npm",
    "lib",
    "upstream-cli.js"
  ));
  const upstreamCliPath = upstreamCli.resolveUpstreamCliPath();
  assertFile(upstreamCliPath);
  if (!upstreamCliPath.includes(`${publicPackageName}-js`)) {
    throw new Error(`unexpected upstream CLI path: ${upstreamCliPath}`);
  }

  const binPath = join(projectDir, "node_modules", ".bin", "concurrently.cmd");
  assertFile(binPath);
  const binScriptPath = join(
    installedRootDir,
    "npm",
    "bin",
    "concurrently-ml.js"
  );
  assertFile(binScriptPath);
  const smoke = spawnSync(
    process.execPath,
    [binScriptPath, "--no-color", "node -e \"console.log('windows-js')\""],
    { cwd: projectDir, encoding: "utf8" }
  );
  if (smoke.error) {
    throw smoke.error;
  }
  if (smoke.status !== 0) {
    throw new Error(
      `Windows JS runner smoke exited ${smoke.status}\nstdout:\n${smoke.stdout}\nstderr:\n${smoke.stderr}`
    );
  }
  if (
    !smoke.stdout.includes("[0] windows-js\n") ||
    !smoke.stdout.includes("exited with code 0\n")
  ) {
    throw new Error(
      `Windows JS runner smoke produced unexpected stdout\nstdout:\n${smoke.stdout}\nstderr:\n${smoke.stderr}`
    );
  }
  if (smoke.stderr !== "") {
    throw new Error(`Windows JS runner smoke produced stderr:\n${smoke.stderr}`);
  }

  console.log(`windows js smoke ok: ${basename(rootTarball)}`);
} finally {
  rmSync(tempDir, { recursive: true, force: true });
}

function mkdirProject(path) {
  rmSync(path, { recursive: true, force: true });
  mkdirSync(path, { recursive: true });
  writeFileSync(join(path, "package.json"), '{"private":true}\n');
}

function npmPack(path, destination) {
  const output = npmRun(["pack", path, "--pack-destination", destination], packageRoot);
  const tarball = output.stdout.trim().split(/\r?\n/).pop();
  if (!tarball) {
    throw new Error(`npm pack produced no tarball name for ${path}`);
  }
  const tarballPath = join(destination, tarball);
  assertFile(tarballPath);
  return tarballPath;
}

function npmRun(args, cwd) {
  const result = spawnSync("npm.cmd", args, {
    cwd,
    encoding: "utf8",
    env: { ...process.env, npm_config_cache: npmCacheDir },
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (result.error) {
    throw result.error;
  }
  if (result.status !== 0) {
    throw new Error(
      `npm ${args.join(" ")} exited ${result.status}\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`
    );
  }
  return result;
}

function assertFile(path) {
  if (!existsSync(path) || !statSync(path).isFile()) {
    throw new Error(`expected file: ${path}`);
  }
}
