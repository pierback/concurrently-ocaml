const {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} = require("node:fs");
const { tmpdir } = require("node:os");
const { resolve } = require("node:path");
const { spawn } = require("node:child_process");
const { EventEmitter } = require("node:events");
const { PassThrough, Writable } = require("node:stream");
const {
  forceKillProcessForTest,
  processRunning,
  waitFor,
  waitForSync,
} = require("./native-api-support");

async function runNativeApiCustomPolicy({
  api,
  assertEqual,
  commands,
  nativeApiCustomSpawnProgress,
  sink,
}) {
  const { jsSingleQuoted, nodeEvalCommand } = commands;

  await runNativeApiCustomSpawnMarkerRestartSmoke(api);
  await runNativeApiCustomSpawnRestartOptionsSmoke(api, sink);
  await runNativeApiCustomSpawnRestartThrowSmoke(api, sink);
  await runNativeApiCustomSpawnStartupThrowSmoke(api, sink);
  await runNativeApiCustomSpawnCompletionPolicySmoke(api, sink);
  await runNativeApiCustomSpawnKillPolicySmoke(api, sink);
  await runNativeApiCustomSpawnErrorsSmoke(api, sink);

  async function runNativeApiCustomSpawnMarkerRestartSmoke(api) {
    nativeApiCustomSpawnProgress("restart policy");
    nativeApiCustomSpawnProgress("restart policy marker restart");
    const restartRoot = mkdtempSync(resolve(tmpdir(), "concurrently-ml-spawn-restart-"));
    try {
      const restartMarker = resolve(restartRoot, "marker");
      let restartOutput = "";
      const restartSink = new Writable({
        write(chunk, _encoding, callback) {
          restartOutput += chunk.toString();
          callback();
        },
      });
      let restartCalls = 0;
      const restartRun = api.concurrently(
        [
          "node -e " +
            JSON.stringify(
              "const fs=require('node:fs');const f=process.env.CONCURRENTLY_ML_RESTART_MARKER;if(!fs.existsSync(f)){fs.writeFileSync(f,'1');process.exit(1)}process.exit(0)"
            ),
        ],
        {
          env: { CONCURRENTLY_ML_RESTART_MARKER: restartMarker },
          outputStream: restartSink,
          restartTries: 1,
          spawn(command, options) {
            restartCalls += 1;
            return spawn(command, [], options);
          },
        }
      );
      restartRun.result.catch(() => {});
      const restartPublicCloses = [];
      restartRun.commands[0].close.subscribe((event) => {
        restartPublicCloses.push(event.exitCode);
      });
      const restartEvents = await restartRun.result;
      assertEqual(restartCalls, 2, "native JS API custom spawn restart call count");
      assertEqual(
        JSON.stringify(restartPublicCloses),
        JSON.stringify([0]),
        "native JS API custom spawn restart public close stream"
      );
      assertEqual(
        restartEvents[0].exitCode,
        0,
        "native JS API custom spawn restart final exit code"
      );
      if (!restartOutput.includes("restarted")) {
        throw new Error(
          `native JS API custom spawn did not log restart: ${JSON.stringify(restartOutput)}`
        );
      }
    } finally {
      rmSync(restartRoot, { recursive: true, force: true });
    }
  }

  async function runNativeApiCustomSpawnRestartOptionsSmoke(api, sink) {
    nativeApiCustomSpawnProgress("restart policy options");
    const exponentialStartedAt = Date.now();
    let exponentialCalls = 0;
    const exponentialEvents = await api.concurrently(
      ["node -e \"process.exit(1)\""],
      {
        outputStream: sink,
        restartTries: 1,
        restartDelay: "exponential",
        spawn(command, options) {
          exponentialCalls += 1;
          return spawn(command, [], options);
        },
      }
    ).result.catch((events) => events);
    assertEqual(
      exponentialCalls,
      2,
      "native JS API custom spawn exponential restart call count"
    );
    assertEqual(
      exponentialEvents[0].exitCode,
      1,
      "native JS API custom spawn exponential restart final exit code"
    );
    if (Date.now() - exponentialStartedAt < 900) {
      throw new Error("native JS API custom spawn exponential restart did not delay");
    }

    let fractionalRestartRuns = 0;
    const fractionalRestartEvents = await api.concurrently(
      ["node -e \"process.exit(1)\""],
      {
        outputStream: sink,
        restartTries: 1.5,
        spawn(command, options) {
          fractionalRestartRuns += 1;
          return spawn(command, [], options);
        },
      }
    ).result;
    assertEqual(
      fractionalRestartRuns,
      2,
      "native JS API custom spawn fractional restart run count"
    );
    assertEqual(
      fractionalRestartEvents.length,
      0,
      "native JS API custom spawn fractional restart event count"
    );
  }

  async function runNativeApiCustomSpawnRestartThrowSmoke(api, sink) {
    nativeApiCustomSpawnProgress("restart policy restart throw");
    let restartThrowPid;
    let restartThrowCalls = 0;
    const restartThrowRun = api.concurrently(
      [
        "node -e \"process.exit(1)\"",
        "node -e \"setInterval(()=>{},1000)\"",
      ],
      {
        maxProcesses: 2,
        outputStream: sink,
        restartTries: 1,
        spawn(command, options) {
          restartThrowCalls += 1;
          if (restartThrowCalls === 3) {
            throw new Error("restart-spawn-boom");
          }
          const child = spawn(command, [], options);
          if (command.includes("setInterval")) {
            restartThrowPid = child.pid;
          }
          return child;
        },
      }
    );
    restartThrowRun.result.catch(() => {});
    try {
      const restartThrowError = await restartThrowRun.result.catch((error) => error);
      assertEqual(
        restartThrowError.message,
        "restart-spawn-boom",
        "native JS API custom spawn restart throw error"
      );
      await waitFor(
        () => !processRunning(restartThrowPid),
        5000,
        "native JS API custom spawn restart throw left sibling process running"
      );
    } finally {
      if (processRunning(restartThrowPid)) {
        forceKillProcessForTest(restartThrowPid);
      }
    }
  }

  async function runNativeApiCustomSpawnStartupThrowSmoke(api, sink) {
    nativeApiCustomSpawnProgress("restart policy startup throw");
    const startupThrowRoot = mkdtempSync(
      resolve(tmpdir(), "concurrently-ml-spawn-startup-throw-")
    );
    let startupThrowPid;
    try {
      const startupThrowReady = resolve(startupThrowRoot, "ready");
      const startupThrowSource = `process.on('SIGTERM',()=>{}); require('node:fs').writeFileSync(${JSON.stringify(
        startupThrowReady
      )}, '1'); setInterval(()=>{},1000)`;
      const startupThrowRun = api.concurrently(
        [
          "startup-child",
          "throw-on-start",
        ],
        {
          killTimeout: 100,
          maxProcesses: 2,
          outputStream: sink,
          spawn(command, options) {
            if (command === "throw-on-start") {
              throw new Error("startup-spawn-boom");
            }
            const child = spawn(process.execPath, ["-e", startupThrowSource], {
              ...options,
              shell: false,
            });
            startupThrowPid = child.pid;

            waitForSync(() => existsSync(startupThrowReady), 1000);

            return child;
          },
        }
      );
      startupThrowRun.result.catch(() => {});
      const startupThrowError = await startupThrowRun.result.catch((error) => error);
      assertEqual(
        startupThrowError.message,
        "startup-spawn-boom",
        "native JS API custom spawn startup throw error"
      );
      await waitFor(
        () => !processRunning(startupThrowPid),
        5000,
        "native JS API custom spawn startup throw cleared killTimeout before SIGKILL"
      );
    } finally {
      if (processRunning(startupThrowPid)) {
        forceKillProcessForTest(startupThrowPid);
      }
      rmSync(startupThrowRoot, { recursive: true, force: true });
    }
  }

  async function runNativeApiCustomSpawnCompletionPolicySmoke(api, sink) {
    nativeApiCustomSpawnProgress("completion policy");
    const numericSuccessEvents = await api.concurrently(
      [
        { name: "1", command: "node -e \"process.exit(0)\"" },
        "node -e \"process.exit(7)\"",
      ],
      {
        outputStream: sink,
        successCondition: "command-1",
        spawn(command, options) {
          return spawn(command, [], options);
        },
      }
    ).result.then(
      () => {
        throw new Error("native JS API custom spawn numeric success selector resolved");
      },
      (events) => events
    );
    assertEqual(
      numericSuccessEvents.length,
      2,
      "native JS API custom spawn numeric success event count"
    );
  }

  async function runNativeApiCustomSpawnKillPolicySmoke(api, sink) {
    nativeApiCustomSpawnProgress("kill policy");
    const killCalls = [];
    const killRun = api.concurrently(
      ["node -e \"setTimeout(()=>{}, 1000)\""],
      {
        outputStream: sink,
        spawn(command, options) {
          return spawn(command, [], options);
        },
        kill(pid, signal) {
          killCalls.push({ pid, signal });
          process.kill(pid, signal);
        },
      }
    );
    killRun.result.catch(() => {});
    setTimeout(() => killRun.commands[0].kill("SIGTERM"), 25);
    await killRun.result.catch((events) => events);
    assertEqual(killCalls.length, 1, "native JS API custom spawn kill call count");
    assertEqual(
      Number.isInteger(killCalls[0].pid),
      true,
      "native JS API custom spawn kill pid"
    );
    assertEqual(killCalls[0].signal, "SIGTERM", "native JS API custom spawn kill signal");

    const killedRestartRun = api.concurrently(
      ["node -e \"setTimeout(()=>{}, 1000)\""],
      {
        outputStream: sink,
        restartTries: 1,
        spawn(command, options) {
          return spawn(command, [], options);
        },
      }
    );
    killedRestartRun.result.catch(() => {});
    await waitFor(
      () => api.Command.canKill(killedRestartRun.commands[0]),
      1000,
      "native JS API custom spawn restart kill command did not become killable"
    );
    killedRestartRun.commands[0].kill("SIGTERM");
    const killedRestartEvents = await killedRestartRun.result.catch((events) => events);
    assertEqual(
      killedRestartEvents.length,
      1,
      "native JS API custom spawn killed restart event count"
    );
    assertEqual(
      killedRestartEvents[0].killed,
      true,
      "native JS API custom spawn killed restart event flag"
    );

    let invalidKillSignalPid;
    const invalidKillSignalRun = api.concurrently(
      [
        "node -e \"process.exit(1)\"",
        "node -e \"setInterval(()=>{}, 1000)\"",
      ],
      {
        killOthersOn: ["failure"],
        killSignal: "TERM",
        outputStream: sink,
        spawn(command, options) {
          const child = spawn(command, [], options);
          if (command.includes("setInterval")) {
            invalidKillSignalPid = child.pid;
          }
          return child;
        },
      }
    );
    invalidKillSignalRun.result.catch(() => {});
    try {
      const invalidKillSignalResult = await Promise.race([
        invalidKillSignalRun.result.catch((error) => error),
        new Promise((resolveTimeout) => {
          setTimeout(() => resolveTimeout("timeout"), 1000);
        }),
      ]);
      if (invalidKillSignalResult === "timeout") {
        throw new Error("native JS API custom spawn invalid kill signal hung");
      }
      assertEqual(
        invalidKillSignalResult.code,
        "ERR_UNKNOWN_SIGNAL",
        "native JS API custom spawn invalid kill signal error"
      );
    } finally {
      if (processRunning(invalidKillSignalPid)) {
        forceKillProcessForTest(invalidKillSignalPid);
      }
    }
  }

  async function runNativeApiCustomSpawnErrorsSmoke(api, sink) {
    nativeApiCustomSpawnProgress("spawn errors");
    const spawnErrorEvents = await api.concurrently(["ignored"], {
      raw: true,
      outputStream: sink,
      spawn() {
        return spawn("definitely-not-a-real-binary-concurrently-ml", [], {
          stdio: ["pipe", "pipe", "pipe"],
        });
      },
    }).result.catch((events) => events);
    await new Promise((resolveDelay) => setTimeout(resolveDelay, 50));
    assertEqual(
      spawnErrorEvents.length,
      1,
      "native JS API custom spawn error event count"
    );

    let staleCloseCalls = 0;
    let staleCloseOutput = "";
    const staleCloseSink = new Writable({
      write(chunk, _encoding, callback) {
        staleCloseOutput += chunk.toString();
        callback();
      },
    });
    const staleCloseEvents = await api.concurrently(["stale-close"], {
      outputStream: staleCloseSink,
      restartDelay: 0,
      restartTries: 1,
      spawn() {
        staleCloseCalls += 1;
        const child = new EventEmitter();
        child.pid = 80000 + staleCloseCalls;
        child.stdout = new PassThrough();
        child.stderr = new PassThrough();
        child.stdin = new PassThrough();
        child.kill = () => true;
        if (staleCloseCalls === 1) {
          setTimeout(() => child.emit("error", new Error("stale-close-boom")), 0);
          setTimeout(() => child.emit("close", 1, null), 30);
        } else {
          setTimeout(() => {
            child.stdout.write("ok");
            child.emit("close", 0, null);
          }, 80);
        }
        return child;
      },
    }).result;
    assertEqual(
      staleCloseCalls,
      2,
      "native JS API custom spawn stale close restart call count"
    );
    assertEqual(
      staleCloseEvents[0].exitCode,
      0,
      "native JS API custom spawn stale close final exit code"
    );
    if (!staleCloseOutput.includes("ok")) {
      throw new Error(
        `native JS API custom spawn stale close lost replacement output: ${JSON.stringify(staleCloseOutput)}`
      );
    }

    let staleErrorCalls = 0;
    let staleErrorOutput = "";
    const staleErrorSink = new Writable({
      write(chunk, _encoding, callback) {
        staleErrorOutput += chunk.toString();
        callback();
      },
    });
    const staleErrorEvents = await api.concurrently(["stale-error"], {
      outputStream: staleErrorSink,
      restartDelay: 0,
      restartTries: 1,
      spawn() {
        staleErrorCalls += 1;
        const child = new EventEmitter();
        child.pid = 81000 + staleErrorCalls;
        child.stdout = new PassThrough();
        child.stderr = new PassThrough();
        child.stdin = new PassThrough();
        child.kill = () => true;
        if (staleErrorCalls === 1) {
          setTimeout(() => child.emit("close", 1, null), 0);
          setTimeout(() => child.emit("error", new Error("stale-error-boom")), 30);
        } else {
          setTimeout(() => {
            child.stdout.write("ok");
            child.emit("close", 0, null);
          }, 80);
        }
        return child;
      },
    }).result;
    assertEqual(
      staleErrorCalls,
      2,
      "native JS API custom spawn stale error restart call count"
    );
    assertEqual(
      staleErrorEvents[0].exitCode,
      0,
      "native JS API custom spawn stale error final exit code"
    );
    if (!staleErrorOutput.includes("ok")) {
      throw new Error(
        `native JS API custom spawn stale error lost replacement output: ${JSON.stringify(staleErrorOutput)}`
      );
    }

    let throwingSpawnPid;
    let throwingSpawnCalls = 0;
    const throwingSpawnRun = api.concurrently(
      [
        "node -e \"setInterval(()=>{}, 1000)\"",
        "node -e \"process.exit(0)\"",
      ],
      {
        maxProcesses: 2,
        outputStream: sink,
        spawn(command, options) {
          throwingSpawnCalls += 1;
          if (throwingSpawnCalls === 2) {
            throw new Error("spawn-boom");
          }
          const child = spawn(command, [], options);
          throwingSpawnPid = child.pid;
          return child;
        },
      }
    );
    throwingSpawnRun.result.catch(() => {});
    try {
      const spawnError = await throwingSpawnRun.result.catch((error) => error);
      assertEqual(
        spawnError.message,
        "spawn-boom",
        "native JS API custom spawn throw error"
      );
      await waitFor(
        () => !processRunning(throwingSpawnPid),
        5000,
        "native JS API custom spawn throw left previous process running"
      );
    } finally {
      if (processRunning(throwingSpawnPid)) {
        forceKillProcessForTest(throwingSpawnPid);
      }
    }

    if (process.platform !== "win32") {
      const killTreeRoot = mkdtempSync(resolve(tmpdir(), "concurrently-ml-spawn-kill-tree-"));
      const killTreePidFile = resolve(killTreeRoot, "grandchild.pid");
      const killTreeCommand = nodeEvalCommand(
        "const cp=require('node:child_process');" +
          "const fs=require('node:fs');" +
          "const child=cp.spawn('sleep',['30'],{stdio:'ignore'});" +
          `fs.writeFileSync('${jsSingleQuoted(killTreePidFile)}',String(child.pid));` +
          "setInterval(function(){},1000)"
      );
      const killTreeRun = api.concurrently(
        [killTreeCommand],
        {
          outputStream: sink,
          spawn(command, options) {
            return spawn(command, [], options);
          },
        }
      );
      killTreeRun.result.catch(() => {});
      try {
        await waitFor(
          () => existsSync(killTreePidFile) && api.Command.canKill(killTreeRun.commands[0]),
          10000,
          "native JS API custom spawn kill-tree command did not become killable"
        );
        const grandchildPid = Number(readFileSync(killTreePidFile, "utf8"));
        killTreeRun.commands[0].kill("SIGTERM");
        await killTreeRun.result.catch((events) => events);
        await waitFor(
          () => !processRunning(grandchildPid),
          10000,
          "native JS API custom spawn default kill left descendant running"
        );
      } finally {
        const grandchildPid = existsSync(killTreePidFile)
          ? Number(readFileSync(killTreePidFile, "utf8"))
          : undefined;
        if (processRunning(grandchildPid)) {
          process.kill(grandchildPid, "SIGKILL");
        }
        rmSync(killTreeRoot, { recursive: true, force: true });
      }

      const killTreeNoPathRoot = mkdtempSync(
        resolve(tmpdir(), "concurrently-ml-spawn-kill-tree-no-path-")
      );
      const killTreeNoPathPidFile = resolve(killTreeNoPathRoot, "grandchild.pid");
      const absoluteNodeCommand =
        JSON.stringify(process.execPath) +
        " -e " +
        JSON.stringify(
          "const cp=require('node:child_process');" +
            "const fs=require('node:fs');" +
            "const child=cp.spawn('/bin/sleep',['30'],{stdio:'ignore'});" +
            `fs.writeFileSync('${jsSingleQuoted(killTreeNoPathPidFile)}',String(child.pid));` +
            "setInterval(function(){},1000)"
        );
      const killTreeNoPathRun = api.concurrently([absoluteNodeCommand], {
        outputStream: sink,
        spawn(command, options) {
          return spawn(command, [], options);
        },
      });
      killTreeNoPathRun.result.catch(() => {});
      const originalPath = process.env.PATH;
      try {
        await waitFor(
          () =>
            existsSync(killTreeNoPathPidFile) &&
            api.Command.canKill(killTreeNoPathRun.commands[0]),
          10000,
          "native JS API custom spawn kill-tree no-PATH command did not become killable"
        );
        const grandchildPid = Number(readFileSync(killTreeNoPathPidFile, "utf8"));
        process.env.PATH = "";
        killTreeNoPathRun.commands[0].kill("SIGTERM");
        process.env.PATH = originalPath;
        await killTreeNoPathRun.result.catch((events) => events);
        await waitFor(
          () => !processRunning(grandchildPid),
          10000,
          "native JS API custom spawn default kill depended on pgrep PATH lookup"
        );
      } finally {
        process.env.PATH = originalPath;
        const grandchildPid = existsSync(killTreeNoPathPidFile)
          ? Number(readFileSync(killTreeNoPathPidFile, "utf8"))
          : undefined;
        if (processRunning(grandchildPid)) {
          process.kill(grandchildPid, "SIGKILL");
        }
        rmSync(killTreeNoPathRoot, { recursive: true, force: true });
      }
    }
  }

}

module.exports = { runNativeApiCustomPolicy };
