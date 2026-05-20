#!/usr/bin/env node

const { copyFileSync, chmodSync, mkdirSync, readFileSync, writeFileSync } = require("node:fs");
const { createHash } = require("node:crypto");
const { basename, join, resolve } = require("node:path");

const args = new Map();
for (let index = 2; index < process.argv.length; index += 2) {
  const key = process.argv[index];
  const value = process.argv[index + 1];
  if (!key || !key.startsWith("--") || !value) {
    throw new Error(
      "usage: package-platform --target TARGET --platform OS --arch CPU [--libc LIBC] --binary PATH"
    );
  }
  args.set(key.slice(2), value);
}

const target = required("target");
const platform = required("platform");
const arch = required("arch");
const libc = optional("libc");
const binary = resolve(required("binary"));
const expectedTarget = targetName({ platform, arch, libc });
if (target !== expectedTarget) {
  throw new Error(`target ${target} does not match expected ${expectedTarget}`);
}
const rootPackage = JSON.parse(readFileSync(resolve("package.json"), "utf8"));
const binaryName = platform === "win32" ? "concurrently-ml.exe" : "concurrently-ml";
const packageName = `${rootPackage.name}-${target}`;
const packageDir = resolve("dist", "npm", packageName.replace("/", "__"));
const binDir = join(packageDir, "bin");
const packagedBinary = join(binDir, binaryName);

mkdirSync(binDir, { recursive: true });
copyFileSync(binary, packagedBinary);
chmodSync(packagedBinary, 0o755);
writeFileSync(
  join(packageDir, "SHA256SUMS"),
  `${sha256File(packagedBinary)}  bin/${binaryName}\n`
);

writeFileSync(
  join(packageDir, "package.json"),
  `${JSON.stringify(
    withoutUndefined({
      name: packageName,
      version: rootPackage.version,
      description: `${rootPackage.description} native binary for ${target}`,
      license: rootPackage.license,
      os: [platform],
      cpu: [arch],
      libc: platform === "linux" ? [npmLibcSelector(libc)] : undefined,
      files: ["bin/", "SHA256SUMS"],
    }),
    null,
    2
  )}\n`
);

console.log(`${packageName} -> ${join(packageDir, "bin", basename(binaryName))}`);

function sha256File(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

function required(key) {
  const value = args.get(key);
  if (!value) {
    throw new Error(`missing --${key}`);
  }
  return value;
}

function optional(key) {
  return args.get(key);
}

function targetName({ platform, arch, libc }) {
  if (platform !== "linux") {
    if (libc) {
      throw new Error("--libc is only valid for linux targets");
    }
    return `${platform}-${arch}`;
  }

  if (libc !== "gnu" && libc !== "musl") {
    throw new Error("linux targets require --libc gnu or --libc musl");
  }

  return `${platform}-${arch}-${libc}`;
}

function withoutUndefined(value) {
  return Object.fromEntries(
    Object.entries(value).filter(([_key, entry]) => entry !== undefined)
  );
}

function npmLibcSelector(libc) {
  return libc === "gnu" ? "glibc" : libc;
}
