#!/usr/bin/env node

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
const platformPackageName = `${rootPackage.name}-${target}`;
const platformPackageDir = resolve(
  "dist",
  "npm",
  platformPackageName.replace("/", "__")
);
const platformPackageJsonPath = join(platformPackageDir, "package.json");
const nativeBinaryPath = join(
  platformPackageDir,
  "bin",
  platform === "win32" ? "concurrently-ml.exe" : "concurrently-ml"
);

assertEqual(process.platform, platform, "smoke host platform");
assertEqual(process.arch, arch, "smoke host architecture");
assertFile(platformPackageJsonPath);
assertFile(nativeBinaryPath);

const platformPackage = readJson(platformPackageJsonPath);
assertEqual(platformPackage.name, platformPackageName, "platform package name");
assertEqual(platformPackage.version, rootPackage.version, "platform package version");
assertArrayEqual(platformPackage.os, [platform], "platform package os");
assertArrayEqual(platformPackage.cpu, [arch], "platform package cpu");
assertExecutable(nativeBinaryPath);

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
      "--offline",
      platformTarball,
      rootTarball,
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
    "@pierback",
    "concurrently-ml"
  );
  assertFile(binPath);
  assertFile(concurrentlyBinPath);
  assertFile(join(installedRootDir, "index.js"));
  assertFile(join(installedRootDir, "index.mjs"));
  assertFile(join(installedRootDir, "index.d.ts"));
  assertFile(join(installedRootDir, "index.d.mts"));
  assertFile(join(installedRootDir, "npm", "lib", "native.js"));
  assertNoPackedSourceTree(installedRootDir);

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

  nodeRun(
    [
      "-e",
      `
const { Writable } = require("node:stream");
const concurrently = require("@pierback/concurrently-ml");
let output = "";
let errorOutput = "";
const closeEvents = [];
const stdoutChunks = [];
const stderrChunks = [];
const timerEvents = [];
const states = [];
const outputStream = new Writable({
  write(chunk, _encoding, callback) {
    output += chunk.toString();
    callback();
  }
});
const errorStream = new Writable({
  write(chunk, _encoding, callback) {
    errorOutput += chunk.toString();
    callback();
  }
});
const command = "node -e " + JSON.stringify("setTimeout(()=>{process.stdout.write('api');process.stderr.write('err')},25)");
const run = concurrently([command], { raw: true, outputStream, errorStream });
const assertThrowsUnsupported = (fn) => {
  try {
    fn();
  } catch (error) {
    if (String(error && error.message).includes("not supported")) return;
    throw error;
  }
  throw new Error("expected unsupported command handle member to throw");
};
if (typeof concurrently.concurrently !== "function") throw new Error("missing named concurrently export");
if (typeof concurrently.createConcurrently !== "function") throw new Error("missing createConcurrently export");
if (typeof concurrently.createConcurrently({ raw: true }) !== "function") {
  throw new Error("createConcurrently did not return a runner");
}
if (!Array.isArray(run.commands) || run.commands.length !== 1) throw new Error("missing command handles");
run.commands[0].close.subscribe((event) => closeEvents.push(event));
run.commands[0].stdout.subscribe((chunk) => stdoutChunks.push(chunk.toString()));
run.commands[0].stderr.on("data", (chunk) => stderrChunks.push(chunk.toString()));
run.commands[0].timer.subscribe((event) => timerEvents.push(event));
run.commands[0].stateChange.subscribe((state) => states.push(state));
assertThrowsUnsupported(() => run.commands[0].kill());
run.result.then((events) => {
  if (output !== "api") throw new Error("unexpected require output: " + JSON.stringify(output));
  if (errorOutput !== "err") throw new Error("unexpected require error output: " + JSON.stringify(errorOutput));
  if (stdoutChunks.join("") !== "api") throw new Error("unexpected stdout observable output: " + JSON.stringify(stdoutChunks));
  if (stderrChunks.join("") !== "err") throw new Error("unexpected stderr observable output: " + JSON.stringify(stderrChunks));
  if (!states.includes("started") || states[states.length - 1] !== "exited") {
    throw new Error("unexpected state observable output: " + JSON.stringify(states));
  }
  if (timerEvents.length < 2 || !(timerEvents[0].startDate instanceof Date) || !(timerEvents[timerEvents.length - 1].endDate instanceof Date)) {
    throw new Error("unexpected timer observable output");
  }
  if (!Array.isArray(events) || events.length !== 1) throw new Error("unexpected require result events");
  if (events[0].exitCode !== 0) throw new Error("unexpected require exit code");
  if (closeEvents.length !== 1 || closeEvents[0] !== events[0]) {
    throw new Error("command close observable did not emit the native close event");
  }
  if (!run.commands[0].exited || run.commands[0].killed) {
    throw new Error("command handle final state was not updated");
  }
}).catch((error) => {
  throw new Error("require API rejected: " + JSON.stringify(error));
});
`,
    ],
    projectDir,
    "require API smoke"
  );

	  nodeRun(
	    [
	      "-e",
	      `
	const { Writable } = require("node:stream");
	const concurrently = require("@pierback/concurrently-ml");
	let output = "";
	const outputStream = new Writable({
	  write(chunk, _encoding, callback) {
	    output += chunk.toString();
	    callback();
	  }
	});
	const run = concurrently.createConcurrently({ raw: true })(["printf factory"], { outputStream });
	run.result.then((events) => {
	  if (output !== "factory") throw new Error("unexpected factory output: " + JSON.stringify(output));
	  if (!Array.isArray(events) || events[0].exitCode !== 0) {
	    throw new Error("unexpected factory close events: " + JSON.stringify(events));
	  }
	});
	`,
	    ],
	    projectDir,
	    "createConcurrently API smoke"
	  );

	  nodeRun(
	    [
	      "-e",
	      `
	const { Writable } = require("node:stream");
	const concurrently = require("@pierback/concurrently-ml");
	let output = "";
	const outputStream = new Writable({
	  write(chunk, _encoding, callback) {
	    output += chunk.toString();
	    callback();
	  }
	});
	concurrently(["printf color"], { prefixColors: ["red"], outputStream }).result.then(() => {
	  if (!output.includes("\\x1b[31m")) {
	    throw new Error("prefixColors was not forwarded to native output: " + JSON.stringify(output));
	  }
	});
	`,
	    ],
	    projectDir,
	    "prefixColors API smoke"
	  );

	  mkdirSync(join(projectDir, "sub"), { recursive: true });
  nodeRun(
    [
      "-e",
      `
const { Writable } = require("node:stream");
const concurrently = require("@pierback/concurrently-ml");
let output = "";
const outputStream = new Writable({
  write(chunk, _encoding, callback) {
    output += chunk.toString();
    callback();
  }
});
concurrently(["pwd"], { raw: true, cwd: "sub", outputStream }).result.then(() => {
  if (!output.trim().endsWith("/sub")) {
    throw new Error("relative cwd was not applied exactly once: " + JSON.stringify(output));
  }
});
`,
    ],
    projectDir,
	    "relative cwd API smoke"
	  );

	  mkdirSync(join(projectDir, "api-fields"), { recursive: true });
	  nodeRun(
	    [
	      "-e",
	      `
	const { Writable } = require("node:stream");
	const concurrently = require("@pierback/concurrently-ml");
	let output = "";
	const outputStream = new Writable({
	  write(chunk, _encoding, callback) {
	    output += chunk.toString();
	    callback();
	  }
	});
	concurrently([
	  {
	    command: "node -e \\"console.log(process.cwd().endsWith('/api-fields') + ':' + process.env.CONCURRENTLY_ML_FIELD)\\"",
	    cwd: "api-fields",
	    env: { CONCURRENTLY_ML_FIELD: "per-command-env" },
	    raw: true
	  }
	], { outputStream }).result.then((events) => {
	  if (output !== "true:per-command-env\\n") {
	    throw new Error("per-command cwd/env/raw fields were not applied: " + JSON.stringify(output));
	  }
	  if (!Array.isArray(events) || events[0].exitCode !== 0) {
	    throw new Error("unexpected per-command field close events: " + JSON.stringify(events));
	  }
	});
	`,
	    ],
	    projectDir,
	    "per-command cwd env raw API smoke"
	  );

  nodeRun(
    [
      "-e",
      `
const { Writable } = require("node:stream");
const concurrently = require("@pierback/concurrently-ml");
let output = "";
const outputStream = new Writable({
  write(chunk, _encoding, callback) {
    output += chunk.toString();
    callback();
  }
});
concurrently(["printf hidden-a", "printf hidden-b"], {
  hide: [0, 1],
  outputStream
}).result.then((events) => {
  if (output !== "") {
    throw new Error("hide array did not hide all command output: " + JSON.stringify(output));
  }
  if (!Array.isArray(events) || events.length !== 2) {
    throw new Error("unexpected hide array close events: " + JSON.stringify(events));
  }
});
`,
    ],
    projectDir,
    "hide array API smoke"
  );

  nodeRun(
    [
      "-e",
      `
const { Writable } = require("node:stream");
const concurrently = require("@pierback/concurrently-ml");
let output = "";
const outputStream = new Writable({
  write(chunk, _encoding, callback) {
    output += chunk.toString();
    callback();
  }
});
concurrently(["true", "printf queued"], {
  maxProcesses: 1,
  killOthersOn: ["success"],
  raw: true,
  outputStream
}).result.then((events) => {
  if (output !== "") {
    throw new Error("queued command unexpectedly produced output: " + JSON.stringify(output));
  }
  if (!Array.isArray(events) || events.length !== 1) {
    throw new Error("unexpected skipped queued close events: " + JSON.stringify(events));
  }
  if (events[0].command.command !== "true" || events[0].exitCode !== 0) {
    throw new Error("unexpected completed command event: " + JSON.stringify(events));
  }
});
`,
    ],
    projectDir,
    "skipped queued API close event smoke"
  );

  nodeRun(
    [
      "-e",
      `
const { Writable } = require("node:stream");
const concurrently = require("@pierback/concurrently-ml");
let stderr = "";
const outputStream = new Writable({
  write(_chunk, _encoding, callback) {
    callback();
  }
});
const errorStream = new Writable({
  write(chunk, _encoding, callback) {
    stderr += chunk.toString();
    callback();
  }
});
concurrently(["--version"], { raw: true, outputStream, errorStream }).result.then(() => {
  throw new Error("dash-leading command unexpectedly succeeded");
}).catch((events) => {
  if (!Array.isArray(events) || events.length !== 1) {
    throw new Error("unexpected dash-leading command close events: " + JSON.stringify(events));
  }
  if (events[0].command.command !== "--version" || events[0].exitCode !== 127) {
    throw new Error("dash-leading command was not treated as a command: " + JSON.stringify(events));
  }
  if (!stderr.includes("--version")) {
    throw new Error("dash-leading command stderr did not come from the shell: " + JSON.stringify(stderr));
  }
});
`,
    ],
    projectDir,
    "dash-leading command API smoke"
  );

  nodeRun(
    [
      "-e",
      `
const { Writable } = require("node:stream");
const concurrently = require("@pierback/concurrently-ml");
let stderr = "";
const outputStream = new Writable({
  write(_chunk, _encoding, callback) {
    callback();
  }
});
const errorStream = new Writable({
  write(chunk, _encoding, callback) {
    stderr += chunk.toString();
    callback();
  }
});
concurrently(["printf never"], {
  maxProcesses: 0,
  raw: true,
  outputStream,
  errorStream
}).result.then(() => {
  throw new Error("invalid native config unexpectedly succeeded");
}).catch((events) => {
  if (!Array.isArray(events) || events.length !== 1) {
    throw new Error("missing close-events file did not fall back to JS close events: " + JSON.stringify(events));
  }
  if (!stderr.includes("invalid max processes")) {
    throw new Error("unexpected invalid config stderr: " + JSON.stringify(stderr));
  }
});
`,
    ],
    projectDir,
    "missing native close-events fallback API smoke"
  );

  mkdirSync(join(projectDir, "global-cwd", "nested"), { recursive: true });
  nodeRun(
    [
      "-e",
      `
const { Writable } = require("node:stream");
const concurrently = require("@pierback/concurrently-ml");
let output = "";
const outputStream = new Writable({
  write(chunk, _encoding, callback) {
    output += chunk.toString();
    callback();
  }
});
concurrently([
  { command: "pwd", cwd: "nested", raw: true }
], { cwd: "global-cwd", outputStream }).result.then((events) => {
  if (!output.trim().endsWith("/global-cwd/nested")) {
    throw new Error("relative command cwd was not resolved under global cwd: " + JSON.stringify(output));
  }
  if (!Array.isArray(events) || events[0].exitCode !== 0) {
    throw new Error("unexpected global plus command cwd close events: " + JSON.stringify(events));
  }
});
`,
    ],
    projectDir,
    "global plus per-command relative cwd API smoke"
  );

  nodeRun(
    [
      "-e",
      `
const { Writable } = require("node:stream");
const concurrently = require("@pierback/concurrently-ml");
let output = "";
const outputStream = new Writable({
  write(chunk, _encoding, callback) {
    output += chunk.toString();
    callback();
  }
});
concurrently([
  { command: "printf comma", name: "api,worker" }
], { outputStream }).result.then((events) => {
  const plainOutput = output.replace(/\\x1b\\[[0-9;]*m/g, "");
  if (!plainOutput.includes("[api,worker] comma\\n")) {
    throw new Error("comma command name was not preserved in output: " + JSON.stringify(output));
  }
  if (!Array.isArray(events) || events[0].command.name !== "api,worker") {
    throw new Error("comma command name was not preserved in close events: " + JSON.stringify(events));
  }
});
`,
    ],
    projectDir,
    "comma command name API smoke"
  );

  mkdirSync(join(projectDir, "wild-api"), { recursive: true });
  writeFileSync(
    join(projectDir, "wild-api", "package.json"),
    JSON.stringify({
      private: true,
      scripts: {
        "wild-one":
          "node -e \"console.log(process.cwd().endsWith('/wild-api') + ':' + process.env.WILD_API_FIELD)\"",
      },
    }) + "\n"
  );
  nodeRun(
    [
      "-e",
      `
const { Writable } = require("node:stream");
const concurrently = require("@pierback/concurrently-ml");
let output = "";
const outputStream = new Writable({
  write(chunk, _encoding, callback) {
    output += chunk.toString();
    callback();
  }
});
concurrently([
  {
    command: "npm:wild-*",
    cwd: "wild-api",
    env: { WILD_API_FIELD: "per-command-wildcard" },
    raw: true
  }
], { outputStream }).result.then((events) => {
  if (!output.includes("true:per-command-wildcard\\n")) {
    throw new Error("per-command cwd was not used for wildcard expansion: " + JSON.stringify(output));
  }
  if (!Array.isArray(events) || events[0].exitCode !== 0) {
    throw new Error("unexpected wildcard field close events: " + JSON.stringify(events));
  }
});
`,
    ],
    projectDir,
    "per-command wildcard cwd API smoke"
  );

  nodeRun(
    [
      "-e",
      `
const { Writable } = require("node:stream");
const concurrently = require("@pierback/concurrently-ml");
let output = "";
const outputStream = new Writable({
  write(chunk, _encoding, callback) {
    output += chunk.toString();
    callback();
  }
});
concurrently(["npm:no-match-*"], { cwd: process.cwd(), outputStream }).result.then((events) => {
  if (output !== "") {
    throw new Error("unexpected no-op API output: " + JSON.stringify(output));
  }
  if (!Array.isArray(events) || events.length !== 0) {
    throw new Error("unexpected no-op API close events: " + JSON.stringify(events));
  }
});
`,
    ],
    projectDir,
    "no-op wildcard API smoke"
  );

	  nodeRun(
	    [
	      "-e",
	      `
	const { Writable } = require("node:stream");
	const concurrently = require("@pierback/concurrently-ml");
	let output = "";
	const outputStream = new Writable({
	  write(chunk, _encoding, callback) {
	    output += chunk.toString();
	    callback();
	  }
	});
	concurrently(["cat"], { raw: true, handleInput: true, outputStream }).result.then((events) => {
	  if (output !== "api stdin\\n") {
	    throw new Error("handleInput did not read process.stdin: " + JSON.stringify(output));
	  }
	  if (!Array.isArray(events) || events[0].exitCode !== 0) {
	    throw new Error("unexpected handleInput close events: " + JSON.stringify(events));
	  }
	});
	`,
	    ],
	    projectDir,
	    "handleInput default stdin API smoke",
	    { input: "api stdin\n" }
	  );

	  nodeRun(
	    [
	      "-e",
      `
const { Writable } = require("node:stream");
const concurrently = require("@pierback/concurrently-ml");
const outputStream = new Writable({
	  write(_chunk, _encoding, callback) {
	    callback();
	  }
	});
	concurrently(["true", "false"], { raw: true, outputStream }).result.then(() => {
	  throw new Error("expected multi-command failure");
	}).catch((events) => {
  if (!Array.isArray(events) || events.length !== 2) {
    throw new Error("unexpected rejection payload: " + JSON.stringify(events));
  }
  if (events[0].exitCode !== 0 || events[1].exitCode !== 1) {
    throw new Error("unexpected per-command exit codes: " + JSON.stringify(events.map((event) => event.exitCode)));
  }
});
`,
    ],
    projectDir,
	    "raw multi-command API close event smoke"
	  );

  nodeRun(
    [
      "-e",
      `
const { Writable } = require("node:stream");
const concurrently = require("@pierback/concurrently-ml");
const outputStream = new Writable({
  write(_chunk, _encoding, callback) {
    callback();
  }
});
concurrently(["sleep 2", "sh -c \\"exit 1\\""], {
  killOthersOn: ["failure"],
  outputStream,
  errorStream: outputStream
}).result.then(() => {
  throw new Error("expected kill-on-fail rejection");
}).catch((events) => {
  if (!Array.isArray(events) || events.length !== 2) {
    throw new Error("unexpected kill-on-fail payload: " + JSON.stringify(events));
  }
  const sleepEvent = events.find((event) => event.command.command === "sleep 2");
  if (!sleepEvent || sleepEvent.killed !== true || sleepEvent.exitCode !== "SIGTERM") {
    throw new Error("unexpected killed command close event: " + JSON.stringify(events));
  }
});
`,
    ],
    projectDir,
    "kill-on-fail API signal label smoke"
  );

  nodeRun(
    [
      "--input-type=module",
      "-e",
      `
import concurrently, { concurrently as named } from "@pierback/concurrently-ml";
if (concurrently !== named) throw new Error("default and named ESM exports differ");
const run = concurrently(["printf esm"], { raw: true });
await run.result;
`,
    ],
    projectDir,
    "ESM API smoke"
  );

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

function assertExecutable(path) {
  const mode = statSync(path).mode;
  if ((mode & 0o111) === 0) {
    throw new Error(`expected executable file mode: ${path}`);
  }
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

function nodeRun(args, cwd, label, options = {}) {
  const result = spawnSync(process.execPath, args, {
    cwd,
    encoding: "utf8",
    input: options.input,
    stdio: ["pipe", "pipe", "pipe"],
  });
  if (result.error) {
    throw result.error;
  }
  if (result.status !== 0) {
    throw new Error(
      `${label} exited ${result.status}\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`
    );
  }
  return result;
}
