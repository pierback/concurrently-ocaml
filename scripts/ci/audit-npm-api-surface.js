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
const { isAbsolute, join, relative, resolve } = require("node:path");
const { spawnSync } = require("node:child_process");

const packageRoot = resolve(".");
const rootPackage = readJson(resolve("package.json"));
const publicPackageName = "concurrently";
const upstreamPackageName = "upstream-concurrently";
const upstreamVersion = "9.2.1";
const tempDir = mkdtempSync(join(tmpdir(), "concurrently-ml-api-surface-"));
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
      `${upstreamPackageName}@npm:concurrently@${upstreamVersion}`,
      "typescript@5.9.3",
      "@types/node@24",
    ],
    projectDir
  );

  const localPackageDir = join(projectDir, "node_modules", publicPackageName);
  const upstreamPackageDir = join(projectDir, "node_modules", upstreamPackageName);
  const localPackageJson = readJson(join(localPackageDir, "package.json"));
  const upstreamPackageJson = readJson(join(upstreamPackageDir, "package.json"));

  assertNoUpstreamRuntimeDependency(localPackageJson);
  assertBinSurface(localPackageJson.bin, upstreamPackageJson.bin, localPackageDir);
  assertExportsSurface(
    localPackageJson.exports,
    upstreamPackageJson.exports,
    localPackageDir,
    "exports"
  );

  assertRuntimeExports(projectDir, "commonjs");
  assertRuntimeExports(projectDir, "module");
  assertPrototypeSurface(projectDir);
  assertLoggerOutputRuntime(projectDir);
  assertTypescriptConsumer(projectDir);
  assertIpcRuntime(projectDir);

  console.log(`api surface audit ok: concurrently@${upstreamVersion}`);
} finally {
  rmSync(tempDir, { recursive: true, force: true });
}

function assertNoUpstreamRuntimeDependency(packageJson) {
  for (const field of ["dependencies", "optionalDependencies", "peerDependencies"]) {
    for (const [name, version] of Object.entries(packageJson[field] ?? {})) {
      if (name === "concurrently-js" || version === `npm:concurrently@${upstreamVersion}`) {
        throw new Error(`${field}.${name} still routes to upstream concurrently`);
      }
    }
  }
}

function assertRuntimeExports(projectDir, moduleKind) {
  const script =
    moduleKind === "commonjs"
      ? `
        const local = require(${JSON.stringify(publicPackageName)});
        const upstream = require(${JSON.stringify(upstreamPackageName)});
        assertSameRuntimeSurface(local, upstream);
      `
      : `
        const local = await import(${JSON.stringify(publicPackageName)});
        const upstream = await import(${JSON.stringify(upstreamPackageName)});
        assertSameRuntimeSurface(local, upstream);
      `;
  const result = spawnSync(
    process.execPath,
    [
      ...(moduleKind === "module" ? ["--input-type=module"] : []),
      "-e",
      `
      function exportedKeys(value) {
        return Reflect.ownKeys(value)
          .filter((key) => typeof key === "string")
          .sort();
      }
      function assertJsonEqual(actual, expected, label) {
        const actualJson = JSON.stringify(actual);
        const expectedJson = JSON.stringify(expected);
        if (actualJson !== expectedJson) {
          throw new Error(label + ": expected " + expectedJson + ", got " + actualJson);
        }
      }
      function assertSameRuntimeSurface(local, upstream) {
        if (typeof local.default !== typeof upstream.default) {
          throw new Error("default export type mismatch");
        }
        assertJsonEqual(exportedKeys(local), exportedKeys(upstream), "export keys");
      }
      ${script}
      `,
    ],
    { cwd: projectDir, encoding: "utf8" }
  );
  if (result.error) {
    throw result.error;
  }
  if (result.status !== 0) {
    throw new Error(
      `${moduleKind} export audit exited ${result.status}\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`
    );
  }
}

function assertPrototypeSurface(projectDir) {
  const result = spawnSync(
    process.execPath,
    [
      "-e",
      `
      const local = require(${JSON.stringify(publicPackageName)});
      const upstream = require(${JSON.stringify(upstreamPackageName)});
      function stringKeys(value) {
        return Reflect.ownKeys(value)
          .filter((key) => typeof key === "string")
          .sort();
      }
      function prototypeKeys(value) {
        return Object.getOwnPropertyNames(value.prototype ?? {}).sort();
      }
      function assertJsonEqual(actual, expected, label) {
        const actualJson = JSON.stringify(actual);
        const expectedJson = JSON.stringify(expected);
        if (actualJson !== expectedJson) {
          throw new Error(label + ": expected " + expectedJson + ", got " + actualJson);
        }
      }
      for (const key of stringKeys(upstream)) {
        const upstreamValue = upstream[key];
        const localValue = local[key];
        if (typeof upstreamValue !== "function") {
          continue;
        }
        if (typeof localValue !== "function") {
          throw new Error(key + ": expected function export");
        }
        if (localValue.length !== upstreamValue.length) {
          throw new Error(
            key + ": expected function length " + upstreamValue.length + ", got " + localValue.length
          );
        }
        assertJsonEqual(prototypeKeys(localValue), prototypeKeys(upstreamValue), key + " prototype keys");
        assertJsonEqual(
          Object.getOwnPropertyNames(localValue).sort(),
          Object.getOwnPropertyNames(upstreamValue).sort(),
          key + " static keys"
        );
      }
      `,
    ],
    { cwd: projectDir, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }
  );
  if (result.error) {
    throw result.error;
  }
  if (result.status !== 0) {
    throw new Error(
      `prototype surface audit exited ${result.status}\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`
    );
  }
}

function assertTypescriptConsumer(projectDir) {
  writeFileSync(
    join(projectDir, "types-cjs.cts"),
    `
import concurrently = require("concurrently");
import { spawn } from "node:child_process";

const logger = new concurrently.Logger({ raw: true });
const command = new concurrently.Command({ index: 0, name: "api", command: "echo api" });
command.cleanUp();
command.maybeSetupIPC({} as concurrently.ChildProcess);
logger.output.subscribe({
  next(event) {
    event.text.toUpperCase();
    event.command?.name.toUpperCase();
  },
});
logger.shortenText("abcdef");
logger.getPrefixesFor(command).command.toUpperCase();
logger.getPrefix(command).toUpperCase();
new concurrently.KillOthers({}).maybeForceKill([command]);
new concurrently.LogTimings({}).printExitInfoTimingTable([]);
const result = concurrently(["echo ok"], {
  logger,
  spawn(command, options) {
    return spawn(command, [], options);
  },
  kill(pid, signal) {
    process.kill(pid, signal);
  },
  hide: [0, "web"],
  controllers: [new concurrently.LogOutput({ logger })],
});

result.commands[0]?.close.subscribe({
  next(event) {
    event.timings.durationSeconds.toFixed();
  },
});
`
  );
  writeFileSync(
    join(projectDir, "types-esm.mts"),
    `
import concurrently, { Command, Logger, type ConcurrentlyOptions } from "concurrently";
import { spawn } from "node:child_process";

const options: Partial<ConcurrentlyOptions> = {
  logger: new Logger({}),
  spawn(command, spawnOptions) {
    return spawn(command, [], spawnOptions);
  },
};

const run = concurrently([{ command: "echo ok", ipc: 3 }], options);
if (Command.canKill(run.commands[0])) {
  run.commands[0].process.pid?.toFixed();
}

const controllerCommand = new Command({
  index: 0,
  name: "controller",
  command: "echo controller",
});
const controllerOptions: Partial<ConcurrentlyOptions> = {
  controllers: [
    {
      handle() {
        return { commands: [controllerCommand] };
      },
    },
  ],
};
concurrently(["echo original"], controllerOptions);
`
  );
  writeFileSync(
    join(projectDir, "tsconfig.json"),
    `${JSON.stringify(
      {
        compilerOptions: {
          target: "ES2022",
          module: "NodeNext",
          moduleResolution: "NodeNext",
          strict: true,
          noEmit: true,
          types: ["node"],
          skipLibCheck: false,
        },
        include: ["types-cjs.cts", "types-esm.mts"],
      },
      null,
      2
    )}\n`
  );

  const tsc = join(
    projectDir,
    "node_modules",
    ".bin",
    process.platform === "win32" ? "tsc.cmd" : "tsc"
  );
  const result = spawnFileSync(tsc, ["-p", "tsconfig.json"], {
    cwd: projectDir,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (result.error) {
    throw result.error;
  }
  if (result.status !== 0) {
    throw new Error(
      `TypeScript consumer audit exited ${result.status}\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`
    );
  }
}

function assertLoggerOutputRuntime(projectDir) {
  const result = spawnSync(
    process.execPath,
    [
      "-e",
      `
      const concurrently = require(${JSON.stringify(publicPackageName)});
      const { Writable } = require("node:stream");
      const logger = new concurrently.Logger({
        raw: true,
        outputStream: new Writable({
          write(_chunk, _encoding, callback) {
            callback();
          },
        }),
      });
      const events = [];
      logger.output.subscribe({
        next(event) {
          events.push(event);
        },
      });
      logger.logCommandText("hello", { index: 0, name: "api", command: "echo api" });
      if (
        events.length !== 1 ||
        events[0].text !== "hello" ||
        events[0].command?.name !== "api"
      ) {
        throw new Error("Logger.output did not emit upstream-shaped events: " + JSON.stringify(events));
      }
      `,
    ],
    { cwd: projectDir, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }
  );
  if (result.error) {
    throw result.error;
  }
  if (result.status !== 0) {
    throw new Error(
      `Logger.output runtime audit exited ${result.status}\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`
    );
  }
}

function assertIpcRuntime(projectDir) {
  const upstreamDefault = inspectIpcRuntime(
    projectDir,
    upstreamPackageName,
    "default shell spawn"
  );
  const localDefault = inspectIpcRuntime(
    projectDir,
    publicPackageName,
    "default shell spawn"
  );
  if (localDefault.ok !== upstreamDefault.ok) {
    throw new Error(
      `default shell IPC parity mismatch on ${process.platform}\nlocal:\n${formatIpcResult(
        localDefault
      )}\nupstream:\n${formatIpcResult(upstreamDefault)}`
    );
  }
  if (upstreamDefault.ok) {
    assertIpcResult(localDefault, `${publicPackageName} default shell IPC`);
  }

  assertIpcResult(
    inspectIpcRuntime(projectDir, publicPackageName, "custom spawn"),
    `${publicPackageName} custom spawn IPC`
  );
  assertIpcResult(
    inspectIpcRuntime(projectDir, upstreamPackageName, "custom spawn"),
    `${upstreamPackageName} custom spawn IPC`
  );
}

function inspectIpcRuntime(projectDir, packageName, mode) {
  const customSpawn = mode === "custom spawn";
  const childSource =
    'process.on("message",(message)=>{process.send({pong:message.ping});});setTimeout(()=>process.exit(0),100);';
  const result = spawnSync(
    process.execPath,
    [
      "-e",
      `
      (async () => {
        const concurrently = require(${JSON.stringify(packageName)});
        const runConcurrently = ${
          customSpawn ? "concurrently.createConcurrently" : "concurrently"
        };
        if (typeof runConcurrently !== "function") {
          throw new Error("missing concurrently entrypoint for ${mode}");
        }
        const childSource = ${JSON.stringify(childSource)};
        const command = ${
          customSpawn
            ? JSON.stringify("ipc-child")
            : 'process.execPath + " -e " + JSON.stringify(childSource)'
        };
        const run = runConcurrently(
          [{ command, ipc: 3 }],
          {
            raw: true,
            ${
              customSpawn
                ? `
            spawn(_command, options) {
              const { spawn } = require("node:child_process");
              return spawn(process.execPath, ["-e", childSource], {
                ...options,
                shell: false,
              });
            },
            `
                : ""
            }
          }
        );
        const incoming = [];
        run.commands[0].messages.incoming.subscribe({
          next(event) {
            incoming.push(event.message);
          },
        });
        await run.commands[0].send({ ping: 7 });
        const events = await run.result;
        if (events.length !== 1 || events[0].exitCode !== 0) {
          throw new Error("unexpected IPC close events: " + JSON.stringify(events));
        }
        if (!incoming.some((message) => message && message.pong === 7)) {
          throw new Error("missing IPC response: " + JSON.stringify(incoming));
        }
      })().catch((error) => {
        console.error(error);
        process.exitCode = 1;
      });
      `,
    ],
    { cwd: projectDir, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }
  );
  return {
    ok: !result.error && result.status === 0,
    mode,
    packageName,
    error: result.error,
    status: result.status,
    stdout: result.stdout,
    stderr: result.stderr,
  };
}

function assertIpcResult(result, label) {
  if (result.ok) {
    return;
  }
  if (result.error) {
    throw result.error;
  }
  throw new Error(`${label} runtime audit failed\n${formatIpcResult(result)}`);
}

function formatIpcResult(result) {
  return `${result.packageName} ${result.mode} exited ${result.status}\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`;
}

function assertBinSurface(localBin, upstreamBin, localPackageDir) {
  for (const binName of Object.keys(upstreamBin)) {
    if (!Object.prototype.hasOwnProperty.call(localBin, binName)) {
      throw new Error(`missing upstream bin alias: ${binName}`);
    }
  }
  const extraBinNames = Object.keys(localBin)
    .filter((binName) => !Object.prototype.hasOwnProperty.call(upstreamBin, binName))
    .sort();
  assertJsonEqual(extraBinNames, ["concml"], "extra bin aliases");
  for (const [binName, binPath] of Object.entries(localBin)) {
    assertPackageFile(localPackageDir, binPath, `bin.${binName}`);
    if (typeof binName !== "string" || binName.length === 0) {
      throw new Error(`invalid bin name: ${binName}`);
    }
  }
}

function assertExportsSurface(localExports, upstreamExports, localPackageDir, label) {
  if (typeof upstreamExports === "string") {
    if (typeof localExports !== "string") {
      throw new Error(`${label}: expected string export target`);
    }
    assertPackageRelativeFile(localPackageDir, localExports, label);
    return;
  }
  if (
    !upstreamExports ||
    typeof upstreamExports !== "object" ||
    Array.isArray(upstreamExports)
  ) {
    throw new Error(`${label}: unsupported upstream export shape`);
  }
  if (!localExports || typeof localExports !== "object" || Array.isArray(localExports)) {
    throw new Error(`${label}: expected object export shape`);
  }
  assertJsonEqual(
    Object.keys(localExports).sort(),
    Object.keys(upstreamExports).sort(),
    `${label} keys`
  );
  for (const key of Object.keys(upstreamExports)) {
    assertExportsSurface(
      localExports[key],
      upstreamExports[key],
      localPackageDir,
      `${label}.${key}`
    );
  }
}

function assertPackageRelativeFile(packageDir, target, label) {
  if (!target.startsWith("./")) {
    throw new Error(`${label}: expected package-relative target, got ${target}`);
  }
  assertPackageFile(packageDir, target, label);
}

function assertPackageFile(packageDir, target, label) {
  if (typeof target !== "string" || target.length === 0) {
    throw new Error(`${label}: expected non-empty package file target`);
  }
  if (isAbsolute(target)) {
    throw new Error(`${label}: expected relative package file target, got ${target}`);
  }
  const targetPath = resolve(packageDir, target);
  const relativeTarget = relative(packageDir, targetPath);
  if (relativeTarget.startsWith("..") || isAbsolute(relativeTarget)) {
    throw new Error(`${label}: target escapes package directory: ${target}`);
  }
  assertFile(targetPath);
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

function readJson(path) {
  return JSON.parse(readFileSync(path, "utf8"));
}

function assertFile(path) {
  if (!existsSync(path) || !statSync(path).isFile()) {
    throw new Error(`expected file: ${path}`);
  }
}

function assertJsonEqual(actual, expected, label) {
  assertEqual(JSON.stringify(actual), JSON.stringify(expected), label);
}

function assertEqual(actual, expected, label) {
  if (actual !== expected) {
    throw new Error(`${label}: expected ${expected}, got ${actual}`);
  }
}
