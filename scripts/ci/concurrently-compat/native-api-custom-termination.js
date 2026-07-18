const {
  mkdtempSync,
  rmSync,
  writeFileSync,
} = require("node:fs");
const { tmpdir } = require("node:os");
const { resolve } = require("node:path");
const { spawn, spawnSync } = require("node:child_process");
const { Writable } = require("node:stream");
const {
  forceKillProcessForTest,
  stripAnsiColors,
} = require("./native-api-support");

async function runNativeApiCustomTermination({
  api,
  assertEqual,
  nativeApiCustomSpawnProgress,
  sink,
}) {
  await runNativeApiCustomSpawnSchedulingSmoke(api, sink);
  await runNativeApiCustomSpawnPendingRestartSmoke(api);
  await runNativeApiCustomSpawnKillTimeoutSmoke(api, sink);
  runNativeApiCustomSpawnSignalSmoke();
  runNativeApiCustomSpawnSignalPendingRestartSmoke();
  runNativeApiCustomSpawnRestartTimerBackstopSmoke();
  await runNativeApiCustomSpawnHiddenCommandsSmoke(api);

  async function runNativeApiCustomSpawnSchedulingSmoke(api, sink) {
    nativeApiCustomSpawnProgress("scheduling");
    const percentCalls = [];
    const percentRun = api.concurrently(
      [
        "node -e \"setTimeout(()=>process.exit(0), 150)\"",
        "node -e \"setTimeout(()=>process.exit(0), 150)\"",
      ],
      {
        maxProcesses: "1%",
        outputStream: sink,
        spawn(command, options) {
          percentCalls.push(command);
          return spawn(command, [], options);
        },
      }
    );
    percentRun.result.catch(() => {});
    await new Promise((resolveDelay) => setTimeout(resolveDelay, 50));
    assertEqual(
      percentCalls.length,
      1,
      "native JS API custom spawn percent maxProcesses initial call count"
    );
    await percentRun.result;

    const queuedCalls = [];
    const queuedRun = api.concurrently(
      [
        "node -e \"setTimeout(()=>process.exit(1), 10)\"",
        "node -e \"setTimeout(()=>{}, 1000)\"",
        "node -e \"process.stdout.write('should-not-start')\"",
      ],
      {
        maxProcesses: 2,
        killOthersOn: ["failure"],
        outputStream: sink,
        spawn(command, options) {
          queuedCalls.push(command);
          return spawn(command, [], options);
        },
      }
    );
    queuedRun.result.catch(() => {});
    const queuedEvents = await queuedRun.result.catch((events) => events);
    assertEqual(queuedCalls.length, 2, "native JS API custom spawn queued call count");
    assertEqual(queuedEvents.length, 2, "native JS API custom spawn queued event count");
  }

  async function runNativeApiCustomSpawnPendingRestartSmoke(api) {
    const killOthersRestartRoot = mkdtempSync(
      resolve(tmpdir(), "concurrently-ml-spawn-kill-others-restart-")
    );
    try {
      const killOthersRestartMarker = resolve(killOthersRestartRoot, "marker");
      const killOthersRestartReadyMarker = resolve(
        killOthersRestartRoot,
        "restart-ready"
      );
      let killOthersRestartOutput = "";
      const killOthersRestartSink = new Writable({
        write(chunk, _encoding, callback) {
          killOthersRestartOutput += chunk.toString();
          callback();
        },
      });
      const killOthersRestartCommand =
        "node -e " +
        JSON.stringify(
          "const fs=require('node:fs');const f=process.env.CONCURRENTLY_ML_KILL_OTHERS_RESTART_MARKER;if(!fs.existsSync(f)){fs.writeFileSync(f,'1');process.exit(1)}else{process.exit(0)}"
        );
      // Wait until the failed child's close listeners have armed its restart
      // timer before the sibling exercises kill-others cancellation.
      const killOthersRestartSuccessCommand =
        "node -e " +
        JSON.stringify(
          "const fs=require('node:fs');const f=process.env.CONCURRENTLY_ML_KILL_OTHERS_RESTART_READY;const deadline=Date.now()+2000;const poll=()=>{if(fs.existsSync(f))process.exit(0);if(Date.now()>deadline)process.exit(2);setTimeout(poll,10)};poll()"
        );
      let killOthersRestartCalls = 0;
      const killOthersRestartRun = api.concurrently(
        [killOthersRestartCommand, killOthersRestartSuccessCommand],
        {
          env: {
            CONCURRENTLY_ML_KILL_OTHERS_RESTART_MARKER: killOthersRestartMarker,
            CONCURRENTLY_ML_KILL_OTHERS_RESTART_READY:
              killOthersRestartReadyMarker,
          },
          killOthersOn: ["success"],
          maxProcesses: 2,
          outputStream: killOthersRestartSink,
          restartDelay: 1000,
          restartTries: 1,
          spawn(command, options) {
            const child = spawn(command, [], options);
            if (command === killOthersRestartCommand) {
              killOthersRestartCalls += 1;
              if (killOthersRestartCalls === 1) {
                child.once("close", () =>
                  setImmediate(() => writeFileSync(killOthersRestartReadyMarker, "1"))
                );
              }
            }

            return child;
          },
        }
      );
      killOthersRestartRun.result.catch(() => {});
      const killOthersRestartEvents = await killOthersRestartRun.result;
      assertEqual(
        killOthersRestartCalls,
        2,
        "native JS API custom spawn kill-others pending restart call count"
      );
      assertEqual(
        killOthersRestartEvents.length,
        2,
        "native JS API custom spawn kill-others pending restart event count"
      );
      if (killOthersRestartEvents.some((event) => event.exitCode !== 0)) {
        throw new Error(
          `native JS API custom spawn skipped pending restart after kill-others: ${JSON.stringify(killOthersRestartEvents)}`
        );
      }
      const plainKillOthersRestartOutput = stripAnsiColors(killOthersRestartOutput);
      if (!plainKillOthersRestartOutput.includes("--> Sending SIGTERM to other processes..")) {
        throw new Error(
          `native JS API custom spawn did not log kill-others cancellation: ${JSON.stringify(killOthersRestartOutput)}`
        );
      }
    } finally {
      rmSync(killOthersRestartRoot, { recursive: true, force: true });
    }
  }

  async function runNativeApiCustomSpawnKillTimeoutSmoke(api, sink) {
    nativeApiCustomSpawnProgress("kill timeout");
    nativeApiCustomSpawnProgress("kill timeout force kill");
    const killTimeoutRun = api.concurrently(
      [
        "kill-timeout-child",
        "node -e \"setTimeout(()=>process.exit(1),20)\"",
      ],
      {
        killOthersOn: ["failure"],
        killTimeout: 25,
        maxProcesses: 2,
        outputStream: sink,
        spawn(command, options) {
          if (command === "kill-timeout-child") {
            return spawn(
              process.execPath,
              ["-e", "process.on('SIGTERM',()=>{});setInterval(()=>{},1000)"],
              {
                ...options,
                shell: false,
              }
            );
          }
          return spawn(command, [], options);
        },
      }
    );
    killTimeoutRun.result.catch(() => {});
    const killTimeoutEvents = await killTimeoutRun.result.catch((events) => events);
    if (!killTimeoutEvents.some((event) => event.exitCode === "SIGKILL")) {
      throw new Error(
        `native JS API custom spawn did not force kill after timeout: ${JSON.stringify(killTimeoutEvents)}`
      );
    }

    nativeApiCustomSpawnProgress("kill timeout timer backstop");
    const killTimeoutBackstopCode = `
      const { Writable } = require("node:stream");
      const { spawn } = require("node:child_process");
      const api = require(${JSON.stringify(resolve("index.js"))});
      const sink = new Writable({ write(_chunk, _encoding, callback) { callback(); } });
      api.concurrently([
        ${JSON.stringify("node -e \"setInterval(()=>{},1000)\"")},
        ${JSON.stringify("node -e \"setTimeout(()=>process.exit(1),20)\"")},
      ], {
        killOthersOn: ["failure"],
        killTimeout: 2000,
        maxProcesses: 2,
        outputStream: sink,
        spawn(command, options) {
          return spawn(command, [], options);
        },
      }).result.catch(() => {}).then(() => process.stdout.write("done"));
    `;
    const killTimeoutBackstopRun = spawnSync(
      process.execPath,
      ["-e", killTimeoutBackstopCode],
      { cwd: resolve("."), encoding: "utf8", killSignal: "SIGKILL", timeout: 1200 }
    );
    assertEqual(
      killTimeoutBackstopRun.status,
      0,
      `native JS API custom spawn killTimeout timer kept process alive: ${killTimeoutBackstopRun.stderr || killTimeoutBackstopRun.error}`
    );

    const signalKillTimeoutBackstopRoot = mkdtempSync(
      resolve(tmpdir(), "concurrently-ml-spawn-signal-kill-backstop-")
    );
    try {
      nativeApiCustomSpawnProgress("kill timeout signal backstop");
      const signalKillTimeoutBackstopMarker = resolve(
        signalKillTimeoutBackstopRoot,
        "marker"
      );
      const signalKillTimeoutBackstopCommand =
        "node -e " +
        JSON.stringify(
          `const fs=require('node:fs');fs.writeFileSync(${JSON.stringify(
            signalKillTimeoutBackstopMarker
          )},'1');process.on('SIGTERM',()=>{});setInterval(()=>{},1000)`
        );
      const signalKillTimeoutCode = `
        const { Writable } = require("node:stream");
        const { spawn } = require("node:child_process");
        const api = require(${JSON.stringify(resolve("index.js"))});
        const sink = new Writable({ write(_chunk, _encoding, callback) { callback(); } });
        api.concurrently([${JSON.stringify(signalKillTimeoutBackstopCommand)}], {
          killTimeout: 100,
          outputStream: sink,
          spawn(command, options) {
            return spawn(command, [], options);
          },
        }).result.catch(() => {}).then(() => process.stdout.write("done"));
        const sendSelfSigterm = () => {
          if (process.platform === "win32") {
            process.emit("SIGTERM", "SIGTERM");
            return;
          }
          process.kill(process.pid, "SIGTERM");
        };
        const signalWhenReady = () => {
          if (require("node:fs").existsSync(${JSON.stringify(signalKillTimeoutBackstopMarker)})) {
            sendSelfSigterm();
            return;
          }
          setTimeout(signalWhenReady, 25);
        };
        signalWhenReady();
      `;
      const signalKillTimeout = spawnSync(
        process.execPath,
        ["-e", signalKillTimeoutCode],
        { cwd: resolve("."), encoding: "utf8", killSignal: "SIGKILL", timeout: 2500 }
      );
      assertEqual(
        signalKillTimeout.status,
        0,
        `native JS API custom spawn signal killTimeout hung: ${signalKillTimeout.stderr || signalKillTimeout.error}`
      );
      assertEqual(
        signalKillTimeout.stdout,
        "done",
        "native JS API custom spawn signal killTimeout completion"
      );
    } finally {
      rmSync(signalKillTimeoutBackstopRoot, { recursive: true, force: true });
    }
  }

  function runNativeApiCustomSpawnSignalSmoke() {
    nativeApiCustomSpawnProgress("signal restart");
    const signalRestartRoot = mkdtempSync(
      resolve(tmpdir(), "concurrently-ml-spawn-signal-restart-")
    );
    try {
      const signalRestartMarker = resolve(signalRestartRoot, "marker");
      const signalRestartCode = `
        const { Writable } = require("node:stream");
        const { spawn } = require("node:child_process");
        const api = require(${JSON.stringify(resolve("index.js"))});
        const marker = ${JSON.stringify(signalRestartMarker)};
        const command = "node -e " + ${JSON.stringify(
          JSON.stringify(
            "const fs=require('node:fs');const f=process.env.CONCURRENTLY_ML_SIGNAL_RESTART_MARKER;if(!fs.existsSync(f)){fs.writeFileSync(f,'1');process.once('SIGTERM',()=>process.exit(1));setInterval(()=>{},1000)}else{process.exit(0)}"
          )
        )};
        const sink = new Writable({ write(_chunk, _encoding, callback) { callback(); } });
        let calls = 0;
        api.concurrently([command], {
          env: { CONCURRENTLY_ML_SIGNAL_RESTART_MARKER: marker },
          outputStream: sink,
          restartDelay: 0,
          restartTries: 1,
          spawn(commandText, options) {
            calls += 1;
            return spawn(commandText, [], options);
          },
        }).result.then(
          () => process.stdout.write("done:" + calls),
          (error) => {
            process.stderr.write(JSON.stringify(error));
            process.exit(1);
          }
        );
        const sendSelfSigterm = () => {
          if (process.platform === "win32") {
            process.emit("SIGTERM", "SIGTERM");
            return;
          }
          process.kill(process.pid, "SIGTERM");
        };
        setTimeout(sendSelfSigterm, 100);
      `;
      const signalRestart = spawnSync(process.execPath, ["-e", signalRestartCode], {
        cwd: resolve("."),
        encoding: "utf8",
        killSignal: "SIGKILL",
        timeout: 5000,
      });
      assertEqual(
        signalRestart.status,
        0,
        `native JS API custom spawn non-SIGINT restart failed: ${signalRestart.stderr || signalRestart.error}`
      );
      assertEqual(
        signalRestart.stdout,
        "done:2",
        "native JS API custom spawn non-SIGINT restart call count"
      );
    } finally {
      rmSync(signalRestartRoot, { recursive: true, force: true });
    }

    const signalKillTimeoutRoot = mkdtempSync(
      resolve(tmpdir(), "concurrently-ml-spawn-signal-kill-timeout-")
    );
    try {
      nativeApiCustomSpawnProgress("signal kill timeout restart");
      const signalKillTimeoutMarker = resolve(signalKillTimeoutRoot, "marker");
      const signalKillTimeoutCommand =
        "node -e " +
        JSON.stringify(
          `const fs=require('node:fs'); const marker=${JSON.stringify(
            signalKillTimeoutMarker
          )}; if(!fs.existsSync(marker)){fs.writeFileSync(marker,'1'); process.once('SIGTERM',()=>process.exit(1)); setInterval(()=>{},1000)} else {process.stdout.write('restarted'); setTimeout(()=>process.exit(0),300)}`
        );
      const signalKillTimeoutCode = `
        const api = require(${JSON.stringify(resolve("index.js"))});
        const { spawn } = require("node:child_process");
        const { Writable } = require("node:stream");
        const sink = new Writable({ write(_chunk, _encoding, callback) { callback(); } });
        let calls = 0;
        api.concurrently([${JSON.stringify(signalKillTimeoutCommand)}], {
          killTimeout: 100,
          outputStream: sink,
          restartDelay: 0,
          restartTries: 1,
          spawn(command, options) {
            calls += 1;
            return spawn(command, [], options);
          },
        }).result.then(
          () => process.stdout.write("done:" + calls),
          (error) => {
            process.stderr.write(JSON.stringify(error));
            process.exit(1);
          }
        );
        const signalWhenReady = () => {
          if (require("node:fs").existsSync(${JSON.stringify(signalKillTimeoutMarker)})) {
            if (process.platform === "win32") {
              process.emit("SIGTERM", "SIGTERM");
            } else {
              process.kill(process.pid, "SIGTERM");
            }
            return;
          }
          setTimeout(signalWhenReady, 25);
        };
        signalWhenReady();
      `;
      const signalKillTimeout = spawnSync(
        process.execPath,
        ["-e", signalKillTimeoutCode],
        { cwd: resolve("."), encoding: "utf8", killSignal: "SIGKILL", timeout: 2500 }
      );
      assertEqual(
        signalKillTimeout.status,
        0,
        `native JS API custom spawn signal killTimeout restart failed: ${signalKillTimeout.stderr || signalKillTimeout.error}`
      );
      assertEqual(
        signalKillTimeout.stdout,
        "done:2",
        "native JS API custom spawn signal killTimeout restart call count"
      );
    } finally {
      rmSync(signalKillTimeoutRoot, { recursive: true, force: true });
    }

    const signalChildRoot = mkdtempSync(
      resolve(tmpdir(), "concurrently-ml-spawn-signal-")
    );
    try {
      nativeApiCustomSpawnProgress("signal child cleanup");
      const signalChildPidFile = resolve(signalChildRoot, "child.pid");
      const signalChildCommand =
        "node -e " +
        JSON.stringify(
          `require('node:fs').writeFileSync(${JSON.stringify(
            signalChildPidFile
          )}, String(process.pid)); setInterval(()=>{},1000)`
        );
      const signalChildCode = `
        const api = require(${JSON.stringify(resolve("index.js"))});
        const { spawn } = require("node:child_process");
        const { existsSync, readFileSync } = require("node:fs");
        const { Writable } = require("node:stream");
        const pidFile = ${JSON.stringify(signalChildPidFile)};
        const sink = new Writable({ write(_chunk, _encoding, callback) { callback(); } });
        const run = api.concurrently([${JSON.stringify(signalChildCommand)}], {
          outputStream: sink,
          spawn(command, options) {
            return spawn(command, [], options);
          },
        });
        run.result.catch(() => {});
        const isRunning = (pid) => {
          try {
            process.kill(pid, 0);
            return true;
          } catch (_error) {
            return false;
          }
        };
        const signalWhenReady = () => {
          if (existsSync(pidFile)) {
            if (process.platform === "win32") {
              process.emit("SIGTERM", "SIGTERM");
            } else {
              process.kill(process.pid, "SIGTERM");
            }
            return;
          }
          setTimeout(signalWhenReady, 25);
        };
        signalWhenReady();
        setTimeout(() => {
          if (!existsSync(pidFile)) {
            process.exit(2);
          }
          const childPid = Number(readFileSync(pidFile, "utf8"));
          const childRunning = isRunning(childPid);
          if (childRunning) {
            forceKillProcessForTest(childPid);
          }
          process.exit(childRunning ? 1 : 0);
        }, 1200);
      `;
      const signalChild = spawnSync(process.execPath, ["-e", signalChildCode], {
        cwd: resolve("."),
        encoding: "utf8",
        killSignal: "SIGKILL",
        timeout: 2500,
      });
      assertEqual(
        signalChild.status,
        0,
        `native JS API custom spawn signal cleanup failed: ${signalChild.stderr || signalChild.stdout || signalChild.error}`
      );
    } finally {
      rmSync(signalChildRoot, { recursive: true, force: true });
    }
  }

  function runNativeApiCustomSpawnSignalPendingRestartSmoke() {
    nativeApiCustomSpawnProgress("signal pending restart");
    const signalPendingRestartCode = `
      const { Writable } = require("node:stream");
      const { spawn } = require("node:child_process");
      const api = require(${JSON.stringify(resolve("index.js"))});
      const sink = new Writable({ write(_chunk, _encoding, callback) { callback(); } });
      api.concurrently([${JSON.stringify("node -e \"process.exit(1)\"")}], {
        outputStream: sink,
        restartDelay: 5000,
        restartTries: 1,
        spawn(command, options) {
          return spawn(command, [], options);
        },
      }).result.catch(() => {}).then(() => process.stdout.write("done"));
      const sendSelfSigterm = () => {
        if (process.platform === "win32") {
          process.emit("SIGTERM", "SIGTERM");
          return;
        }
        process.kill(process.pid, "SIGTERM");
      };
      setTimeout(sendSelfSigterm, 100);
    `;
    const signalPendingRestart = spawnSync(
      process.execPath,
      ["-e", signalPendingRestartCode],
      { cwd: resolve("."), encoding: "utf8", killSignal: "SIGKILL", timeout: 1200 }
    );
    assertEqual(
      signalPendingRestart.status,
      0,
      `native JS API custom spawn signal left pending restart timer: ${signalPendingRestart.stderr || signalPendingRestart.error}`
    );
    assertEqual(
      signalPendingRestart.stdout,
      "done",
      "native JS API custom spawn signal pending restart completion"
    );
  }

  function runNativeApiCustomSpawnRestartTimerBackstopSmoke() {
    nativeApiCustomSpawnProgress("restart timer backstop");
    const restartTimerBackstopCode = `
      const { Writable } = require("node:stream");
      const { spawn } = require("node:child_process");
      const api = require(${JSON.stringify(resolve("index.js"))});
      const sink = new Writable({ write(_chunk, _encoding, callback) { callback(); } });
      let calls = 0;
      api.concurrently([
        ${JSON.stringify("node -e \"process.exit(1)\"")},
        ${JSON.stringify("node -e \"setTimeout(()=>process.exit(0),50)\"")},
        "throw-on-start",
      ], {
        maxProcesses: 2,
        outputStream: sink,
        restartDelay: 2000,
        restartTries: 1,
        spawn(command, options) {
          calls += 1;
          if (command === "throw-on-start") {
            throw new Error("queued-spawn-boom");
          }
          return spawn(command, [], options);
        },
      }).result.catch(() => process.stdout.write("done"));
    `;
    const restartTimerBackstopRun = spawnSync(
      process.execPath,
      ["-e", restartTimerBackstopCode],
      { cwd: resolve("."), encoding: "utf8", killSignal: "SIGKILL", timeout: 1200 }
    );
    assertEqual(
      restartTimerBackstopRun.status,
      0,
      `native JS API custom spawn restart timer kept process alive: ${restartTimerBackstopRun.stderr || restartTimerBackstopRun.error}`
    );
    assertEqual(
      restartTimerBackstopRun.stdout,
      "done",
      "native JS API custom spawn restart timer completion"
    );
  }

  async function runNativeApiCustomSpawnHiddenCommandsSmoke(api) {
    nativeApiCustomSpawnProgress("hidden commands");
    let hiddenOutput = "";
    const hiddenSink = new Writable({
      write(chunk, _encoding, callback) {
        hiddenOutput += chunk.toString();
        callback();
      },
    });
    await api.concurrently(
      [{ command: "node -e \"process.stdout.write('hidden-secret')\"", hidden: true }],
      {
        outputStream: hiddenSink,
        spawn(command, options) {
          return spawn(command, [], options);
        },
      }
    ).result;
    assertEqual(hiddenOutput, "", "native JS API custom spawn hidden output");

    const hiddenRawChildCode = `
      const { spawn } = require("node:child_process");
      const api = require(${JSON.stringify(resolve("index.js"))});
      api.concurrently(
        [{ command: ${JSON.stringify("node -e \"process.stdout.write('hidden-raw-secret')\"")}, hidden: true }],
        {
          raw: true,
          spawn(command, options) {
            return spawn(command, [], options);
          },
        }
      ).result.then(() => {});
    `;
    const hiddenRawChild = spawnSync(process.execPath, ["-e", hiddenRawChildCode], {
      cwd: resolve("."),
      encoding: "utf8",
    });
    assertEqual(
      hiddenRawChild.status,
      0,
      `native JS API custom spawn hidden raw child exited with ${hiddenRawChild.status}: ${hiddenRawChild.stderr}`
    );
    assertEqual(
      hiddenRawChild.stdout,
      "",
      "native JS API custom spawn hidden raw stdout"
    );
  }
}

module.exports = { runNativeApiCustomTermination };
