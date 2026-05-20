#!/usr/bin/env node

const {
  existsSync,
  mkdirSync,
  mkdtempSync,
  realpathSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} = require("node:fs");
const { createHash } = require("node:crypto");
const { tmpdir } = require("node:os");
const { basename, join, resolve } = require("node:path");
const { spawnSync } = require("node:child_process");

const args = new Map();
for (let index = 2; index < process.argv.length; index += 2) {
  const key = process.argv[index];
  const value = process.argv[index + 1];
  if (!key || !key.startsWith("--") || !value) {
    throw new Error("usage: smoke-npm-install --target TARGET --platform OS --arch CPU");
  }
  args.set(key.slice(2), value);
}

const target = required("target");
const platform = required("platform");
const arch = required("arch");
const packageRoot = resolve(".");
const rootPackage = readJson(resolve("package.json"));
const publicPackageName = "concurrently";
const platformPackageName = `${rootPackage.name}-${target}`;
const platformPackageDir = resolve(
  "dist",
  "npm",
  platformPackageName.replace("/", "__")
);
const platformPackageJsonPath = join(platformPackageDir, "package.json");
const nativeBinaryName = platform === "win32" ? "concurrently-ml.exe" : "concurrently-ml";
const nativeBinaryPath = join(
  platformPackageDir,
  "bin",
  nativeBinaryName
);
const checksumPath = join(platformPackageDir, "SHA256SUMS");

assertEqual(process.platform, platform, "smoke host platform");
assertEqual(process.arch, arch, "smoke host architecture");
assertFile(platformPackageJsonPath);
assertFile(nativeBinaryPath);

const platformPackage = readJson(platformPackageJsonPath);
assertEqual(platformPackage.name, platformPackageName, "platform package name");
assertEqual(platformPackage.version, rootPackage.version, "platform package version");
assertEqual(
  rootPackage.optionalDependencies[platformPackageName],
  rootPackage.version,
  "root optional dependency version"
);
assertArrayEqual(platformPackage.os, [platform], "platform package os");
assertArrayEqual(platformPackage.cpu, [arch], "platform package cpu");
assertArrayEqual(platformPackage.files, ["bin/", "SHA256SUMS"], "platform package files");
assertExecutable(nativeBinaryPath);
assertChecksum(checksumPath, `bin/${nativeBinaryName}`, nativeBinaryPath);

const tempDir = mkdtempSync(join(tmpdir(), `concurrently-ml-${target}-`));
const npmCacheDir = join(tempDir, "npm-cache");
try {
  const rootTarball = npmPack(packageRoot, tempDir);
  const platformTarball = npmPack(platformPackageDir, tempDir);
  const projectDir = join(tempDir, "project");

  mkdirProject(projectDir);
  npmRun(
    [
      "install",
      "--ignore-scripts",
      "--no-audit",
      "--no-fund",
      "--prefer-offline",
      platformTarball,
      `${publicPackageName}@file:${rootTarball}`,
    ],
    projectDir
  );

  const binPath = join(
    projectDir,
    "node_modules",
    ".bin",
    process.platform === "win32" ? "conc.cmd" : "conc"
  );
  const concurrentlyBinPath = join(
    projectDir,
    "node_modules",
    ".bin",
    process.platform === "win32" ? "concurrently.cmd" : "concurrently"
  );
  const installedRootDir = join(
    projectDir,
    "node_modules",
    publicPackageName
  );
  const installedPlatformDir = join(
    projectDir,
    "node_modules",
    ...platformPackageName.split("/")
  );
  const installedPlatformBinaryPath = join(
    installedPlatformDir,
    "bin",
    nativeBinaryName
  );
  const installedChecksumPath = join(installedPlatformDir, "SHA256SUMS");
  assertFile(binPath);
  assertFile(concurrentlyBinPath);
  assertFile(installedPlatformBinaryPath);
  assertChecksum(
    installedChecksumPath,
    `bin/${nativeBinaryName}`,
    installedPlatformBinaryPath
  );
  assertFile(join(installedRootDir, "index.js"));
  assertFile(join(installedRootDir, "index.mjs"));
  assertFile(join(installedRootDir, "index.d.ts"));
  assertFile(join(installedRootDir, "index.d.mts"));
  assertFile(join(installedRootDir, "npm", "lib", "native.js"));
  assertNoPackedSourceTree(installedRootDir);

  const native = require(join(installedRootDir, "npm", "lib", "native.js"));
  assertEqual(
    realpathSync(native.resolveBinaryPath()),
    realpathSync(installedPlatformBinaryPath),
    "native resolver binary path"
  );

  const smoke = spawnSync(binPath, ["--no-color", "printf smoke"], {
    cwd: projectDir,
    encoding: "utf8",
  });
  if (smoke.error) {
    throw smoke.error;
  }
  if (smoke.status !== 0) {
    throw new Error(
      `conc smoke exited ${smoke.status}\nstdout:\n${smoke.stdout}\nstderr:\n${smoke.stderr}`
    );
  }
  assertEqual(
    smoke.stdout,
    "[0] smoke\n[0] printf smoke exited with code 0\n",
    "conc smoke stdout"
  );
  assertEqual(smoke.stderr, "", "conc smoke stderr");

  const concurrentlySmoke = spawnSync(
    concurrentlyBinPath,
    ["--no-color", "printf concurrently"],
    {
      cwd: projectDir,
      encoding: "utf8",
    }
  );
  if (concurrentlySmoke.error) {
    throw concurrentlySmoke.error;
  }
  if (concurrentlySmoke.status !== 0) {
    throw new Error(
      `concurrently smoke exited ${concurrentlySmoke.status}\nstdout:\n${concurrentlySmoke.stdout}\nstderr:\n${concurrentlySmoke.stderr}`
    );
  }
  assertEqual(
    concurrentlySmoke.stdout,
    "[0] concurrently\n[0] printf concurrently exited with code 0\n",
    "concurrently smoke stdout"
  );
  assertEqual(concurrentlySmoke.stderr, "", "concurrently smoke stderr");

  const versionSmoke = spawnSync(binPath, ["--version"], {
    cwd: projectDir,
    encoding: "utf8",
  });
  if (versionSmoke.error) {
    throw versionSmoke.error;
  }
  if (versionSmoke.status !== 0) {
    throw new Error(
      `conc --version exited ${versionSmoke.status}\nstdout:\n${versionSmoke.stdout}\nstderr:\n${versionSmoke.stderr}`
    );
  }
  assertEqual(versionSmoke.stdout, `${rootPackage.version}\n`, "conc version stdout");
  assertEqual(versionSmoke.stderr, "", "conc version stderr");

  const apiSmoke = spawnSync(
    process.execPath,
    [
      "-e",
      `
      const concurrently = require(${JSON.stringify(publicPackageName)});
      if (typeof concurrently !== "function") {
        throw new Error("default export is not callable");
      }
      if (typeof concurrently.createConcurrently !== "function") {
        throw new Error("createConcurrently export is missing");
      }
      const run = concurrently(['node -e "process.exit(0)"'], { raw: true });
      if (!run || !Array.isArray(run.commands) || run.commands.length !== 1) {
        throw new Error("invalid concurrently result commands");
      }
      run.result.then((events) => {
        if (!Array.isArray(events) || events.length !== 1 || events[0].exitCode !== 0) {
          throw new Error("invalid concurrently result events");
        }
        process.stdout.write("api smoke ok\\n");
      }, (error) => {
        console.error(error);
        process.exit(1);
      });
      `,
    ],
    { cwd: projectDir, encoding: "utf8" }
  );
  if (apiSmoke.error) {
    throw apiSmoke.error;
  }
  if (apiSmoke.status !== 0) {
    throw new Error(
      `programmatic API smoke exited ${apiSmoke.status}\nstdout:\n${apiSmoke.stdout}\nstderr:\n${apiSmoke.stderr}`
    );
  }
  assertEqual(apiSmoke.stdout, "api smoke ok\n", "programmatic API smoke stdout");
  assertEqual(apiSmoke.stderr, "", "programmatic API smoke stderr");

  const esmApiSmoke = spawnSync(
    process.execPath,
    [
      "--input-type=module",
      "-e",
      `
      import concurrently, { createConcurrently } from ${JSON.stringify(publicPackageName)};
      if (typeof concurrently !== "function") {
        throw new Error("default ESM export is not callable");
      }
      if (typeof createConcurrently !== "function") {
        throw new Error("createConcurrently ESM export is missing");
      }
      const run = concurrently(['node -e "process.exit(0)"'], { raw: true });
      const events = await run.result;
      if (!Array.isArray(events) || events.length !== 1 || events[0].exitCode !== 0) {
        throw new Error("invalid concurrently ESM result events");
      }
      process.stdout.write("esm api smoke ok\\n");
      `,
    ],
    { cwd: projectDir, encoding: "utf8" }
  );
  if (esmApiSmoke.error) {
    throw esmApiSmoke.error;
  }
  if (esmApiSmoke.status !== 0) {
    throw new Error(
      `programmatic ESM API smoke exited ${esmApiSmoke.status}\nstdout:\n${esmApiSmoke.stdout}\nstderr:\n${esmApiSmoke.stderr}`
    );
  }
  assertEqual(
    esmApiSmoke.stdout,
    "esm api smoke ok\n",
    "programmatic ESM API smoke stdout"
  );
  assertEqual(esmApiSmoke.stderr, "", "programmatic ESM API smoke stderr");

  const helpSmoke = spawnSync(binPath, ["-h"], {
    cwd: projectDir,
    encoding: "utf8",
  });
  if (helpSmoke.error) {
    throw helpSmoke.error;
  }
  if (helpSmoke.status !== 0) {
    throw new Error(
      `conc -h exited ${helpSmoke.status}\nstdout:\n${helpSmoke.stdout}\nstderr:\n${helpSmoke.stderr}`
    );
  }
  if (!helpSmoke.stdout.startsWith("concurrently [options] <command ...>") || helpSmoke.stderr !== "") {
    throw new Error(
      `conc -h did not produce clean help output\nstdout:\n${helpSmoke.stdout}\nstderr:\n${helpSmoke.stderr}`
    );
  }

  const concurrentlyHelpSmoke = spawnSync(concurrentlyBinPath, ["--help"], {
    cwd: projectDir,
    encoding: "utf8",
  });
  if (concurrentlyHelpSmoke.error) {
    throw concurrentlyHelpSmoke.error;
  }
  if (concurrentlyHelpSmoke.status !== 0) {
    throw new Error(
      `concurrently --help exited ${concurrentlyHelpSmoke.status}\nstdout:\n${concurrentlyHelpSmoke.stdout}\nstderr:\n${concurrentlyHelpSmoke.stderr}`
    );
  }
  assertEqual(concurrentlyHelpSmoke.stdout, helpSmoke.stdout, "concurrently help stdout");
  assertEqual(concurrentlyHelpSmoke.stderr, "", "concurrently help stderr");

  console.log(
    `smoke ok: ${basename(rootTarball)} + ${basename(platformTarball)} -> ${smoke.stdout.trim()}`
  );
} finally {
  rmSync(tempDir, { recursive: true, force: true });
}

function required(key) {
  const value = args.get(key);
  if (!value) {
    throw new Error(`missing --${key}`);
  }
  return value;
}

function readJson(path) {
  return JSON.parse(readFileSync(path, "utf8"));
}

function assertFile(path) {
  if (!existsSync(path) || !statSync(path).isFile()) {
    throw new Error(`expected file: ${path}`);
  }
}

function assertNoFile(path) {
  if (existsSync(path)) {
    throw new Error(`unexpected file: ${path}`);
  }
}

function assertExecutable(path) {
  const mode = statSync(path).mode;
  if ((mode & 0o111) === 0) {
    throw new Error(`expected executable file mode: ${path}`);
  }
}

function assertChecksum(checksumPath, expectedRelativePath, binaryPath) {
  assertFile(checksumPath);
  const expected = `${sha256File(binaryPath)}  ${expectedRelativePath}\n`;
  const actual = readFileSync(checksumPath, "utf8");
  assertEqual(actual, expected, `${checksumPath} contents`);
}

function sha256File(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

function assertEqual(actual, expected, label) {
  if (actual !== expected) {
    throw new Error(`${label}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

function assertArrayEqual(actual, expected, label) {
  assertEqual(JSON.stringify(actual), JSON.stringify(expected), label);
}

function assertNoPackedSourceTree(packageDir) {
  const forbiddenPaths = [
    "bin/main.ml",
    "dune-project",
    "concurrentlyocaml.opam",
    "lib/runner.ml",
    "scripts/ci/compat-concurrently.js",
    "test/domain_tests.ml",
  ];
  for (const relativePath of forbiddenPaths) {
    const packedPath = join(packageDir, relativePath);
    if (existsSync(packedPath)) {
      throw new Error(`root npm package leaked source/build file: ${relativePath}`);
    }
  }
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
  const npm = process.platform === "win32" ? "npm.cmd" : "npm";
  const result = spawnSync(npm, args, {
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
