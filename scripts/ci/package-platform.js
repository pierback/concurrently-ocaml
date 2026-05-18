#!/usr/bin/env node

const { copyFileSync, chmodSync, mkdirSync, readFileSync, writeFileSync } = require("node:fs");
const { basename, join, resolve } = require("node:path");

const args = new Map();
for (let index = 2; index < process.argv.length; index += 2) {
  const key = process.argv[index];
  const value = process.argv[index + 1];
  if (!key || !key.startsWith("--") || !value) {
    throw new Error("usage: package-platform --target TARGET --platform OS --arch CPU --binary PATH");
  }
  args.set(key.slice(2), value);
}

const target = required("target");
const platform = required("platform");
const arch = required("arch");
const binary = resolve(required("binary"));
const rootPackage = JSON.parse(readFileSync(resolve("package.json"), "utf8"));
const binaryName = platform === "win32" ? "concurrently-ml.exe" : "concurrently-ml";
const packageName = `${rootPackage.name}-${target}`;
const packageDir = resolve("dist", "npm", packageName.replace("/", "__"));
const binDir = join(packageDir, "bin");

mkdirSync(binDir, { recursive: true });
copyFileSync(binary, join(binDir, binaryName));
chmodSync(join(binDir, binaryName), 0o755);

writeFileSync(
  join(packageDir, "package.json"),
  `${JSON.stringify(
    {
      name: packageName,
      version: rootPackage.version,
      description: `${rootPackage.description} native binary for ${target}`,
      license: rootPackage.license,
      os: [platform],
      cpu: [arch],
      files: ["bin/"],
    },
    null,
    2
  )}\n`
);

console.log(`${packageName} -> ${join(packageDir, "bin", basename(binaryName))}`);

function required(key) {
  const value = args.get(key);
  if (!value) {
    throw new Error(`missing --${key}`);
  }
  return value;
}
