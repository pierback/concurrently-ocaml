"use strict";

const assert = require("node:assert/strict");
const { spawn } = require("node:child_process");
const { PassThrough } = require("node:stream");
const { setTimeout: delay } = require("node:timers/promises");
const test = require("node:test");

const {
  Command,
  InputHandler,
  KillOnSignal,
  KillOthers,
  LogError,
  LogExit,
  LogOutput,
  LogTimings,
  RestartProcess,
  concurrently,
} = require("../lib/api");

function recordCalls(implementation = () => undefined) {
  const calls = [];
  const record = (...args) => {
    calls.push(args);
    return implementation(...args);
  };
  record.calls = calls;
  return record;
}

function createLogger() {
  return {
    logCommandEvent: recordCalls(),
    logCommandText: recordCalls(),
    logGlobalEvent: recordCalls(),
    logTable: recordCalls(),
  };
}

function createCommand(index, name = `command-${index}`) {
  return new Command(
    { index, name, command: `echo ${name}` },
    {},
    () => {
      throw new Error("test command must not be started");
    },
    () => undefined
  );
}

function makeKillable(command, implementation) {
  command.pid = 1000 + command.index;
  command.process = {};
  command.killProcess = () => undefined;
  command.kill = recordCalls(implementation);
  return command.kill;
}

function closeEvent(command, exitCode, durationSeconds = 0) {
  const startDate = new Date(2024, 0, 2, 3, 4, 5, 6);
  const endDate = new Date(startDate.getTime() + durationSeconds * 1000);
  return {
    command,
    index: command.index,
    exitCode,
    killed: false,
    timings: { startDate, endDate, durationSeconds },
  };
}

test("InputHandler routes default, index, name, and colon-containing input", () => {
  const commands = [createCommand(0, "foo"), createCommand(1, "bar")];
  const writes = commands.map(() => recordCalls());
  commands.forEach((command, index) => {
    command.stdin = { write: writes[index] };
  });
  const inputStream = new PassThrough();
  const logger = createLogger();
  const controller = new InputHandler({
    defaultInputTarget: 0,
    inputStream,
    logger,
  });

  const handled = controller.handle(commands);
  assert.strictEqual(handled.commands, commands);
  inputStream.write("default");
  inputStream.write("1:some:thing");
  inputStream.write("bar:named");
  inputStream.write("missing:value");

  assert.deepEqual(writes[0].calls, [["default"], ["missing:value"]]);
  assert.deepEqual(writes[1].calls, [["some:thing"], ["named"]]);
  assert.deepEqual(logger.logGlobalEvent.calls, []);

  handled.onFinish();
  handled.onFinish();
  inputStream.emit("data", Buffer.from("after-finish"));
  assert.deepEqual(writes[0].calls, [["default"], ["missing:value"]]);
});

test("InputHandler reports missing stdin and honors pauseInputStreamOnFinish", () => {
  const command = createCommand(0, "foo");
  const logger = createLogger();
  const inputStream = new PassThrough();
  const pause = recordCalls();
  inputStream.pause = pause;
  const handled = new InputHandler({ inputStream, logger }).handle([command]);

  inputStream.write("input");
  assert.deepEqual(logger.logGlobalEvent.calls, [
    ['Unable to find command "0", or it has no stdin open\n'],
  ]);
  handled.onFinish();
  assert.equal(pause.calls.length, 1);

  const flowingStream = new PassThrough();
  const flowingPause = recordCalls();
  flowingStream.pause = flowingPause;
  const noPause = new InputHandler({
    inputStream: flowingStream,
    logger,
    pauseInputStreamOnFinish: false,
  }).handle([command]);
  noPause.onFinish();
  assert.equal(flowingPause.calls.length, 0);

  assert.deepEqual(new InputHandler({ logger }).handle([command]), {
    commands: [command],
  });
});

test("KillOthers kills matching live commands, aborts, and cleans subscriptions", () => {
  const commands = [createCommand(0), createCommand(1)];
  const killed = makeKillable(commands[1]);
  const logger = createLogger();
  const abortController = new AbortController();
  const handled = new KillOthers({
    logger,
    abortController,
    conditions: "success",
  }).handle(commands);

  commands[0].close.next(closeEvent(commands[0], 0));
  assert.equal(abortController.signal.aborted, true);
  assert.deepEqual(logger.logGlobalEvent.calls, [
    ["Sending SIGTERM to other processes.."],
  ]);
  assert.deepEqual(killed.calls, [[undefined]]);

  handled.onFinish();
  commands[0].close.next(closeEvent(commands[0], 0));
  assert.deepEqual(killed.calls, [[undefined]]);
});

test("KillOthers ignores invalid or non-matching conditions", () => {
  const commands = [createCommand(0), createCommand(1)];
  const killed = makeKillable(commands[1]);
  const logger = createLogger();
  const abortController = new AbortController();
  const handled = new KillOthers({
    logger,
    abortController,
    conditions: ["failure", "unknown"],
    killSignal: "SIGKILL",
  }).handle(commands);

  commands[0].close.next(closeEvent(commands[0], 0));
  assert.equal(abortController.signal.aborted, false);
  assert.deepEqual(killed.calls, []);
  handled.onFinish();

  assert.deepEqual(
    new KillOthers({ logger, conditions: ["unknown"] }).handle(commands),
    { commands }
  );
});

test("KillOthers force-kills only processes still alive after the timeout", async () => {
  const commands = [createCommand(0), createCommand(1), createCommand(2)];
  const stillAlive = makeKillable(commands[1]);
  const exitedOnTerm = makeKillable(commands[2], () => {
    commands[2].process = undefined;
    commands[2].pid = undefined;
  });
  const logger = createLogger();
  const handled = new KillOthers({
    logger,
    conditions: "failure",
    timeoutMs: 5,
  }).handle(commands);

  commands[0].close.next(closeEvent(commands[0], 1));
  await delay(20);

  assert.deepEqual(stillAlive.calls, [[undefined], ["SIGKILL"]]);
  assert.deepEqual(exitedOnTerm.calls, [[undefined]]);
  assert.deepEqual(logger.logGlobalEvent.calls, [
    ["Sending SIGTERM to other processes.."],
    ["Sending SIGKILL to 1 processes.."],
  ]);
  handled.onFinish();
});

test("KillOthers onFinish cancels a pending force-kill timer", async () => {
  const commands = [createCommand(0), createCommand(1)];
  const killed = makeKillable(commands[1]);
  const handled = new KillOthers({
    logger: createLogger(),
    conditions: "failure",
    timeoutMs: 10,
  }).handle(commands);

  commands[0].close.next(closeEvent(commands[0], 1));
  handled.onFinish();
  await delay(25);
  assert.deepEqual(killed.calls, [[undefined]]);
});

test("controllers observe live child output through the spawn backend", async () => {
  const logger = createLogger();
  const outputStream = new PassThrough();
  const run = concurrently(["emit"], {
    controllers: [new LogOutput({ logger })],
    outputStream,
    raw: true,
    spawn() {
      return spawn(process.execPath, ["-e", "process.stdout.write('hello')"], {
        stdio: ["pipe", "pipe", "pipe"],
      });
    },
  });

  await run.result;
  assert.equal(logger.logCommandText.calls.length, 1);
  assert.equal(logger.logCommandText.calls[0][0], "hello");
  assert.strictEqual(logger.logCommandText.calls[0][1], run.commands[0]);
});

test("KillOthers stops live siblings and prevents queued commands from spawning", async () => {
  const spawnedCommands = [];
  const abortController = new AbortController();
  const outputStream = new PassThrough();
  const startedAt = Date.now();
  const run = concurrently(["fast", "slow", "queued"], {
    controllers: [
      new KillOthers({
        abortController,
        conditions: "failure",
        logger: createLogger(),
      }),
    ],
    maxProcesses: 2,
    outputStream,
    raw: true,
    spawn(command) {
      spawnedCommands.push(command);
      const script =
        command === "fast"
          ? "setTimeout(() => process.exit(1), 20)"
          : "setTimeout(() => process.exit(0), 800)";
      return spawn(process.execPath, ["-e", script], {
        detached: process.platform !== "win32",
        stdio: ["pipe", "pipe", "pipe"],
      });
    },
    kill(pid, signal) {
      try {
        process.kill(pid, signal ?? "SIGTERM");
      } catch (error) {
        if (error?.code !== "ESRCH") {
          throw error;
        }
      }
    },
  });

  const closeEvents = await run.result.then(
    () => assert.fail("the failing command must reject the run"),
    (events) => events
  );
  assert.deepEqual(spawnedCommands, ["fast", "slow"]);
  assert.equal(abortController.signal.aborted, true);
  assert.ok(Date.now() - startedAt < 700);
  assert.equal(closeEvents.length, 2);
});

test("LogError renders strings, stacks, and stackless errors, then unsubscribes", () => {
  const commands = [createCommand(0), createCommand(1), createCommand(2)];
  const logger = createLogger();
  const handled = new LogError({ logger }).handle(commands);
  const withStack = new Error("with stack");
  const withoutStack = new Error("without stack");
  withoutStack.stack = "";

  commands[0].error.next("plain error");
  commands[1].error.next(withStack);
  commands[2].error.next(withoutStack);

  assert.deepEqual(logger.logCommandEvent.calls, [
    [`Error occurred when executing command: ${commands[0].command}`, commands[0]],
    ["plain error", commands[0]],
    [`Error occurred when executing command: ${commands[1].command}`, commands[1]],
    [withStack.stack, commands[1]],
    [`Error occurred when executing command: ${commands[2].command}`, commands[2]],
    [String(withoutStack), commands[2]],
  ]);

  handled.onFinish();
  commands[0].error.next("late error");
  assert.equal(logger.logCommandEvent.calls.length, 6);
});

test("LogExit and LogOutput observe command streams and clean up on finish", () => {
  const commands = [createCommand(0), createCommand(1)];
  const logger = createLogger();
  const exits = new LogExit({ logger }).handle(commands);
  const output = new LogOutput({ logger }).handle(commands);

  commands[0].stdout.next(Buffer.from("stdout"));
  commands[1].stderr.next(Buffer.from("stderr"));
  commands[0].close.next(closeEvent(commands[0], 0));
  commands[1].close.next(closeEvent(commands[1], "SIGTERM"));

  assert.deepEqual(logger.logCommandText.calls, [
    ["stdout", commands[0]],
    ["stderr", commands[1]],
  ]);
  assert.deepEqual(logger.logCommandEvent.calls, [
    [`${commands[0].command} exited with code 0`, commands[0]],
    [`${commands[1].command} exited with code SIGTERM`, commands[1]],
  ]);

  exits.onFinish();
  output.onFinish();
  commands[0].stdout.next(Buffer.from("late"));
  commands[0].close.next(closeEvent(commands[0], 2));
  assert.equal(logger.logCommandText.calls.length, 2);
  assert.equal(logger.logCommandEvent.calls.length, 2);
});

test("LogTimings logs process events and a sorted summary on finish", () => {
  const commands = [createCommand(0, "short"), createCommand(1, "long")];
  const logger = createLogger();
  const handled = new LogTimings({ logger }).handle(commands);
  const short = closeEvent(commands[0], 0, 3);
  const long = closeEvent(commands[1], 1, 5);

  commands[0].timer.next({ startDate: short.timings.startDate });
  commands[0].timer.next(short.timings);
  commands[1].timer.next({ startDate: long.timings.startDate });
  commands[1].timer.next(long.timings);
  commands[0].close.next(short);
  commands[1].close.next(long);
  commands[0].close.next(short);

  assert.deepEqual(logger.logCommandEvent.calls, [
    [`${commands[0].command} started at 2024-01-02 03:04:05.006`, commands[0]],
    [`${commands[0].command} stopped at 2024-01-02 03:04:08.006 after ${
      (3000).toLocaleString()
    }ms`, commands[0]],
    [`${commands[1].command} started at 2024-01-02 03:04:05.006`, commands[1]],
    [`${commands[1].command} stopped at 2024-01-02 03:04:10.006 after ${
      (5000).toLocaleString()
    }ms`, commands[1]],
  ]);
  assert.deepEqual(logger.logGlobalEvent.calls, []);

  handled.onFinish();
  handled.onFinish();
  assert.deepEqual(logger.logGlobalEvent.calls, [["Timings:"]]);
  assert.deepEqual(logger.logTable.calls, [
    [
      [
        LogTimings.mapCloseEventToTimingInfo(long),
        LogTimings.mapCloseEventToTimingInfo(short),
      ],
    ],
  ]);

  commands[0].timer.next({ startDate: short.timings.startDate });
  assert.equal(logger.logCommandEvent.calls.length, 4);
});

test("LogTimings omits incomplete summaries and is a no-op without a logger", () => {
  const commands = [createCommand(0), createCommand(1)];
  const logger = createLogger();
  const handled = new LogTimings({ logger }).handle(commands);

  commands[0].close.next(closeEvent(commands[0], 0, 1));
  commands[1].error.next(new Error("spawn failed"));
  handled.onFinish();
  commands[1].close.next(closeEvent(commands[1], 1, 1));
  assert.deepEqual(logger.logGlobalEvent.calls, []);
  assert.deepEqual(logger.logTable.calls, []);

  assert.deepEqual(new LogTimings({}).handle(commands), { commands });
});

test("scheduler-dependent controllers fail explicitly instead of passing through", () => {
  const commands = [createCommand(0)];
  assert.throws(
    () => new KillOnSignal({ process }).handle(commands),
    /KillOnSignal is not supported by the current scheduler/
  );

  const noRestart = new RestartProcess({ tries: 0 });
  assert.deepEqual(noRestart.handle(commands), { commands });

  const restart = new RestartProcess({ tries: -1 });
  assert.equal(restart.tries, Infinity);
  assert.throws(
    () => restart.handle(commands),
    /RestartProcess is not supported by the current scheduler/
  );
});

test("controller setup failures clean up earlier controllers", () => {
  const cleanup = recordCalls();
  assert.throws(
    () =>
      concurrently(["unused"], {
        controllers: [
          {
            handle(commands) {
              return { commands, onFinish: cleanup };
            },
          },
          {
            handle() {
              throw new Error("controller setup failed");
            },
          },
        ],
      }),
    /controller setup failed/
  );
  assert.equal(cleanup.calls.length, 1);
});
