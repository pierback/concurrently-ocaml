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
    throw new Error(
      "usage: smoke-npm-install --target TARGET --platform OS --arch CPU [--libc LIBC]"
    );
  }
  args.set(key.slice(2), value);
}

const target = required("target");
const platform = required("platform");
const arch = required("arch");
const libc = optional("libc");
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
assertLinuxLibc(platformPackage);
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
  assertFile(join(installedRootDir, "npm", "lib", "api.js"));
  assertFile(join(installedRootDir, "npm", "lib", "native.js"));
  assertNoUpstreamFallbackDependency(projectDir, installedRootDir);
  assertNoPackedSourceTree(installedRootDir);

  const native = require(join(installedRootDir, "npm", "lib", "native.js"));
  assertEqual(
    realpathSync(native.resolveBinaryPath()),
    realpathSync(installedPlatformBinaryPath),
    "native resolver binary path"
  );

  const smokeCommand = platformCommand("smoke");
  const smoke = spawnFileSync(binPath, ["--no-color", smokeCommand], {
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
  assertSmokeOutput(smoke.stdout, "smoke", smokeCommand, "conc smoke stdout");
  assertEqual(smoke.stderr, "", "conc smoke stderr");

  const concurrentlyCommand = platformCommand("concurrently");
  const concurrentlySmoke = spawnFileSync(
    concurrentlyBinPath,
    ["--no-color", concurrentlyCommand],
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
  assertSmokeOutput(
    concurrentlySmoke.stdout,
    "concurrently",
    concurrentlyCommand,
    "concurrently smoke stdout"
  );
  assertEqual(concurrentlySmoke.stderr, "", "concurrently smoke stderr");

  const versionSmoke = spawnFileSync(binPath, ["--version"], {
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
      const { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, writeFileSync } = require("node:fs");
      const { tmpdir } = require("node:os");
      const { delimiter, join } = require("node:path");
      const { PassThrough, Writable } = require("node:stream");
      const { runInNewContext } = require("node:vm");
      if (typeof concurrently !== "function") {
        throw new Error("default export is not callable");
      }
      if (typeof concurrently.createConcurrently !== "function") {
        throw new Error("createConcurrently export is missing");
      }
      const configured = concurrently.createConcurrently({ raw: true });
      if (typeof configured !== "function") {
        throw new Error("createConcurrently factory result is missing");
      }
      const timingInfo = concurrently.LogTimings.mapCloseEventToTimingInfo({
        command: { name: "api", command: "node -e noop" },
        timings: {
          startDate: new Date(100),
          endDate: new Date(500),
        },
        killed: false,
        exitCode: 0,
      });
      if (timingInfo.duration !== "400") {
        throw new Error("LogTimings duration did not match upstream milliseconds: " + JSON.stringify(timingInfo));
      }
      const apiSource = readFileSync(
        join(process.cwd(), "node_modules", "concurrently", "npm", "lib", "api.js"),
        "utf8"
      );
      const apiSandbox = {
        require(id) {
          return id === "./native" ? { runNative() { throw new Error("unexpected native run"); } } : require(id);
        },
        module: { exports: {} },
        exports: {},
        process,
      };
      runInNewContext(apiSource + "\\nmodule.exports.__windowsShellQuote = windowsShellQuote;", apiSandbox);
      const quotedPercent = apiSandbox.module.exports.__windowsShellQuote("%PATH%");
      if (quotedPercent.includes("%PATH%") || !quotedPercent.includes("^%PATH^%")) {
        throw new Error("Windows shell quote did not escape percent signs: " + quotedPercent);
      }
      const stringCommand = concurrently(['node -e "process.exit(0)"'], { raw: true });
      if (stringCommand.commands[0].name !== "") {
        throw new Error("string command default name diverged from concurrently");
      }
      const stringCommandResult = stringCommand.result;
      const objectCommand = concurrently([{ command: 'node -e "process.exit(0)"' }], { raw: true });
      if (objectCommand.commands[0].name !== "") {
        throw new Error("object command default name diverged from concurrently");
      }
      const objectCommandResult = objectCommand.result;
      let dashPrefixedOutput = "";
      const dashPrefixedStream = new Writable({
        write(chunk, _encoding, callback) {
          dashPrefixedOutput += chunk.toString();
          callback();
        },
      });
      const dashPrefixedCommand = concurrently(["-v"], {
        raw: true,
        outputStream: dashPrefixedStream,
      });
      const dashPrefixedCommandResult = Promise.race([
        dashPrefixedCommand.result.then((events) => {
          throw new Error("dash-prefixed command unexpectedly resolved: " + JSON.stringify(events));
        }, (events) => {
          if (!Array.isArray(events) || events.length !== 1) {
            throw new Error("invalid dash-prefixed command result: " + JSON.stringify(events));
          }
        }),
        new Promise((_resolve, reject) => setTimeout(() => reject(new Error("dash-prefixed command hung")), 30000)),
      ]);
      const shortcutOutputSink = new Writable({
        write(_chunk, _encoding, callback) {
          callback();
        },
      });
      const shortcutRun = concurrently(["npm:api-echo"], {
        raw: true,
        outputStream: shortcutOutputSink,
        successCondition: "command-api-echo",
      });
      if (shortcutRun.commands[0]?.command !== "npm run api-echo") {
        throw new Error("npm shortcut command was not expanded: " + JSON.stringify(shortcutRun.commands));
      }
      if (shortcutRun.commands[0]?.name !== "api-echo") {
        throw new Error("npm shortcut command name was not preserved: " + JSON.stringify(shortcutRun.commands));
      }
      const shortcutResult = shortcutRun.result.then((events) => {
        if (!Array.isArray(events) || events.length !== 1 || events[0].exitCode !== 0) {
          throw new Error("invalid npm shortcut result events: " + JSON.stringify(events));
        }
      });
      const shortcutArgsRun = concurrently(["npm:api-args -- --flag"], {
        raw: true,
        outputStream: shortcutOutputSink,
      });
      if (shortcutArgsRun.commands[0]?.command !== "npm run api-args -- --flag") {
        throw new Error("npm shortcut suffix was not preserved: " + JSON.stringify(shortcutArgsRun.commands));
      }
      const shortcutArgsResult = shortcutArgsRun.result.then((events) => {
        if (!Array.isArray(events) || events.length !== 1 || events[0].exitCode !== 0) {
          throw new Error("invalid npm shortcut suffix result events: " + JSON.stringify(events));
        }
      });
      const wildcardRun = concurrently(["npm:api-wild-*"], {
        raw: true,
        outputStream: shortcutOutputSink,
      });
      if (wildcardRun.commands.length !== 2) {
        throw new Error("npm wildcard shortcut did not expand commands: " + JSON.stringify(wildcardRun.commands));
      }
      if (JSON.stringify(wildcardRun.commands.map((command) => command.name)) !== JSON.stringify(["a", "b"])) {
        throw new Error("npm wildcard shortcut names did not use captures: " + JSON.stringify(wildcardRun.commands));
      }
      const wildcardResult = wildcardRun.result.then((events) => {
        if (!Array.isArray(events) || events.length !== 2 || events.some((event) => event.exitCode !== 0)) {
          throw new Error("invalid npm wildcard result events: " + JSON.stringify(events));
        }
      });
      const wildcardOmission = concurrently(["npm:api-wild-*(!b)"], {
        raw: true,
        outputStream: shortcutOutputSink,
      });
      if (
        wildcardOmission.commands.length !== 1 ||
        wildcardOmission.commands[0]?.name !== "a"
      ) {
        throw new Error("npm wildcard omission did not filter commands: " + JSON.stringify(wildcardOmission.commands));
      }
      const wildcardOmissionResult = wildcardOmission.result.then((events) => {
        if (!Array.isArray(events) || events.length !== 1 || events[0].exitCode !== 0) {
          throw new Error("invalid npm wildcard omission result events: " + JSON.stringify(events));
        }
      });
      const wildcardRegexOmission = concurrently(["cd . && npm run rx-*(![ab])"], {
        raw: true,
        outputStream: shortcutOutputSink,
      });
      if (
        wildcardRegexOmission.commands.length !== 1 ||
        wildcardRegexOmission.commands[0]?.name !== "c" ||
        wildcardRegexOmission.commands[0]?.command !== "cd . && npm run rx-c"
      ) {
        throw new Error("embedded npm wildcard regex omission did not preserve shell prefix: " + JSON.stringify(wildcardRegexOmission.commands));
      }
      const wildcardRegexOmissionResult = wildcardRegexOmission.result.then((events) => {
        if (!Array.isArray(events) || events.length !== 1 || events[0].exitCode !== 0) {
          throw new Error("invalid embedded npm wildcard regex omission result events: " + JSON.stringify(events));
        }
      });
      const fakeBin = join(process.cwd(), "fake-bin");
      mkdirSync(fakeBin, { recursive: true });
      const fakeDenoPath = join(fakeBin, process.platform === "win32" ? "deno.cmd" : "deno");
      writeFileSync(
        fakeDenoPath,
        process.platform === "win32"
          ? "@echo off\\r\\nexit /b 0\\r\\n"
          : "#!/bin/sh\\nexit 0\\n"
      );
      if (process.platform !== "win32") {
        chmodSync(fakeDenoPath, 0o700);
      }
      const denoPackageFallback = concurrently(["deno task deno-pkg-*"], {
        raw: true,
        outputStream: shortcutOutputSink,
        env: { PATH: fakeBin + delimiter + (process.env.PATH || "") },
      });
      if (
        denoPackageFallback.commands.length !== 2 ||
        JSON.stringify(denoPackageFallback.commands.map((command) => command.name)) !== JSON.stringify(["a", "b"])
      ) {
        throw new Error("deno wildcard did not include package scripts: " + JSON.stringify(denoPackageFallback.commands));
      }
      const denoPackageFallbackResult = denoPackageFallback.result.then((events) => {
        if (!Array.isArray(events) || events.length !== 2 || events.some((event) => event.exitCode !== 0)) {
          throw new Error("invalid deno package fallback result events: " + JSON.stringify(events));
        }
      });
      const quotedWildcard = concurrently(["npm run space-* && node --version"], {
        raw: true,
        outputStream: shortcutOutputSink,
      });
      if (
        quotedWildcard.commands.length !== 1 ||
        quotedWildcard.commands[0]?.name !== "a b" ||
        !quotedWildcard.commands[0]?.command.includes("&& node --version")
      ) {
        throw new Error("wildcard suffix was not preserved: " + JSON.stringify(quotedWildcard.commands));
      }
      const quotedScript =
        process.platform === "win32" ? '"space-a b"' : "'space-a b'";
      if (!quotedWildcard.commands[0]?.command.includes(quotedScript)) {
        throw new Error("wildcard script name was not shell quoted: " + JSON.stringify(quotedWildcard.commands));
      }
      const quotedWildcardResult = quotedWildcard.result.then((events) => {
        if (!Array.isArray(events) || events.length !== 1 || events[0].exitCode !== 0) {
          throw new Error("invalid quoted wildcard result events: " + JSON.stringify(events));
        }
      });
      const npmRunWildcard = concurrently(["npm run api-wild-*"], {
        raw: true,
        outputStream: shortcutOutputSink,
      });
      if (npmRunWildcard.commands.length !== 2) {
        throw new Error("npm run wildcard command did not expand commands: " + JSON.stringify(npmRunWildcard.commands));
      }
      const npmRunWildcardResult = npmRunWildcard.result.then((events) => {
        if (!Array.isArray(events) || events.length !== 2 || events.some((event) => event.exitCode !== 0)) {
          throw new Error("invalid npm run wildcard result events: " + JSON.stringify(events));
        }
      });
      const emptyWildcard = concurrently(["npm:no-match-*"], {
        raw: true,
        outputStream: shortcutOutputSink,
      });
      if (emptyWildcard.commands.length !== 0) {
        throw new Error("empty npm wildcard shortcut was not empty: " + JSON.stringify(emptyWildcard.commands));
      }
      const emptyWildcardResult = emptyWildcard.result.then((events) => {
        if (!Array.isArray(events) || events.length !== 0) {
          throw new Error("invalid empty npm wildcard result events: " + JSON.stringify(events));
        }
      });
      const emptyRun = concurrently([]);
      if (!Array.isArray(emptyRun.commands) || emptyRun.commands.length !== 0) {
        throw new Error("empty API run returned commands: " + JSON.stringify(emptyRun.commands));
      }
      const emptyRunResult = emptyRun.result.then((events) => {
        if (!Array.isArray(events) || events.length !== 0) {
          throw new Error("invalid empty API run events: " + JSON.stringify(events));
        }
      });
      const emptyTeardownPath = join(process.cwd(), "empty-teardown.txt");
      const emptyTeardownRun = concurrently(["npm:no-match-*"], {
        raw: true,
        teardown: [
          "node -e " + JSON.stringify("require('node:fs').writeFileSync('empty-teardown.txt','ok')"),
        ],
        outputStream: shortcutOutputSink,
      });
      const emptyTeardownResult = emptyTeardownRun.result.then((events) => {
        if (!Array.isArray(events) || events.length !== 0) {
          throw new Error("invalid empty teardown result events: " + JSON.stringify(events));
        }
        if (!existsSync(emptyTeardownPath)) {
          throw new Error("empty wildcard teardown did not run");
        }
      });
      const eventTempDirs = () => readdirSync(tmpdir()).filter((name) => name.startsWith("concurrently-ml-api-")).sort();
      const unsupportedDirsBefore = eventTempDirs();
      for (const [label, commands] of [
        ["partial env", [{ command: 'node -e "process.exit(0)"', env: { FOO: "1" } }, 'node -e "process.exit(0)"']],
        ["partial cwd", [{ command: 'node -e "process.exit(0)"', cwd: process.cwd() }, 'node -e "process.exit(0)"']],
        ["mixed raw", [{ command: 'node -e "process.exit(0)"', raw: true }, 'node -e "process.exit(0)"']],
      ]) {
        try {
          concurrently(commands);
          throw new Error(label + " did not fail");
        } catch (error) {
          if (!String(error && error.message).includes("not supported")) {
            throw error;
          }
        }
      }
      const unsupportedDirsAfter = eventTempDirs();
      if (JSON.stringify(unsupportedDirsAfter) !== JSON.stringify(unsupportedDirsBefore)) {
        throw new Error("unsupported API validation leaked event temp dirs");
      }
      const undefinedHookOptions = concurrently(['node -e "process.exit(0)"'], {
        raw: true,
        outputStream: shortcutOutputSink,
        controllers: undefined,
        logger: undefined,
        spawn: undefined,
        kill: undefined,
      });
      const undefinedHookOptionsResult = undefinedHookOptions.result.then((events) => {
        if (!Array.isArray(events) || events.length !== 1 || events[0].exitCode !== 0) {
          throw new Error("undefined unsupported hook options changed API execution: " + JSON.stringify(events));
        }
      });
      const mixed = concurrently([
        'node -e "process.exit(0)"',
        'node -e "process.exit(2)"',
      ], { raw: true });
      const mixedResult = mixed.result.then((events) => {
        throw new Error("mixed command result unexpectedly resolved: " + JSON.stringify(events));
      }, (events) => {
        const exitCodes = new Map(events.map((event) => [event.index, event.exitCode]));
        if (exitCodes.get(0) !== 0 || exitCodes.get(1) !== 2) {
          throw new Error("invalid mixed exit codes: " + JSON.stringify(events));
        }
      });
      const sanitizedEnv = { ...process.env, PATH: "", Path: "" };
      const sanitized = concurrently(["exit 0"], { raw: true, env: sanitizedEnv });
      const sanitizedResult = sanitized.result.then((events) => {
        if (!Array.isArray(events) || events.length !== 1 || events[0].exitCode !== 0) {
          throw new Error("invalid sanitized env result events");
        }
      });
      const envRun = concurrently(['node -e "if (process.env.FOO !== \\'1\\') process.exit(4)"'], {
        raw: true,
        env: { FOO: "1" },
      });
      const envResult = envRun.result.then((events) => {
        if (!Array.isArray(events) || events.length !== 1 || events[0].exitCode !== 0) {
          throw new Error("invalid options.env result events");
        }
      });
      const equalCommandEnvOrder = concurrently([
        {
          command: 'node -e "if (process.env.A !== \\'1\\' || process.env.B !== \\'2\\') process.exit(4)"',
          env: { A: "1", B: "2" },
        },
        {
          command: 'node -e "if (process.env.A !== \\'1\\' || process.env.B !== \\'2\\') process.exit(4)"',
          env: { B: "2", A: "1" },
        },
      ], { raw: true });
      const equalCommandEnvOrderResult = equalCommandEnvOrder.result.then((events) => {
        if (!Array.isArray(events) || events.some((event) => event.exitCode !== 0)) {
          throw new Error("invalid equivalent command env result events");
        }
      });
      const optionEnvIsolation = concurrently([
        'node -e "process.exit(0)"',
        'node -e "setTimeout(()=>process.exit(1),200)"',
      ], {
        raw: true,
        env: { CONCURRENTLY_SUCCESS: "first" },
      });
      const optionEnvIsolationResult = optionEnvIsolation.result.then((events) => {
        throw new Error("options.env CONCURRENTLY_SUCCESS changed native success semantics: " + JSON.stringify(events));
      }, (events) => {
        const exitCodes = new Map(events.map((event) => [event.index, event.exitCode]));
        if (exitCodes.get(0) !== 0 || exitCodes.get(1) !== 1) {
          throw new Error("invalid options.env isolation exit codes: " + JSON.stringify(events));
        }
      });
      let nodeOptionsOutput = "";
      const nodeOptionsStream = new Writable({
        write(chunk, _encoding, callback) {
          nodeOptionsOutput += chunk.toString();
          callback();
        },
      });
      const nodeOptionsRun = concurrently(["echo node-options-ok"], {
        env: { NODE_OPTIONS: "--bad-option" },
        outputStream: nodeOptionsStream,
        raw: true,
      });
      const nodeOptionsResult = nodeOptionsRun.result.then(() => {
        if (!nodeOptionsOutput.includes("node-options-ok")) {
          throw new Error("options.env.NODE_OPTIONS leaked into API wrapper: " + nodeOptionsOutput);
        }
      });
      const previousSuccessEnv = process.env.CONCURRENTLY_SUCCESS;
      process.env.CONCURRENTLY_SUCCESS = "first";
      const inheritedEnvIsolation = concurrently([
        'node -e "process.exit(0)"',
        'node -e "setTimeout(()=>process.exit(1),200)"',
      ], { raw: true });
      if (previousSuccessEnv === undefined) {
        delete process.env.CONCURRENTLY_SUCCESS;
      } else {
        process.env.CONCURRENTLY_SUCCESS = previousSuccessEnv;
      }
      const inheritedEnvIsolationResult = inheritedEnvIsolation.result.then((events) => {
        throw new Error("process.env CONCURRENTLY_SUCCESS changed native success semantics: " + JSON.stringify(events));
      }, (events) => {
        const exitCodes = new Map(events.map((event) => [event.index, event.exitCode]));
        if (exitCodes.get(0) !== 0 || exitCodes.get(1) !== 1) {
          throw new Error("invalid process.env isolation exit codes: " + JSON.stringify(events));
        }
      });
      let additionalOutput = "";
      const additionalStream = new Writable({
        write(chunk, _encoding, callback) {
          additionalOutput += chunk.toString();
          callback();
        },
      });
      const additionalCommand =
        "node -e " +
        JSON.stringify("console.log(process.argv.slice(1).join('|'))") +
        " -- {1} {@} {*} \\\\{1} {9}";
      const additionalRun = concurrently([additionalCommand], {
        raw: true,
        additionalArguments: ["one", "two words", "quote's"],
        outputStream: additionalStream,
      });
      const additionalResult = additionalRun.result.then(() => {
        const expected = "one|one|two words|quote's|one two words quote's|{1}";
        if (additionalOutput.trim() !== expected) {
          throw new Error("invalid additionalArguments output: " + JSON.stringify(additionalOutput));
        }
      });
      const pauseInput = new PassThrough();
      pauseInput.resume();
      const pauseRun = concurrently(['node -e "setTimeout(()=>process.exit(0),50)"'], {
        raw: true,
        inputStream: pauseInput,
        pauseInputStreamOnFinish: true,
      });
      const pauseResult = pauseRun.result.then(() => {
        if (!pauseInput.isPaused()) {
          throw new Error("pauseInputStreamOnFinish did not pause the input stream");
        }
      });
      let delayedOutput = "";
      const delayedStream = new Writable({
        write(chunk, _encoding, callback) {
          setTimeout(() => {
            delayedOutput += chunk.toString();
            callback();
          }, 50);
        },
      });
      const delayedOutputRun = concurrently(['node -e "process.stdout.write(\\'delayed\\')"'], {
        raw: true,
        outputStream: delayedStream,
      });
      const delayedOutputResult = delayedOutputRun.result.then(() => {
        if (!delayedOutput.includes("delayed")) {
          throw new Error("result resolved before outputStream flushed");
        }
      });
      let closeDrainBytes = 0;
      const closeDrainStream = new Writable({
        write(chunk, _encoding, callback) {
          closeDrainBytes += chunk.length;
          callback();
        },
      });
      const closeDrainSize = 128 * 1024;
      const closeDrainRun = concurrently([
        "node -e " + JSON.stringify("process.stdout.write('x'.repeat(" + closeDrainSize + "))"),
      ], {
        raw: true,
        outputStream: closeDrainStream,
      });
      const closeDrainResult = closeDrainRun.result.then(() => {
        if (closeDrainBytes !== closeDrainSize) {
          throw new Error("result settled before stdio close: expected " + closeDrainSize + ", got " + closeDrainBytes);
        }
      });
      const timingRun = concurrently([
        'node -e "process.exit(0)"',
        'node -e "setTimeout(()=>process.exit(0),400)"',
      ], {
        raw: true,
        outputStream: new Writable({ write(_chunk, _encoding, callback) { callback(); } }),
      });
      const timingResult = timingRun.result.then((events) => {
        const fast = events.find((event) => event.index === 0);
        const slow = events.find((event) => event.index === 1);
        if (!fast || !slow) {
          throw new Error("missing per-command timing events");
        }
        const fastEndMs = new Date(fast.timings.endDate).getTime();
        const slowEndMs = new Date(slow.timings.endDate).getTime();
        if (
          !Number.isFinite(fastEndMs) ||
          !Number.isFinite(slowEndMs) ||
          fastEndMs === slowEndMs
        ) {
          throw new Error("per-command timings collapsed to run duration: " + JSON.stringify(events));
        }
      });
      const closeOrderFile = join(mkdtempSync(join(tmpdir(), "concurrently-ml-close-order-")), "ready");
      const closeOrderRun = concurrently([
        "node -e " + JSON.stringify("const fs=require('node:fs'); const file=process.env.CLOSE_ORDER_FILE; const deadline=Date.now()+5000; (function wait(){ if(fs.existsSync(file)) setTimeout(()=>process.exit(0),300); else if(Date.now()>deadline) process.exit(2); else setTimeout(wait,20); })();"),
        "node -e " + JSON.stringify("require('node:fs').writeFileSync(process.env.CLOSE_ORDER_FILE,'ready')"),
      ], {
        env: { CLOSE_ORDER_FILE: closeOrderFile },
        raw: true,
        outputStream: new Writable({ write(_chunk, _encoding, callback) { callback(); } }),
      });
      const closeOrderResult = closeOrderRun.result.then((events) => {
        const indexes = events.map((event) => event.index);
        if (JSON.stringify(indexes) !== JSON.stringify([1, 0])) {
          throw new Error("close events were not completion ordered: " + JSON.stringify(events));
        }
      });
      let commaNameOutput = "";
      const commaNameStream = new Writable({
        write(chunk, _encoding, callback) {
          commaNameOutput += chunk.toString();
          callback();
        },
      });
      const commaNameRun = concurrently([
        { name: "api,dev", command: 'node -e "process.exit(0)"' },
      ], {
        outputStream: commaNameStream,
        successCondition: "command-api,dev",
      });
      const commaNameResult = commaNameRun.result.then((events) => {
        if (events[0]?.command.name !== "api,dev") {
          throw new Error("comma command name was corrupted: " + JSON.stringify(events));
        }
        if (!commaNameOutput.includes("[api,dev]")) {
          throw new Error("comma command name prefix was corrupted: " + commaNameOutput);
        }
      });
      let commaHiddenOutput = "";
      const commaHiddenStream = new Writable({
        write(chunk, _encoding, callback) {
          commaHiddenOutput += chunk.toString();
          callback();
        },
      });
      const commaHiddenRun = concurrently([
        { name: "hide,me", command: 'node -e "console.log(\\'hidden\\')"', hidden: true },
        { name: "also,hide", command: 'node -e "console.log(\\'also-hidden\\')"' },
      ], {
        outputStream: commaHiddenStream,
        hide: ["also,hide"],
      });
      const commaHiddenResult = commaHiddenRun.result.then((events) => {
        if (events.length !== 2) {
          throw new Error("hidden comma-name commands did not finish");
        }
        const hiddenEvent = events.find((event) => event.command.name === "hide,me");
        if (!hiddenEvent?.command.hidden) {
          throw new Error("hidden command info did not preserve hidden flag: " + JSON.stringify(events));
        }
        if (commaHiddenOutput.includes("hidden")) {
          throw new Error("hidden comma-name command leaked output: " + commaHiddenOutput);
        }
      });
      let duplicateHideOutput = "";
      const duplicateHideStream = new Writable({
        write(chunk, _encoding, callback) {
          duplicateHideOutput += chunk.toString();
          callback();
        },
      });
      const duplicateHideRun = concurrently([
        { name: "same", command: 'node -e "console.log(\\'one\\')"' },
        { name: "same", command: 'node -e "console.log(\\'two\\')"' },
      ], {
        outputStream: duplicateHideStream,
        hide: ["same"],
      });
      const duplicateHideResult = duplicateHideRun.result.then((events) => {
        if (events.length !== 2) {
          throw new Error("duplicate-name hidden commands did not finish");
        }
        if (duplicateHideOutput.includes("one") || duplicateHideOutput.includes("two")) {
          throw new Error("duplicate-name hide leaked output: " + duplicateHideOutput);
        }
      });
      let numericHideOutput = "";
      const numericHideStream = new Writable({
        write(chunk, _encoding, callback) {
          numericHideOutput += chunk.toString();
          callback();
        },
      });
      const numericHideRun = concurrently([
        { name: "1", command: 'node -e "console.log(\\'name-one\\')"' },
        { name: "two", command: 'node -e "console.log(\\'index-one\\')"' },
      ], {
        outputStream: numericHideStream,
        hide: [1],
      });
      const numericHideResult = numericHideRun.result.then((events) => {
        if (events.length !== 2) {
          throw new Error("numeric hide commands did not finish");
        }
        if (!numericHideOutput.includes("name-one") || numericHideOutput.includes("index-one")) {
          throw new Error("numeric hide did not select by index: " + numericHideOutput);
        }
      });
      const displayCommand = 'node -e "console.log(\\'display-ok\\')"';
      let displayOutput = "";
      const displayStream = new Writable({
        write(chunk, _encoding, callback) {
          displayOutput += chunk.toString();
          callback();
        },
      });
      const displayRun = concurrently([displayCommand], { outputStream: displayStream });
      const displayResult = displayRun.result.then(() => {
        if (!displayOutput.includes("display-ok")) {
          throw new Error("display output missed command stdout");
        }
        if (!displayOutput.includes(displayCommand + " exited with code 0")) {
          throw new Error("display output missed original command close message");
        }
        if (displayOutput.includes("Buffer.from") || displayOutput.includes("concurrently-ml-api-")) {
          throw new Error("display output leaked API wrapper command");
        }
        if (/\x1b\[[0-9;]*m/.test(displayOutput)) {
          throw new Error("captured API output unexpectedly included ANSI colors");
        }
      });
      let unnamedNameOutput = "";
      const unnamedNameStream = new Writable({
        write(chunk, _encoding, callback) {
          unnamedNameOutput += chunk.toString();
          callback();
        },
      });
      const unnamedNameRun = concurrently(['node -e "console.log(\\'unnamed\\')"'], {
        outputStream: unnamedNameStream,
        prefix: "name",
        prefixColors: false,
      });
      const unnamedNameResult = unnamedNameRun.result.then(() => {
        if (!unnamedNameOutput.includes("[0] unnamed")) {
          throw new Error("unnamed command did not keep index prefix: " + unnamedNameOutput);
        }
        if (unnamedNameOutput.includes("[]")) {
          throw new Error("unnamed command emitted empty name prefix: " + unnamedNameOutput);
        }
      });
      let dashPrefixOutput = "";
      const dashPrefixStream = new Writable({
        write(chunk, _encoding, callback) {
          dashPrefixOutput += chunk.toString();
          callback();
        },
      });
      const dashPrefixRun = concurrently(['node -e "console.log(\\'dash-prefix\\')"'], {
        outputStream: dashPrefixStream,
        env: { FORCE_COLOR: "1" },
        prefix: "-v",
        prefixColors: false,
      });
      const dashPrefixResult = dashPrefixRun.result.then(() => {
        if (dashPrefixOutput.trim() === "0.0.14") {
          throw new Error("API prefix option was parsed as CLI version");
        }
        if (!dashPrefixOutput.includes("-v dash-prefix")) {
          throw new Error("dash-prefixed API prefix was not preserved: " + dashPrefixOutput);
        }
        if (/\x1b\[[0-9;]*m/.test(dashPrefixOutput)) {
          throw new Error("prefixColors false did not override FORCE_COLOR: " + dashPrefixOutput);
        }
      });
      const forceColorPreserveRun = concurrently([
        'node -e "process.exit(process.env.FORCE_COLOR === \\'1\\' ? 0 : 7)"',
      ], {
        env: { FORCE_COLOR: "1" },
        prefixColors: false,
        raw: true,
      });
      const forceColorPreserveResult = forceColorPreserveRun.result;
      const explicitFalseRawStream = new Writable({
        write(_chunk, _encoding, callback) {
          callback();
        },
      });
      const explicitFalseRawRun = concurrently([
        { command: 'node -e "console.log(\\'raw-false-object\\')"', raw: false },
        'node -e "console.log(\\'raw-false-string\\')"',
      ], { outputStream: explicitFalseRawStream });
      const explicitFalseRawResult = explicitFalseRawRun.result.then((events) => {
        if (events.length !== 2) {
          throw new Error("explicit raw:false command did not finish with sibling");
        }
      });
      let prefixColorOutput = "";
      const prefixColorStream = new Writable({
        write(chunk, _encoding, callback) {
          prefixColorOutput += chunk.toString();
          callback();
        },
      });
      const previousForceColor = process.env.FORCE_COLOR;
      process.env.FORCE_COLOR = "1";
      const prefixColorRun = concurrently([
        { command: 'node -e "console.log(\\'first\\')"' },
        { command: 'node -e "console.log(\\'second\\')"', prefixColor: "red" },
      ], {
        outputStream: prefixColorStream,
        prefix: "index",
      });
      if (previousForceColor === undefined) {
        delete process.env.FORCE_COLOR;
      } else {
        process.env.FORCE_COLOR = previousForceColor;
      }
      const prefixColorResult = prefixColorRun.result.then(() => {
        if (prefixColorOutput.includes("\\x1b[31m[0]")) {
          throw new Error("partial command prefixColor shifted red onto command 0");
        }
        if (!prefixColorOutput.includes("\\x1b[31m[1]")) {
          throw new Error("partial command prefixColor did not color command 1 red");
        }
      });
      const signalDir = mkdtempSync(join(tmpdir(), "concurrently-ml-api-signal-"));
      const signalPath = join(signalDir, "sigterm.txt");
      const signalReadyPath = join(signalDir, "ready.txt");
      const signalCommand = "node -e " + JSON.stringify(
        "const fs=require('node:fs'); process.on('SIGTERM',()=>{fs.writeFileSync(process.env.SIGNAL_PATH,'ok');process.exit(0)}); fs.writeFileSync(process.env.SIGNAL_READY_PATH,'ok'); setInterval(()=>{},1000)"
      );
      const signalWaitCommand = "node -e " + JSON.stringify(
        "const fs=require('node:fs'); const deadline=Date.now()+5000; (function wait(){ if(fs.existsSync(process.env.SIGNAL_READY_PATH)) process.exit(0); if(Date.now()>deadline) process.exit(2); setTimeout(wait,20); })();"
      );
      const nativePolicyKill = concurrently([
        signalCommand,
        signalWaitCommand,
      ], {
        raw: true,
        env: { SIGNAL_PATH: signalPath, SIGNAL_READY_PATH: signalReadyPath },
        killOthers: ["success", "failure"],
        successCondition: "first",
      });
      const assertNativePolicyKillEvents = (events) => {
        if (!events.some((event) => event.killed)) {
          throw new Error("native kill policy did not report any killed command");
        }
        if (!existsSync(signalPath)) {
          throw new Error("native kill policy did not forward SIGTERM to wrapped command");
        }
      };
      const nativePolicyKillResult = nativePolicyKill.result.then(
        assertNativePolicyKillEvents
      );
      const successOnlyReady = join(
        mkdtempSync(join(tmpdir(), "concurrently-ml-success-kill-")),
        "ready"
      );
      const successOnlyHangSource =
        "require('node:fs').writeFileSync(process.env.SUCCESS_ONLY_READY,'ready'); setInterval(()=>{},1000)";
      const successOnlyWaitSource =
        "const fs=require('node:fs'); const deadline=Date.now()+5000; (function wait(){ if(fs.existsSync(process.env.SUCCESS_ONLY_READY)) process.exit(0); if(Date.now()>deadline) process.exit(2); setTimeout(wait,20); })();";
      const successOnlyKill = concurrently([
        "node -e " + JSON.stringify(successOnlyHangSource),
        "node -e " + JSON.stringify(successOnlyWaitSource),
      ], {
        raw: true,
        env: { SUCCESS_ONLY_READY: successOnlyReady },
        killOthersOn: ["success"],
        successCondition: "first",
      });
      const assertSuccessOnlyKillEvents = (events) => {
        if (!events.some((event) => event.killed)) {
          throw new Error("success-only kill policy did not report any killed command");
        }
      };
      const successOnlyKillResult = successOnlyKill.result.then(
        assertSuccessOnlyKillEvents
      );
      const queuedKill = concurrently([
        'node -e "process.exit(0)"',
        'node -e "console.log(1)"',
        'node -e "console.log(2)"',
      ], {
        raw: true,
        maxProcesses: 1,
        killOthersOn: ["success"],
        successCondition: "first",
      });
      const queuedKillResult = queuedKill.result.then((events) => {
        if (events.length !== 1 || events[0].index !== 0 || events[0].exitCode !== 0) {
          throw new Error("queued kill result should include only spawned commands: " + JSON.stringify(events));
        }
      });
      const killed = concurrently(['node -e "setTimeout(()=>{},10000)"'], { raw: true });
      try {
        killed.commands[0].kill("SIGKILL");
        throw new Error("SIGKILL Command.kill did not fail");
      } catch (error) {
        if (!String(error && error.message).includes("not supported")) {
          throw error;
        }
      }
      try {
        killed.commands[0].kill(9);
        throw new Error("numeric SIGKILL Command.kill did not fail");
      } catch (error) {
        if (!String(error && error.message).includes("not supported")) {
          throw error;
        }
      }
      setTimeout(() => killed.commands[0].kill("SIGTERM"), 100);
      const killedResult = killed.result.then((events) => {
        throw new Error("killed command result unexpectedly resolved: " + JSON.stringify(events));
      }, (events) => {
        if (
          !Array.isArray(events) ||
          events.length !== 1 ||
          !events[0].killed ||
          events[0].exitCode !== "SIGTERM"
        ) {
          throw new Error("invalid killed command result events");
        }
      });
      const multiKill = concurrently([
        'node -e "setTimeout(()=>{},100)"',
        'node -e "setTimeout(()=>{},100)"',
      ], { raw: true });
      if (multiKill.commands.some((command) => command.pid !== undefined || command.stdin !== undefined)) {
        throw new Error("multi-command API exposed native runner process metadata");
      }
      if (concurrently.Command.canKill(multiKill.commands[0])) {
        throw new Error("multi-command Command.canKill unexpectedly returned true");
      }
      try {
        multiKill.commands[0].kill("SIGTERM");
        throw new Error("multi-command kill did not fail");
      } catch (error) {
        if (!String(error && error.message).includes("not supported")) {
          throw error;
        }
      }
      const multiKillResult = multiKill.result.then((events) => {
        if (!Array.isArray(events) || events.length !== 2) {
          throw new Error("invalid multi-command kill result events");
        }
      });
      const run = concurrently(['node -e "process.exit(0)"'], { raw: true });
      if (!run || !Array.isArray(run.commands) || run.commands.length !== 1) {
        throw new Error("invalid concurrently result commands");
      }
      const runResult = run.result.then((events) => {
        if (!Array.isArray(events) || events.length !== 1 || events[0].exitCode !== 0) {
          throw new Error("invalid concurrently result events");
        }
      });
      Promise.all([
        mixedResult,
        stringCommandResult,
        objectCommandResult,
        dashPrefixedCommandResult,
        shortcutResult,
        shortcutArgsResult,
        wildcardResult,
        wildcardOmissionResult,
        wildcardRegexOmissionResult,
        denoPackageFallbackResult,
        quotedWildcardResult,
        npmRunWildcardResult,
        emptyWildcardResult,
        emptyRunResult,
        emptyTeardownResult,
        undefinedHookOptionsResult,
        sanitizedResult,
        envResult,
        equalCommandEnvOrderResult,
        optionEnvIsolationResult,
        nodeOptionsResult,
        inheritedEnvIsolationResult,
        additionalResult,
        pauseResult,
        delayedOutputResult,
        closeDrainResult,
        timingResult,
        closeOrderResult,
        commaNameResult,
        commaHiddenResult,
        duplicateHideResult,
        numericHideResult,
        displayResult,
        unnamedNameResult,
        dashPrefixResult,
        forceColorPreserveResult,
        explicitFalseRawResult,
        prefixColorResult,
        nativePolicyKillResult,
        successOnlyKillResult,
        queuedKillResult,
        killedResult,
        multiKillResult,
        runResult,
      ]).then(() => {
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

  const helpSmoke = spawnFileSync(binPath, ["-h"], {
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

  const concurrentlyHelpSmoke = spawnFileSync(concurrentlyBinPath, ["--help"], {
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

function optional(key) {
  return args.get(key);
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

function assertNoUpstreamFallbackDependency(projectDir, packageDir) {
  const packageJson = readJson(join(packageDir, "package.json"));
  for (const field of ["dependencies", "optionalDependencies", "peerDependencies"]) {
    for (const [name, version] of Object.entries(packageJson[field] ?? {})) {
      if (name === "concurrently-js" || version === "npm:concurrently@9.2.1") {
        throw new Error(`${field}.${name} still routes to upstream concurrently`);
      }
    }
  }
  assertNoFile(join(projectDir, "node_modules", "concurrently-js"));
}

function assertExecutable(path) {
  if (process.platform === "win32") {
    return;
  }
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

function assertSmokeOutput(actual, label, command, context) {
  const expectedOutput = `[0] ${label}\n`;
  const expectedClose = `[0] ${command} exited with code 0\n`;
  const expected = expectedOutput + expectedClose;
  if (actual !== expected) {
    throw new Error(
      `${context}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`
    );
  }
}

function platformCommand(label) {
  if (process.platform === "win32") {
    return `node -e "console.log('${label}')"`;
  }
  return `printf ${label}`;
}

function assertArrayEqual(actual, expected, label) {
  assertEqual(JSON.stringify(actual), JSON.stringify(expected), label);
}

function assertLinuxLibc(platformPackage) {
  if (platform !== "linux") {
    if (libc) {
      throw new Error("--libc is only valid for linux smoke targets");
    }
    if (Object.prototype.hasOwnProperty.call(platformPackage, "libc")) {
      throw new Error("non-linux platform package must not declare libc");
    }
    return;
  }

  if (libc !== "gnu" && libc !== "musl") {
    throw new Error("linux smoke targets require --libc gnu or --libc musl");
  }
  assertEqual(hostLinuxLibc(), libc, "smoke host libc");
  assertArrayEqual(
    platformPackage.libc,
    [npmLibcSelector(libc)],
    "platform package libc"
  );
}

function hostLinuxLibc() {
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

function npmLibcSelector(libc) {
  return libc === "gnu" ? "glibc" : libc;
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
  writeFileSync(
    join(path, "package.json"),
    JSON.stringify({
      private: true,
      scripts: {
        "api-wild-a": "node -e \"process.exit(0)\"",
        "api-wild-b": "node -e \"process.exit(0)\"",
        "rx-a": "node -e \"process.exit(0)\"",
        "rx-b": "node -e \"process.exit(0)\"",
        "rx-c": "node -e \"process.exit(0)\"",
        "deno-pkg-a": "node -e \"process.exit(0)\"",
        "deno-pkg-b": "node -e \"process.exit(0)\"",
        "space-a b": "node -e \"process.exit(0)\"",
        "api-args": "node -e \"if (!process.argv.includes('--flag')) process.exit(5)\" --",
        "api-echo": "node -e \"process.exit(0)\"",
      },
    }) + "\n"
  );
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
  const result = spawnFileSync(npm, args, {
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

function spawnFileSync(command, args, options) {
  return spawnSync(command, args, {
    ...options,
    shell: windowsCommandScript(command),
  });
}

function windowsCommandScript(command) {
  return process.platform === "win32" && command.toLowerCase().endsWith(".cmd");
}
