#!/usr/bin/env node

"use strict";

const { createHash } = require("node:crypto");
const {
  existsSync,
  readFileSync,
  readdirSync,
  statSync,
} = require("node:fs");
const { join, resolve } = require("node:path");

const targets = [
  { target: "darwin-arm64", os: "darwin", cpu: "arm64" },
  { target: "darwin-x64", os: "darwin", cpu: "x64" },
  { target: "linux-arm64-gnu", os: "linux", cpu: "arm64", libc: "glibc" },
  { target: "linux-arm64-musl", os: "linux", cpu: "arm64", libc: "musl" },
  { target: "linux-x64-gnu", os: "linux", cpu: "x64", libc: "glibc" },
  { target: "linux-x64-musl", os: "linux", cpu: "x64", libc: "musl" },
  { target: "win32-x64", os: "win32", cpu: "x64" },
];

const rootPackage = readJson(resolve("package.json"));
const lockfile = readJson(resolve("package-lock.json"));
const version = rootPackage.version;

assert(
  /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(version),
  `invalid package version: ${version}`
);
assertEqual(lockfile.version, version, "lockfile version");
assertEqual(lockfile.packages?.[""]?.version, version, "lockfile root version");

const ocamlVersion = readFileSync(resolve("lib", "version.ml"), "utf8").match(
  /^let current = "([^"]+)"\s*$/
)?.[1];
assertEqual(ocamlVersion, version, "OCaml binary version");

const expectedPackages = targets.map(
  ({ target }) => `${rootPackage.name}-${target}`
);
assertSameMembers(
  Object.keys(rootPackage.optionalDependencies ?? {}),
  expectedPackages,
  "root optional dependencies"
);
assertSameMembers(
  Object.keys(lockfile.packages?.[""]?.optionalDependencies ?? {}),
  expectedPackages,
  "lockfile optional dependencies"
);
for (const packageName of expectedPackages) {
  assertEqual(
    rootPackage.optionalDependencies[packageName],
    version,
    `${packageName} root dependency version`
  );
  assertEqual(
    lockfile.packages[""].optionalDependencies[packageName],
    version,
    `${packageName} lockfile dependency version`
  );
}

const tag = process.argv.slice(2).find((argument) => !argument.startsWith("--"));
if (tag !== undefined) {
  assertEqual(tag, `v${version}`, "release tag");
}

if (process.argv.includes("--dist")) {
  verifyPlatformArtifacts(rootPackage, targets);
}

console.log(`release metadata ok: v${version}`);

function verifyPlatformArtifacts(root, platformTargets) {
  const distDir = resolve("dist", "npm");
  assert(existsSync(distDir), `missing release artifact directory: ${distDir}`);

  const artifactDirs = readdirSync(distDir, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name);
  const expectedDirs = platformTargets.map(({ target }) =>
    `${root.name}-${target}`.replace("/", "__")
  );
  assertSameMembers(artifactDirs, expectedDirs, "platform artifact directories");

  for (const target of platformTargets) {
    const packageName = `${root.name}-${target.target}`;
    const packageDir = join(distDir, packageName.replace("/", "__"));
    const platformPackage = readJson(join(packageDir, "package.json"));
    const binaryName = target.os === "win32" ? "concurrently-ml.exe" : "concurrently-ml";
    const binaryPath = join(packageDir, "bin", binaryName);

    assertEqual(platformPackage.name, packageName, `${packageName} name`);
    assertEqual(platformPackage.version, root.version, `${packageName} version`);
    assertEqual(platformPackage.license, root.license, `${packageName} license`);
    assertDeepEqual(platformPackage.os, [target.os], `${packageName} os`);
    assertDeepEqual(platformPackage.cpu, [target.cpu], `${packageName} cpu`);
    assertDeepEqual(
      platformPackage.libc,
      target.libc === undefined ? undefined : [target.libc],
      `${packageName} libc`
    );
    assert(existsSync(binaryPath), `${packageName} binary is missing`);
    assert(
      (statSync(binaryPath).mode & 0o111) !== 0,
      `${packageName} binary is not executable`
    );
    const expectedChecksum = `${sha256(binaryPath)}  bin/${binaryName}\n`;
    assertEqual(
      readFileSync(join(packageDir, "SHA256SUMS"), "utf8"),
      expectedChecksum,
      `${packageName} checksum`
    );
  }
}

function readJson(path) {
  return JSON.parse(readFileSync(path, "utf8"));
}

function sha256(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function assertEqual(actual, expected, label) {
  if (actual !== expected) {
    throw new Error(`${label}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

function assertDeepEqual(actual, expected, label) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${label}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

function assertSameMembers(actual, expected, label) {
  const actualSorted = [...actual].sort();
  const expectedSorted = [...expected].sort();
  assertDeepEqual(actualSorted, expectedSorted, label);
}
