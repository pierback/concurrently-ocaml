const {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
} = require("node:fs");
const { tmpdir } = require("node:os");
const { resolve } = require("node:path");
const { spawn, spawnSync } = require("node:child_process");
const { EventEmitter } = require("node:events");
const { PassThrough, Writable } = require("node:stream");
const {
  createDiscardSink,
  createOutputCapture,
  processRunning,
  restoreEnvironmentValue,
  stripAnsiColors,
  waitFor,
} = require("./native-api-support");

async function runNativeApiCore({ assertEqual, cliCommandRunner, commands }) {
  const {
    inputEchoCommand,
    jsSingleQuoted,
    nodeDelayPrintCommand,
    nodeEvalCommand,
    nodeExitCommand,
    nodeHangCommand,
    nodePrintCommand,
  } = commands;

  await runNativeApiPerCommandKillSmoke();
  await runNativeApiImmediateKillSmoke();
  await runNativeApiNativeKillPolicyManualKillSmoke();
  await runNativeApiCustomKillPolicySmoke();
  await runNativeApiExitedCommandKillSmoke();
  await runNativeApiClosedIpcSendSmoke();
  await runNativeApiControllerIndexLabelSmoke();
  await runNativeApiControllerTemplateIndexAndStringColorSmoke();
  await runNativeApiControllerIpcSmoke();
  await runNativeApiGlobalRawCommandFalseSmoke();
  await runNativeApiCommandAwareLoggerSmoke();
  await runNativeApiDirectOptionsSmoke();

  async function runNativeApiPerCommandKillSmoke() {
    const api = require(resolve("index.js"));
    const sink = createDiscardSink();
    const run = api.concurrently([nodeHangCommand(), nodeHangCommand()], {
      outputStream: sink,
      prefixColors: false,
    });
    run.result.catch(() => {});

    await waitFor(
      () => run.commands.every((command) => api.Command.canKill(command)),
      10000,
      "native JS API commands did not become killable"
    );
    run.commands.forEach((command, index) => {
      if (!command.process || !Number.isInteger(command.process.pid)) {
        throw new Error(`native JS API command ${index} canKill without process`);
      }
      command.kill("SIGTERM");
      assertEqual(command.killed, true, `native JS API command ${index} kill flag`);
      assertEqual(
        command.killSignal,
        "SIGTERM",
        `native JS API command ${index} kill signal`
      );
    });

    const events = await run.result.then(
      (value) => value,
      (error) => error
    );
    if (!Array.isArray(events)) {
      throw new Error(`native JS API kill returned non-event rejection: ${events}`);
    }
    assertEqual(events.length, 2, "native JS API close event count");
    events.forEach((event, index) => {
      assertEqual(event.killed, true, `native JS API command ${index} killed`);
    });
    console.log("compat ok: native JS API per-command kill");
  }

  async function runNativeApiImmediateKillSmoke() {
    const api = require(resolve("index.js"));
    const sink = createDiscardSink();
    const run = api.concurrently([nodeHangCommand()], {
      outputStream: sink,
      prefixColors: false,
    });
    run.result.catch(() => {});
    const command = run.commands[0];

    if (api.Command.canKill(command)) {
      throw new Error("native JS API immediate Command.canKill was true before pid discovery");
    }
    if (command.pid !== undefined) {
      throw new Error(`native JS API immediate kill already had pid: ${command.pid}`);
    }
    command.kill("SIGTERM");

    const events = await run.result.then(
      (value) => value,
      (error) => error
    );
    if (!Array.isArray(events)) {
      throw new Error(`native JS API immediate kill returned non-events: ${events}`);
    }
    assertEqual(events.length, 1, "native JS API immediate kill event count");
    assertEqual(events[0].killed, true, "native JS API immediate kill flag");
    assertEqual(command.killed, true, "native JS API immediate command kill flag");
    console.log("compat ok: native JS API immediate kill before pid discovery");
  }

  async function runNativeApiNativeKillPolicyManualKillSmoke() {
    if (process.platform === "win32") {
      return;
    }

    const api = require(resolve("index.js"));
    const fixture = mkdtempSync(resolve(tmpdir(), "concurrently-ml-api-kill-policy-"));
    const pidFile = resolve(fixture, "grandchild.pid");
    const sink = createDiscardSink();
    const command = nodeEvalCommand(
      "const cp=require('node:child_process');" +
        "const fs=require('node:fs');" +
        `const child=cp.spawn('sleep',['30'],{stdio:'ignore'});` +
        `fs.writeFileSync('${jsSingleQuoted(pidFile)}',String(child.pid));` +
        "setInterval(function(){},1000)"
    );
    const run = api.concurrently([command, nodeHangCommand()], {
      killOthersOn: ["failure"],
      outputStream: sink,
      prefixColors: false,
    });
    run.result.catch(() => {});
    const result = run.result.catch((events) => events);

    try {
      await waitFor(
        () => existsSync(pidFile) && api.Command.canKill(run.commands[0]),
        10000,
        "native JS API kill-policy command did not become killable"
      );
      const grandchildPid = Number(readFileSync(pidFile, "utf8"));
      run.commands[0].kill("SIGTERM");
      await waitFor(
        () => !processRunning(grandchildPid),
        10000,
        "native JS API kill-policy manual kill left descendant running"
      );
      run.commands[1].kill("SIGTERM");
      await result;
    } finally {
      rmSync(fixture, { recursive: true, force: true });
    }

    console.log("compat ok: native JS API kill policy manual kill cleans descendants");
  }

  async function runNativeApiCustomKillPolicySmoke() {
    const api = require(resolve("index.js"));
    const calls = [];
    const sink = createDiscardSink();
    const run = api.concurrently([nodeExitCommand(0), nodeHangCommand()], {
      killOthersOn: ["success"],
      outputStream: sink,
      prefixColors: false,
      kill(pid, signal) {
        calls.push({ pid, signal });
        if (process.platform === "win32") {
          spawnSync("taskkill", ["/pid", String(pid), "/T", "/F"], {
            stdio: "ignore",
          });
          return;
        }
        process.kill(-pid, signal);
      },
    });
    run.result.catch(() => {});

    const events = await run.result.catch((error) => error);
    if (!Array.isArray(events)) {
      throw new Error(`native JS API custom kill policy returned non-events: ${events}`);
    }
    if (calls.length === 0) {
      throw new Error("native JS API custom kill policy did not call kill callback");
    }
    assertEqual(
      calls[0].signal,
      "SIGTERM",
      "native JS API custom kill policy signal"
    );
    console.log("compat ok: native JS API custom kill policy");
  }

  async function runNativeApiExitedCommandKillSmoke() {
    const api = require(resolve("index.js"));
    const sink = createDiscardSink();
    const run = api.concurrently([nodeExitCommand(0), nodeHangCommand()], {
      outputStream: sink,
      prefixColors: false,
    });
    run.result.catch(() => {});

    await waitFor(
      () => api.Command.canKill(run.commands[1]),
      10000,
      "native JS API hanging command did not become killable"
    );
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 5000));
    run.commands[0].kill("SIGTERM");
    run.commands[1].kill("SIGTERM");

    const events = await run.result.then(
      (value) => value,
      (error) => error
    );
    if (!Array.isArray(events)) {
      throw new Error(`native JS API exited-command kill returned non-event rejection: ${events}`);
    }
    const first = events.find((event) => event.index === 0);
    const second = events.find((event) => event.index === 1);
    assertEqual(first?.killed, false, "native JS API exited command stays un-killed");
    assertEqual(second?.killed, true, "native JS API hanging command is killed");
    console.log("compat ok: native JS API exited-command kill no-op");
  }

  async function runNativeApiClosedIpcSendSmoke() {
    const api = require(resolve("index.js"));
    class FakeChild extends EventEmitter {
      constructor() {
        super();
        this.pid = 12345;
        this.stdin = undefined;
        this.stdout = new EventEmitter();
        this.stderr = new EventEmitter();
      }

      send(_message, _handle, _options, callback) {
        callback();
      }
    }

    const child = new FakeChild();
    const command = new api.Command(
      { index: 0, name: "ipc", command: "ipc", ipc: 1 },
      {},
      () => child,
      () => true
    );
    command.start();
    child.emit("close", 0, null);

    await command.send({ closed: true }).then(
      () => {
        throw new Error("native JS API closed IPC send resolved");
      },
      (error) => {
        assertEqual(
          error.message,
          "Command IPC channel is closed",
          "native JS API closed IPC send rejection"
        );
      }
    );
    console.log("compat ok: native JS API closed IPC send rejects");
  }

  async function runNativeApiControllerIndexLabelSmoke() {
    const api = require(resolve("index.js"));
    let output = "";
    const sink = new Writable({
      write(chunk, _encoding, callback) {
        output += chunk.toString();
        callback();
      },
    });
    const run = api.concurrently([
      nodePrintCommand("removed"),
      { command: nodePrintCommand("kept"), name: "two" },
    ], {
      outputStream: sink,
      prefix: "index",
      prefixColors: false,
      controllers: [
        {
          handle(commands) {
            return { commands: [commands[1]] };
          },
        },
      ],
    });
    run.result.catch(() => {});
    const events = await run.result;

    assertEqual(events.length, 1, "native JS API filtered controller event count");
    assertEqual(events[0].index, 1, "native JS API filtered controller event index");
    if (!output.includes("[1] kept")) {
      throw new Error(
        `native JS API filtered controller lost original output label: ${JSON.stringify(output)}`
      );
    }
    if (output.includes("[0] kept")) {
      throw new Error(
        `native JS API filtered controller reused positional output label: ${JSON.stringify(output)}`
      );
    }
    if (output.includes("[two] kept")) {
      throw new Error(
        `native JS API filtered controller used command name for index prefix: ${JSON.stringify(output)}`
      );
    }
    console.log("compat ok: native JS API filtered controller output label");
  }

  async function runNativeApiControllerTemplateIndexAndStringColorSmoke() {
    const api = require(resolve("index.js"));
    let output = "";
    const sink = new Writable({
      write(chunk, _encoding, callback) {
        output += chunk.toString();
        callback();
      },
    });
    const previousForceColor = process.env.FORCE_COLOR;
    process.env.FORCE_COLOR = "1";
    const run = api.concurrently([
      nodePrintCommand("removed"),
      nodePrintCommand("kept"),
    ], {
      outputStream: sink,
      prefix: "cmd-{index}",
      prefixColors: "red,blue",
      controllers: [
        {
          handle(commands) {
            return { commands: [commands[1]] };
          },
        },
      ],
    });
    run.result.catch(() => {});
    restoreEnvironmentValue("FORCE_COLOR", previousForceColor);
    const events = await run.result;
    const plainOutput = stripAnsiColors(output);

    assertEqual(events.length, 1, "native JS API filtered template event count");
    assertEqual(events[0].index, 1, "native JS API filtered template event index");
    if (!plainOutput.includes("cmd-1 kept")) {
      throw new Error(
        `native JS API template prefix lost original index: ${JSON.stringify(output)}`
      );
    }
    if (plainOutput.includes("cmd-0 kept")) {
      throw new Error(
        `native JS API template prefix reused positional index: ${JSON.stringify(output)}`
      );
    }
    if (!output.includes("\u001b[34mcmd-1")) {
      throw new Error(
        `native JS API string prefix colors did not remap to public index: ${JSON.stringify(output)}`
      );
    }
    if (output.includes("\u001b[31mcmd-1")) {
      throw new Error(
        `native JS API string prefix colors used positional color: ${JSON.stringify(output)}`
      );
    }
    console.log("compat ok: native JS API template index and string prefix colors");
  }

  async function runNativeApiControllerIpcSmoke() {
    const api = require(resolve("index.js"));
    const sink = createDiscardSink();
    const childSource =
      'process.on("message",(message)=>{process.send({pong:message.ping});});setTimeout(()=>process.exit(0),100);';
    const ipcCommand = new api.Command(
      {
        index: 0,
        name: "ipc",
        command: "ipc-child",
        ipc: 3,
      },
      {
        cwd: process.cwd(),
        env: process.env,
        shell: false,
        stdio: ["ignore", "pipe", "pipe", "ipc"],
      },
      (_command, options) => spawn(process.execPath, ["-e", childSource], options)
    );

    const run = api.concurrently([nodeExitCommand(0)], {
      raw: true,
      outputStream: sink,
      controllers: [
        {
          handle() {
            return { commands: [ipcCommand] };
          },
        },
      ],
    });
    run.result.catch(() => {});
    const incoming = [];
    run.commands[0].messages.incoming.subscribe({
      next(event) {
        incoming.push(event.message);
      },
    });
    await run.commands[0].send({ ping: 9 });
    const events = await run.result;
    assertEqual(events.length, 1, "native JS API controller IPC close event count");
    assertEqual(events[0].exitCode, 0, "native JS API controller IPC exit code");
    if (!incoming.some((message) => message && message.pong === 9)) {
      throw new Error(`native JS API controller IPC missing response: ${JSON.stringify(incoming)}`);
    }
    console.log("compat ok: native JS API controller IPC");
  }

  async function runNativeApiGlobalRawCommandFalseSmoke() {
    const api = require(resolve("index.js"));
    let output = "";
    const sink = new Writable({
      write(chunk, _encoding, callback) {
        output += chunk.toString();
        callback();
      },
    });
    await api
      .concurrently([{ command: nodePrintCommand("raw-only"), raw: false }], {
        raw: true,
        timings: true,
        outputStream: sink,
        prefixColors: false,
      })
      .result;

    if (!output.includes("[0] raw-only")) {
      throw new Error(
        `native JS API global raw command override stayed raw: ${JSON.stringify(output)}`
      );
    }
    console.log("compat ok: native JS API global raw command false formats output");
  }

  async function runNativeApiCommandAwareLoggerSmoke() {
    const api = require(resolve("index.js"));
    const logTextCommand = nodePrintCommand("log-text");
    const logMethodCommand = nodePrintCommand("log-method");
    const textLoggerRecords = [];
    const textLogger = {
      logCommandText(text, command) {
        textLoggerRecords.push({
          text,
          index: command?.index,
          name: command?.name,
          command: command?.command,
        });
      },
    };

    await api.concurrently([{ name: "api", command: logTextCommand }], {
      logger: textLogger,
      raw: true,
      prefixColors: false,
    }).result;
    if (
      !textLoggerRecords.some(
        (record) =>
          record.text.includes("log-text") &&
          record.index === 0 &&
          record.name === "api" &&
          record.command === logTextCommand
      )
    ) {
      throw new Error(
        `native JS API command-aware logCommandText missing command: ${JSON.stringify(textLoggerRecords)}`
      );
    }

    const logRecords = [];
    const logger = new api.Logger();
    logger.log = function log(prefix, text, command) {
      logRecords.push({
        prefix,
        text,
        index: command?.index,
        name: command?.name,
        command: command?.command,
      });
    };
    await api.concurrently([{ name: "web", command: logMethodCommand }], {
      logger,
      prefixColors: false,
    }).result;
    if (
      !logRecords.some(
        (record) =>
          record.text.includes("log-method") &&
          record.index === 0 &&
          record.name === "web" &&
          record.command === logMethodCommand
      )
    ) {
      throw new Error(
        `native JS API command-aware logger.log missing command: ${JSON.stringify(logRecords)}`
      );
    }
    console.log("compat ok: native JS API command-aware logger callbacks");
  }


  async function runNativeApiDirectOptionsSmoke() {
    const api = require(resolve("index.js"));

    await runNativeApiAdditionalArgumentsAndHideSmoke(api);
    await runNativeApiCwdSmoke(api);
    await runNativeApiPrefixColorSmoke(api);
    await runNativeApiPauseInputStreamSmoke(api);
    await runNativeApiHandleInputChildSmoke();
    await runNativeApiLegacyKillOthersSmoke(api);
    await runNativeApiHighLevelIpcSmoke(api);
    await runNativeApiControllerOnFinishSmoke(api);
    console.log("compat ok: direct native JS API options");
  }

  async function runNativeApiAdditionalArgumentsAndHideSmoke(api) {
    const argumentCommand = nodeEvalCommand(
      "process.stdout.write(process.argv.slice(1).join('|'))"
    );
    const expansionCases = [
      ["{1}", "alpha beta"],
      ["{@}", "alpha beta|gamma"],
      ["{*}", "alpha beta gamma"],
    ];

    for (const [placeholder, expected] of expansionCases) {
      const output = createOutputCapture();
      await api.createConcurrently(
        [
          { name: "visible", command: `${argumentCommand} ${placeholder}` },
          { name: "hidden", command: nodePrintCommand("hidden-secret") },
        ],
        {
          additionalArguments: ["alpha beta", "gamma"],
          hide: ["hidden"],
          outputStream: output.stream,
          prefixColors: false,
          raw: true,
        }
      ).result;

      assertEqual(
        output.read(),
        expected,
        `native JS API additionalArguments ${placeholder} and options.hide`
      );
    }
  }

  async function runNativeApiCwdSmoke(api) {
    const globalCwd = mkdtempSync(resolve(tmpdir(), "concurrently-ml-api-cwd-"));
    const commandCwd = mkdtempSync(
      resolve(tmpdir(), "concurrently-ml-api-command-cwd-")
    );

    try {
      await api.concurrently(
        [
          {
            command: nodeEvalCommand(
              "require('node:fs').writeFileSync('global.marker','1')"
            ),
          },
          {
            command: nodeEvalCommand(
              "require('node:fs').writeFileSync('override.marker','1')"
            ),
            cwd: commandCwd,
          },
        ],
        {
          cwd: globalCwd,
          outputStream: createDiscardSink(),
          prefixColors: false,
          raw: true,
        }
      ).result;

      if (!existsSync(resolve(globalCwd, "global.marker"))) {
        throw new Error("native JS API global cwd did not reach command");
      }
      if (!existsSync(resolve(commandCwd, "override.marker"))) {
        throw new Error("native JS API command cwd did not override global cwd");
      }
      if (existsSync(resolve(globalCwd, "override.marker"))) {
        throw new Error("native JS API command cwd leaked back to global cwd");
      }
    } finally {
      rmSync(globalCwd, { recursive: true, force: true });
      rmSync(commandCwd, { recursive: true, force: true });
    }
  }

  async function runNativeApiPrefixColorSmoke(api) {
    const output = createOutputCapture();
    const previousForceColor = process.env.FORCE_COLOR;
    const previousNoColor = process.env.NO_COLOR;
    process.env.FORCE_COLOR = "1";
    delete process.env.NO_COLOR;

    try {
      await api.concurrently(
        [
          {
            command: nodePrintCommand("prefix-color"),
            name: "paint",
            prefixColor: "red",
          },
        ],
        { outputStream: output.stream }
      ).result;
    } finally {
      restoreEnvironmentValue("FORCE_COLOR", previousForceColor);
      restoreEnvironmentValue("NO_COLOR", previousNoColor);
    }

    if (!output.read().includes("\u001b[31m[paint]\u001b[39m prefix-color")) {
      throw new Error(
        `native JS API command prefixColor was ignored: ${JSON.stringify(output.read())}`
      );
    }
  }

  async function runNativeApiPauseInputStreamSmoke(api) {
    for (const [label, pauseInputStreamOnFinish, expectedFinishPauseCalls] of [
      ["false", false, 0],
      ["default", undefined, 1],
    ]) {
      const input = new PassThrough();
      const pause = input.pause.bind(input);
      const unpipe = input.unpipe.bind(input);
      let unpipeCompleted = false;
      let finishPauseCalls = 0;
      input.unpipe = function unpipeAndRecord(...destinations) {
        const result = unpipe(...destinations);
        unpipeCompleted = true;

        return result;
      };
      input.pause = function pauseAndRecord() {
        if (unpipeCompleted) {
          finishPauseCalls += 1;
        }

        return pause();
      };
      const options = {
        inputStream: input,
        outputStream: createDiscardSink(),
        prefixColors: false,
        raw: true,
      };
      if (pauseInputStreamOnFinish !== undefined) {
        options.pauseInputStreamOnFinish = pauseInputStreamOnFinish;
      }

      try {
        await api.concurrently([nodeExitCommand(0)], options).result;
        assertEqual(
          finishPauseCalls,
          expectedFinishPauseCalls,
          `native JS API pauseInputStreamOnFinish ${label}`
        );
      } finally {
        input.destroy();
      }
    }
  }

  async function runNativeApiHandleInputChildSmoke() {
    const childSource = `
      const api = require(${JSON.stringify(resolve("index.js"))});
      const run = api.concurrently([${JSON.stringify(inputEchoCommand)}], {
        handleInput: true,
        prefixColors: false,
        raw: true,
      });
      process.stdout.write("api-ready\\n");
      run.result.then(
        () => process.stdout.write("api-done\\n"),
        (error) => {
          process.stderr.write(String(error && error.stack ? error.stack : error));
          process.exitCode = 1;
        }
      );
    `;
    const result = await cliCommandRunner.runCommand(
      process.execPath,
      ["-e", childSource],
      {
        inputWrites: [{ afterStdout: "api-ready\n", input: "direct-input\n" }],
        name: "native JS API handleInput child",
        side: "local",
        timeoutMs: 10000,
      }
    );

    assertEqual(
      result.status,
      0,
      `native JS API handleInput child status: ${result.stderr}`
    );
    if (!result.stdout.includes("direct-input") || !result.stdout.includes("api-done")) {
      throw new Error(
        `native JS API handleInput child missed piped input: ${JSON.stringify(result.stdout)}`
      );
    }
  }

  async function runNativeApiLegacyKillOthersSmoke(api) {
    const events = await api.concurrently(
      [nodeDelayPrintCommand("done", 100), nodeHangCommand()],
      {
        killOthers: ["success"],
        outputStream: createDiscardSink(),
        prefixColors: false,
        raw: true,
        successCondition: "first",
      }
    ).result;
    const killedEvent = events.find((event) => event.index === 1);

    assertEqual(events.length, 2, "native JS API legacy killOthers event count");
    assertEqual(killedEvent?.killed, true, "native JS API legacy killOthers alias");
  }

  async function runNativeApiHighLevelIpcSmoke(api) {
    const childSource =
      "process.on('message',message=>process.send({pong:message.ping},()=>process.exit(0)));setTimeout(()=>process.exit(7),3000)";
    const run = api.concurrently(
      [
        {
          command: nodeEvalCommand(childSource),
          ipc: 3,
          name: "ipc",
        },
      ],
      {
        outputStream: createDiscardSink(),
        prefixColors: false,
        raw: true,
      }
    );
    run.result.catch(() => {});
    const incoming = [];
    run.commands[0].messages.incoming.subscribe({
      next(event) {
        incoming.push(event.message);
      },
    });

    await run.commands[0].send({ ping: 17 });
    const events = await run.result;

    assertEqual(events[0]?.exitCode, 0, "native JS API high-level IPC exit code");
    if (!incoming.some((message) => message && message.pong === 17)) {
      throw new Error(
        `native JS API high-level IPC missing response: ${JSON.stringify(incoming)}`
      );
    }
  }

  async function runNativeApiControllerOnFinishSmoke(api) {
    let allowOnFinish;
    const onFinishGate = new Promise((resolveGate) => {
      allowOnFinish = resolveGate;
    });
    let onFinishStarted = false;
    let onFinishCompleted = false;
    let resultSettled = false;
    const result = api.concurrently([nodeExitCommand(0)], {
      controllers: [
        {
          handle(commands) {
            return {
              commands,
              async onFinish() {
                onFinishStarted = true;
                await onFinishGate;
                onFinishCompleted = true;
              },
            };
          },
        },
      ],
      outputStream: createDiscardSink(),
      prefixColors: false,
      raw: true,
    }).result.then((events) => {
      resultSettled = true;

      return events;
    });

    try {
      await waitFor(
        () => onFinishStarted,
        5000,
        "native JS API controller onFinish did not start"
      );
      await new Promise((resolveTurn) => setImmediate(resolveTurn));
      assertEqual(
        resultSettled,
        false,
        "native JS API result settled before controller onFinish"
      );
    } finally {
      allowOnFinish();
    }

    await result;
    assertEqual(
      onFinishCompleted,
      true,
      "native JS API controller async onFinish completion"
    );
  }

}

module.exports = { runNativeApiCore };
