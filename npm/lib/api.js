"use strict";

const {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} = require("node:fs");
const { cpus, tmpdir } = require("node:os");
const { join, resolve } = require("node:path");
const { Writable } = require("node:stream");
const { StringDecoder } = require("node:string_decoder");
const {
  spawn: spawnChildProcess,
  spawnSync,
} = require("node:child_process");
const { runNative } = require("./native");

const SHORTCUT_RUNNERS = new Set(["npm", "yarn", "pnpm", "bun", "node", "deno"]);
const SIGNALS = ["SIGINT", "SIGTERM", "SIGHUP"];
const SIGNAL_VALIDATION_PID = 2147483647;
const AUTO_PREFIX_COLORS = [
  "cyan",
  "yellow",
  "greenBright",
  "blueBright",
  "magentaBright",
  "white",
  "grey",
  "red",
  "bgCyan",
  "bgYellow",
  "bgGreenBright",
  "bgBlueBright",
  "bgMagenta",
  "bgWhiteBright",
  "bgGrey",
  "bgRed",
];

class NativeApiUnsupportedError extends Error {
  constructor(feature) {
    super(`${feature} is not supported by the native concurrently-ml JavaScript facade`);
    this.name = "NativeApiUnsupportedError";
  }
}

class SimpleSubject {
  constructor() {
    this.subscribers = new Set();
  }

  subscribe(observer) {
    const subscriber = observerSubscriber(observer);
    this.subscribers.add(subscriber);
    return {
      unsubscribe: () => {
        this.subscribers.delete(subscriber);
      },
    };
  }

  next(value) {
    let accepted = true;
    for (const subscriber of [...this.subscribers]) {
      if (subscriber(value) === false) {
        accepted = false;
      }
    }
    return accepted;
  }

  complete() {
    this.subscribers.clear();
  }

  pipe() {
    return this;
  }
}

class SimpleReplaySubject extends SimpleSubject {
  constructor() {
    super();
    this.values = [];
  }

  subscribe(observer) {
    const subscription = super.subscribe(observer);
    const subscriber = observerSubscriber(observer);
    for (const value of this.values) {
      subscriber(value);
    }
    return subscription;
  }

  next(value) {
    this.values.push(value);
    super.next(value);
  }
}

class Command {
  constructor(info = {}, spawnOpts, spawn, killProcess) {
    this.index = numberOrDefault(info.index, 0);
    this.name = stringOrDefault(info.name, String(this.index));
    this.command = stringOrDefault(info.command, "");
    this.prefixColor = info.prefixColor;
    this.env = normalizeEnv(info.env);
    this.cwd = info.cwd;
    this.ipc = info.ipc;
    this.raw = info.raw;
    this.hidden = Boolean(info.hidden);
    this.killed = false;
    this.exited = false;
    this.state = "stopped";
    this.pid = undefined;
    this.stdin = undefined;
    this.killSignal = undefined;
    this.killExitSignal = undefined;
    this.killProcess = undefined;
    this.killBeforePid = false;
    this.startedAt = undefined;
    this.close = new SimpleSubject();
    this.error = new SimpleSubject();
    this.stdout = new SimpleSubject();
    this.stderr = new SimpleSubject();
    this.timer = new SimpleSubject();
    this.stateChange = new SimpleSubject();
    this.messages = {
      incoming: new SimpleSubject(),
      outgoing: new SimpleReplaySubject(),
    };
    this.process = undefined;
    this.spawn = spawn;
    this.spawnOpts = spawnOpts;
    this.runId = 0;
    this.spawnApiCompleted = false;
    this.killProcess =
      typeof killProcess === "function"
        ? (code) => killProcess(this.pid, code)
        : undefined;
    this.subscriptions = [];
  }

  start() {
    if (typeof this.spawn !== "function") {
      throw new NativeApiUnsupportedError("Command.start()");
    }
    this.runId += 1;
    const runId = this.runId;
    this.spawnApiCompleted = false;
    const child = this.spawn(this.command, this.spawnOpts);
    this.process = child;
    this.pid = child.pid;
    this.changeState("started");
    const startDate = new Date();
    const highResStartTime = process.hrtime();
    this.timer.next({ startDate });
    this.subscriptions = this.setupIpc(child);
    child.on?.("error", (error) => {
      if (this.runId !== runId) {
        return;
      }
      this.cleanup();
      const endDate = new Date();
      this.timer.next({ startDate, endDate });
      this.error.next(error);
      this.changeState("errored");
    });
    child.on?.("close", (exitCode, signal) => {
      if (this.runId !== runId) {
        return;
      }
      this.cleanup();
      this.exited = true;
      if (this.state !== "errored") {
        this.changeState("exited");
      }
      const endDate = new Date();
      const [seconds, nanoseconds] = process.hrtime(highResStartTime);
      const closeEvent = {
        command: this,
        index: this.index,
        exitCode:
          process.platform === "win32" &&
          this.killed &&
          (this.killExitSignal || this.killSignal)
            ? this.killExitSignal || this.killSignal
            : exitCode ?? String(signal),
        killed: this.killed,
        timings: {
          startDate,
          endDate,
          durationSeconds: seconds + nanoseconds / 1e9,
        },
      };
      this.timer.next({ startDate, endDate });
      (this.spawnApiClose ?? this.close).next(closeEvent);
    });
    child.stdout?.on?.("data", (chunk) => this.stdout.next(chunk));
    child.stderr?.on?.("data", (chunk) => this.stderr.next(chunk));
    this.stdin = child.stdin || undefined;
    this.stdin?.on?.("error", () => {});
  }

  changeState(state) {
    this.state = state;
    this.stateChange.next(state);
  }

  setupIpc(child) {
    if (!this.ipc) {
      return [];
    }
    const onMessage = (message, handle) => {
      this.messages.incoming.next({ message, handle });
    };
    child.on?.("message", onMessage);
    const outgoing = this.messages.outgoing.subscribe((event) => {
      if (typeof child.send !== "function") {
        event.onSent(new Error("Command does not have an IPC channel"));
        return;
      }
      child.send(event.message, event.handle, event.options, (error) => {
        event.onSent(error);
      });
    });
    return [
      {
        unsubscribe() {
          child.off?.("message", onMessage);
        },
      },
      outgoing,
    ];
  }

  send(message, handle, options) {
    if (this.ipc == null) {
      throw new Error("Command IPC is disabled");
    }
    if (this.state !== "stopped" && this.process === undefined) {
      return Promise.reject(new Error("Command IPC channel is closed"));
    }
    return new Promise((resolve, reject) => {
      this.messages.outgoing.next({
        message,
        handle,
        options,
        onSent(error) {
          if (error) {
            reject(error);
          } else {
            resolve();
          }
        },
      });
    });
  }

  kill(code = "SIGTERM") {
    if (!commandCanRequestKill(this)) {
      return;
    }
    const killed = this.killProcess(code);
    if (killed !== false) {
      this.killed = true;
      this.killSignal = code;
      this.killExitSignal = typeof killed === "string" ? killed : undefined;
    }
  }

  cleanup() {
    for (const subscription of this.subscriptions) {
      subscription.unsubscribe();
    }
    this.subscriptions = [];
    this.messages.outgoing = new SimpleReplaySubject();
    this.process = undefined;
    this.stdin = undefined;
  }

  static canKill(command) {
    return Boolean(
      command &&
        !command.exited &&
        command.process &&
        typeof command.killProcess === "function" &&
        Number.isInteger(command.pid)
    );
  }
}

function commandCanRequestKill(command) {
  return Boolean(
    command &&
      !command.exited &&
      command.process &&
      typeof command.killProcess === "function" &&
      (Number.isInteger(command.pid) || command.killBeforePid)
  );
}

class Logger {
  constructor(options = {}) {
    this.options = options;
  }

  toggleColors() {}
  setPrefixLength() {}
  getPrefixContent() {
    return undefined;
  }
  getPrefix() {
    return "";
  }
  colorText(_command, text) {
    return text;
  }
  logCommandEvent() {}
  logCommandText(text) {
    this.log("", text);
  }
  logGlobalEvent(text) {
    this.log("", text);
  }
  logTable(rows) {
    this.log("", `${JSON.stringify(rows)}\n`);
  }
  log(prefix, text) {
    const stream = this.options.outputStream ?? process.stdout;
    stream.write(`${prefix}${text}`);
  }
  emit() {}
}

class PassThroughController {
  handle(commands) {
    return { commands };
  }
}

class InputHandler extends PassThroughController {}
class KillOnSignal extends PassThroughController {}
class KillOthers extends PassThroughController {}
class LogError extends PassThroughController {}
class LogExit extends PassThroughController {}
class LogOutput extends PassThroughController {}
class RestartProcess extends PassThroughController {}

class LogTimings extends PassThroughController {
  static mapCloseEventToTimingInfo({ command, timings, killed, exitCode }) {
    return {
      name: command.name ?? String(command.index),
      duration: String(
        new Date(timings.endDate).getTime() -
          new Date(timings.startDate).getTime()
      ),
      "exit code": exitCode,
      killed,
      command: command.command,
    };
  }
}

function concurrently(commandInputs, options = {}) {
  assertCommandInputs(commandInputs);
  if (commandInputs.length === 0) {
    throw new Error("[concurrently] no commands provided");
  }
  assertNativeOptions(options);

  const commands = expandShortcutCommands(normalizeCommands(commandInputs), options);
  expandAdditionalArguments(commands, options.additionalArguments);
  const controlled = applyControllers(commands, options.controllers);
  const controlledCommands = controlled.commands;
  if (
    controlledCommands.length === 0 &&
    arrayOption(options.teardown).length === 0
  ) {
    return {
      commands: controlledCommands,
      result: runOnFinishCallbacks(Promise.resolve([]), controlled.onFinishCallbacks),
    };
  }
  if (options.spawn !== undefined) {
    return runSpawnApi(controlledCommands, controlled.onFinishCallbacks, options);
  }
  const eventDir = mkdtempSync(join(tmpdir(), "concurrently-ml-api-"));
  let cleanedEventDir = false;
  const cleanupEventDir = () => {
    if (!cleanedEventDir) {
      cleanedEventDir = true;
      rmSync(eventDir, { recursive: true, force: true });
    }
  };

  let invocation;
  let child;
  let startedAt;
  try {
    invocation = nativeInvocation(controlledCommands, options, eventDir);
    startedAt = new Date();
    child = runNative(invocation.args, {
      cwd: invocation.cwd,
      env: invocation.env,
      stdio: invocation.stdio,
    });
  } catch (error) {
    cleanupEventDir();
    throw error;
  }

  const customKill = options.kill;
  const nativeKillPolicy = nativeKillPolicyMayStopCommands(options);
  controlledCommands.forEach((command, position) => {
    command.process = child;
    command.killBeforePid = !customKill;
    command.killProcess = (code) => {
      if (
        command.exited ||
        existsSync(eventPath(eventDir, command.index)) ||
        (customKill && !Number.isInteger(command.pid)) ||
        (command.startedAt &&
          Number.isInteger(command.pid) &&
          !commandProcessExists(command.pid, nativeKillPolicy))
      ) {
        return false;
      }
      if (customKill) {
        customKill(command.pid, code);
      } else {
        writeFileSync(invocation.killPaths[position], JSON.stringify(code), {
          mode: 0o600,
        });
      }
      command.killed = true;
      command.killSignal = code;
      return true;
    };
  });
  if (controlledCommands.length === 1) {
    controlledCommands[0].stdin = child.stdin;
  }

  const startPoll = setInterval(
    () => markStartedCommands(controlledCommands, eventDir, startedAt),
    20
  );
  startPoll.unref?.();
  const waitForOutput = attachStreams(child, options);
  const finishInput = attachInput(child, options);

  const result = new Promise((resolve, reject) => {
    child.on("error", (error) => {
      clearInterval(startPoll);
      finishInput();
      waitForOutput().then(
        () => {
          cleanupEventDir();
          reject(error);
        },
        () => {
          cleanupEventDir();
          reject(error);
        }
      );
    });
    child.on("exit", () => {
      finishInput();
    });
    child.on("close", (code, signal) => {
      clearInterval(startPoll);
      finishInput();
      const endedAt = new Date();
      const exitCode = signal ?? (code ?? 1);
      markStartedCommands(controlledCommands, eventDir, startedAt);
      const events = readCommandEvents({
        commands: controlledCommands,
        endedAt,
        eventDir,
        runExitCode: exitCode,
        runKilled: Boolean(signal),
        runKillSignal: options.killSignal ?? "SIGTERM",
        startedAt,
        missingEventIsKilled: invocation.missingEventIsKilled,
      });
      waitForOutput().then(
        () => {
          cleanupEventDir();
          if (closeEventsSucceeded(events, options.successCondition)) {
            resolve(events);
          } else {
            reject(events);
          }
        },
        (error) => {
          cleanupEventDir();
          reject(error);
        }
      );
    });
  });

  return {
    commands: controlledCommands,
    result: runOnFinishCallbacks(result, controlled.onFinishCallbacks),
  };
}

function createConcurrently(commandInputs, options) {
  return concurrently(commandInputs, options);
}

function assertCommandInputs(commandInputs) {
  if (!Array.isArray(commandInputs)) {
    throw new Error("[concurrently] commands should be an array");
  }
}

function assertNativeOptions(options) {
  if (options.spawn !== undefined && typeof options.spawn !== "function") {
    throw new Error("options.spawn must be a function");
  }
  if (
    options.outputStream !== undefined &&
    !(options.outputStream instanceof Writable)
  ) {
    throw new Error("options.outputStream must be a writable stream");
  }
  if (options.logger !== undefined) {
    assertNativeLogger(options.logger);
  }
  if (options.kill !== undefined && typeof options.kill !== "function") {
    throw new Error("options.kill must be a function");
  }
  if (options.kill !== undefined && nativeKillPolicyMayStopCommands(options)) {
    throw new NativeApiUnsupportedError(
      "options.kill with options.killOthers/killOthersOn"
    );
  }
}

function assertNativeLogger(logger) {
  if (
    typeof logger.logCommandText !== "function" &&
    typeof logger.log !== "function"
  ) {
    throw new Error(
      "options.logger must implement logCommandText(text) or log(prefix, text)"
    );
  }
  if (
    typeof logger.logCommandText === "function" &&
    logger.logCommandText.length > 1
  ) {
    throw new Error(
      "options.logger logCommandText(text, command) is unsupported by the native merged output stream"
    );
  }
  if (typeof logger.log === "function" && logger.log.length > 2) {
    throw new Error(
      "options.logger log(prefix, text, command) is unsupported by the native merged output stream"
    );
  }
}

function runSpawnApi(commands, onFinishCallbacks, options) {
  if (arrayOption(options.teardown).length > 0) {
    throw new NativeApiUnsupportedError("options.teardown with options.spawn");
  }
  const output = spawnApiOutput(spawnApiOutputSink(options));
  const closeEvents = [];
  const hiddenPositions = new Set(hiddenCommands(commands, options));
  const outputState = spawnApiOutputState(commands, options);
  const running = new Set();
  const scheduler = {
    settled: false,
    stopStarting: false,
    timers: new Set(),
    killTimers: new Set(),
    restartTimers: new Map(),
    pendingFailure: undefined,
    settle: undefined,
  };
  const restartCounts = new Map();
  let nextIndex = 0;
  const maxProcesses = spawnApiMaxProcesses(options.maxProcesses, commands.length);
  const input = spawnApiAttachInput(commands, options, outputState, output);
  const signals = spawnApiAttachSignals(commands, running, scheduler, options);
  const restartLimit = spawnApiRestartLimit(options.restartTries);
  const restartDelay = (command) =>
    spawnApiRestartDelay(options.restartDelay, restartCounts.get(command) ?? 1);

  const result = new Promise((resolve, reject) => {
    const fail = (error) => {
      if (scheduler.settled) {
        return;
      }
      scheduler.settled = true;
      scheduler.stopStarting = true;
      spawnApiClearTimers(scheduler);
      signals.finish();
      input.finish();
      spawnApiFlushGroupedOutput(outputState, output);
      output.finish().then(
        () => reject(error),
        () => reject(error)
      );
    };
    const settle = () => {
      if (
        scheduler.settled ||
        running.size !== 0 ||
        (!scheduler.stopStarting && nextIndex < commands.length)
      ) {
        return;
      }
      scheduler.settled = true;
      spawnApiClearTimers(scheduler);
      signals.finish();
      input.finish();
      spawnApiFlushGroupedOutput(outputState, output);
      spawnApiWriteTimings(closeEvents, options, output);
      output.finish().then(
        () => {
          if (closeEventsSucceeded(closeEvents, options.successCondition)) {
            resolve(closeEvents);
          } else {
            reject(closeEvents);
          }
        },
        (error) => reject(error)
      );
    };
    scheduler.settle = settle;
    const startNext = () => {
      while (
        !scheduler.settled &&
        !scheduler.stopStarting &&
        running.size < maxProcesses &&
        nextIndex < commands.length
      ) {
        const position = nextIndex;
        const command = commands[position];
        nextIndex += 1;
        running.add(command);
        subscribeSpawnApiCommand(command, {
          closeEvents,
          hidden: hiddenPositions.has(String(position)),
          output,
          outputState,
          fail,
          restartCounts,
          restartDelay,
          restartLimit,
          running,
          scheduler,
          input,
          settle,
          startNext,
          options,
        });
        try {
          command.start();
          input.flush(command);
        } catch (error) {
          scheduler.stopStarting = true;
          running.delete(command);
          spawnApiCancelRestartTimers(scheduler, running);
          try {
            spawnApiKillOthers(running, options, scheduler);
          } catch (killError) {
            fail(killError);
            return;
          }
          if (running.size !== 0) {
            scheduler.pendingFailure = error;
            return;
          }
          fail(error);
          return;
        }
      }
      settle();
    };
    startNext();
  });

  return {
    commands,
    result: runOnFinishCallbacks(result, onFinishCallbacks),
  };
}

function subscribeSpawnApiCommand(command, state) {
  const {
    closeEvents,
    hidden,
    output,
    outputState,
    fail,
    restartCounts,
    restartDelay,
    restartLimit,
    running,
    scheduler,
    input,
    settle,
    startNext,
    options,
  } = state;
  const formatter = spawnApiOutputFormatter(command, options, output, outputState);
  command.spawnApiClose = new SimpleSubject();
  if (!hidden) {
    command.stdout.subscribe((chunk) => formatter.stdout(chunk));
    command.stderr.subscribe((chunk) => formatter.stderr(chunk));
  }
  if (options.timings && !options.raw && !hidden) {
    command.timer.subscribe((event) => {
      if (!event.startDate) {
        return;
      }
      if (event.endDate) {
        formatter.event(
          `${command.command} stopped at ${spawnApiFormatDate(
            event.endDate,
            options.timestampFormat
          )} after ${event.endDate.getTime() - event.startDate.getTime()}ms\n`
        );
      } else {
        formatter.event(
          `${command.command} started at ${spawnApiFormatDate(
            event.startDate,
            options.timestampFormat
          )}\n`
        );
      }
    });
  }
  const completeCommand = (event) => {
    if (command.spawnApiCompleted) {
      return;
    }
    command.spawnApiCompleted = true;
    if (!hidden) {
      formatter.close(event);
    }
    if (
      spawnApiShouldRestart(
        event,
        command,
        restartCounts,
        restartLimit,
        scheduler
      )
    ) {
      spawnApiRestartCommand(command, {
        input,
        options,
        output,
        outputState,
        restartFormatter: hidden ? undefined : formatter,
        restartDelay,
        running,
        scheduler,
        fail,
        settle,
        startNext,
      });
      return;
    }
    if (scheduler.caughtSignal === "SIGINT") {
      event.exitCode = 0;
    }
    running.delete(command);
    spawnApiFlushClosedGroups(command, outputState, output);
    if (scheduler.pendingFailure) {
      if (running.size === 0) {
        fail(scheduler.pendingFailure);
      }
      return;
    }
    if (
      !spawnApiShouldPublishCloseEvent(
        event,
        command,
        restartCounts,
        restartLimit,
        scheduler
      )
    ) {
      startNext();
      settle();
      return;
    }
    const publicEvent = spawnApiPublicCloseEvent(event);
    command.close.next(publicEvent);
    closeEvents.push(publicEvent);
    if (spawnApiShouldKillOthers(publicEvent, options)) {
      scheduler.stopStarting = true;
      try {
        spawnApiKillOthers(running, options, scheduler, undefined, output, outputState);
      } catch (error) {
        fail(error);
        return;
      }
    }
    startNext();
    settle();
  };
  command.spawnApiClose.subscribe(completeCommand);
  command.error.subscribe((error) => {
    const runId = command.runId;
    setImmediate(() => {
      if (command.runId === runId && !command.spawnApiCompleted) {
        completeCommand(spawnApiErrorCloseEvent(command, error));
      }
    });
  });
  command.spawn = options.spawn;
  command.spawnOpts = spawnApiOptions(command, options, hidden);
  command.killProcess = (signal) => spawnApiKillProcess(command, options, signal);
}

function spawnApiOutputSink(options) {
  return apiOutputSink(options) ?? {
    write(chunk, callback) {
      process.stdout.write(chunk, callback);
    },
  };
}

function spawnApiOutput(outputSink) {
  return outputWriter(outputSink);
}

function outputWriter(outputSink) {
  let pendingWrites = 0;
  let outputError;
  let ended = false;
  const waiters = [];
  const settleWaiters = () => {
    if (pendingWrites !== 0) {
      return;
    }
    while (waiters.length > 0) {
      const waiter = waiters.shift();
      if (outputError) {
        waiter.reject(outputError);
      } else {
        waiter.resolve();
      }
    }
  };
  return {
    write(chunk) {
      if (!outputSink) {
        return;
      }
      pendingWrites += 1;
      try {
        outputSink.write(chunk, (error) => {
          if (error && !outputError) {
            outputError = error;
          }
          pendingWrites -= 1;
          settleWaiters();
        });
      } catch (error) {
        if (!outputError) {
          outputError = error;
        }
        pendingWrites -= 1;
        settleWaiters();
      }
    },
    finish() {
      if (!ended) {
        ended = true;
        try {
          outputSink?.end?.();
        } catch (error) {
          if (!outputError) {
            outputError = error;
          }
        }
      }
      if (pendingWrites === 0) {
        return outputError ? Promise.reject(outputError) : Promise.resolve();
      }
      return new Promise((resolve, reject) => {
        waiters.push({ resolve, reject });
      });
    },
  };
}

function spawnApiOutputState(commands, options) {
  return {
    activeGroupPosition: 0,
    groupBuffers: options.group
      ? new Map(commands.map((command) => [command, []]))
      : undefined,
    groupLineStates: options.group ? new Map() : undefined,
    groupPositions: options.group
      ? new Map(commands.map((command, position) => [command, position]))
      : undefined,
    autoColorPositions: new Map(commands.map((command, position) => [command, position])),
    prefixColors: spawnApiPrefixColorsForCommands(commands, options.prefixColors),
    pendingRestarts: options.group ? new Set() : undefined,
    raw: Boolean(options.raw),
    lastWriteChar: undefined,
    lastWriteCommand: undefined,
    orderedCommands: commands,
    prefixLength: options.padPrefix
      ? commands.reduce((length, command) => {
          const content = spawnApiPrefixContent(command, options);
          return Math.max(length, content?.value.length ?? 0);
        }, 0)
      : 0,
  };
}

function spawnApiOutputFormatter(command, options, output, outputState) {
  const raw = typeof command.raw === "boolean" ? command.raw : Boolean(options.raw);
  if (raw) {
    return {
      stdout(chunk) {
        spawnApiWriteOutput(command, chunk, outputState, output, false);
      },
      stderr(chunk) {
        if (apiCapturesOutput(options)) {
          spawnApiWriteOutput(command, chunk, outputState, output, false);
          return;
        }
        process.stderr.write(chunk);
      },
      event() {},
      close() {},
    };
  }
  const stdoutDecoder = new StringDecoder("utf8");
  const stderrDecoder = new StringDecoder("utf8");
  const writeText = (text) => {
    if (text === "") {
      return;
    }
    spawnApiLogCommandText(command, text, options, outputState, output);
  };
  return {
    stdout(chunk) {
      writeText(Buffer.isBuffer(chunk) ? stdoutDecoder.write(chunk) : String(chunk));
    },
    stderr(chunk) {
      writeText(Buffer.isBuffer(chunk) ? stderrDecoder.write(chunk) : String(chunk));
    },
    event(text) {
      writeText(text);
    },
    close(event) {
      writeText(stdoutDecoder.end());
      writeText(stderrDecoder.end());
      const lineState = spawnApiLineState(command, outputState);
      if (
        lineState.lastWriteCommand === command &&
        lineState.lastWriteChar !== "\n"
      ) {
        spawnApiWriteOutput(command, "\n", outputState, output);
      }
      const exitCode = event.exitCode ?? 1;
      writeText(`${command.command} exited with code ${exitCode}\n`);
    },
  };
}

function spawnApiPrefix(command, options, outputState) {
  if (options.prefix === "none") {
    return "";
  }
  const content = spawnApiPrefixContent(command, options);
  if (!content) {
    return "";
  }
  if (options.padPrefix) {
    outputState.prefixLength = Math.max(
      outputState.prefixLength,
      content.value.length
    );
  }
  const value = options.padPrefix
    ? content.value.padEnd(outputState.prefixLength, " ")
    : content.value;
  if (content.type === "template" && value === "") {
    return "";
  }
  const bracketed = content.type === "template" ? value : `[${value}]`;
  const colored = spawnApiColorizePrefix(bracketed, command, options, outputState);
  return `${colored} `;
}

function spawnApiPrefixContent(command, options) {
  const prefix = options.prefix;
  if (prefix === undefined) {
    return { type: "default", value: command.name || String(command.index) };
  }
  if (prefix === "index") {
    return { type: "default", value: String(command.index) };
  }
  if (prefix === "name") {
    return { type: "default", value: command.name || String(command.index) };
  }
  if (prefix === "command") {
    return { type: "default", value: spawnApiShortenText(command.command, options) };
  }
  if (prefix === "pid") {
    return {
      type: "default",
      value: command.pid === undefined ? "" : String(command.pid),
    };
  }
  if (prefix === "time") {
    return {
      type: "default",
      value: spawnApiFormatDate(new Date(), options.timestampFormat),
    };
  }
  if (typeof prefix === "string") {
    return {
      type: "template",
      value: spawnApiTemplatePrefix(command, options, prefix),
    };
  }
  return { type: "default", value: command.name || String(command.index) };
}

function spawnApiTemplatePrefix(command, options, prefix) {
  const replacements = {
    "{index}": String(command.index),
    "{name}": command.name,
    "{command}": spawnApiShortenText(command.command, options),
    "{pid}": command.pid === undefined ? "" : String(command.pid),
    "{time}": spawnApiFormatDate(new Date(), options.timestampFormat),
  };
  return prefix.replace(
    /\{(?:index|name|command|pid|time)\}/g,
    (placeholder) => replacements[placeholder]
  );
}

function spawnApiShortenText(text, options) {
  let maxLength = Number(options.prefixLength ?? 10);
  if (Number.isNaN(maxLength) || maxLength === 0) {
    maxLength = 10;
  }
  if (!text || text.length <= maxLength) {
    return text;
  }
  const contentLength = maxLength - 2;
  const endLength = Math.floor(contentLength / 2);
  const beginningLength = contentLength - endLength;
  return `${spawnApiSlice(text, 0, beginningLength)}..${spawnApiSlice(
    text,
    text.length - endLength,
    text.length
  )}`;
}

function spawnApiSlice(text, start, end) {
  return text.slice(spawnApiSliceIndex(text, start), spawnApiSliceIndex(text, end));
}

function spawnApiSliceIndex(text, index) {
  const integer = Number.isFinite(index) ? Math.trunc(index) : index;
  if (Number.isNaN(integer)) {
    return 0;
  }
  if (integer < 0) {
    return Math.max(text.length + integer, 0);
  }
  return Math.min(integer, text.length);
}

function spawnApiColorizePrefix(prefix, command, options, outputState) {
  const colorLevel = spawnApiColorLevel(options);
  if (colorLevel === 0 || options.prefixColors === false) {
    return prefix;
  }
  const color = spawnApiPrefixColor(command, options, outputState);
  const ansi = spawnApiAnsiColor(color, colorLevel);
  return ansi ? `${ansi.open}${prefix}${ansi.close}` : prefix;
}

function spawnApiPrefixColor(command, options, outputState) {
  if (options.prefixColors !== undefined) {
    const colors = outputState?.prefixColors;
    if (colors.length === 0) {
      return undefined;
    }
    const colorPosition = outputState?.autoColorPositions?.get(command) ?? command.index;
    return spawnApiResolvedPrefixColor(colors, colorPosition);
  }
  return command.prefixColor ?? "reset";
}

function spawnApiPrefixColorsForCommands(commands, prefixColors) {
  if (prefixColors === undefined || prefixColors === false) {
    return undefined;
  }
  const colors =
    typeof prefixColors === "string"
      ? prefixColors.split(",")
      : arrayOption(prefixColors);
  if (colors.length === 0) {
    return [];
  }
  const fallback = colors[colors.length - 1];
  return commands.map((command) => colors[command.index] ?? fallback);
}

function spawnApiResolvedPrefixColor(colors, index) {
  const colorsWithoutAutos = colors.filter((color) => color !== "auto");
  const availableAutoColors = AUTO_PREFIX_COLORS.filter(
    (color) => !colorsWithoutAutos.includes(color.replace(/Bright$/, ""))
  );
  let lastColor;
  for (let position = 0; position <= index; position += 1) {
    const configured = colors[position] ?? colors[colors.length - 1];
    if (configured !== "auto") {
      lastColor = configured;
      continue;
    }
    lastColor = spawnApiNextAutoPrefixColor(availableAutoColors, lastColor);
  }
  return lastColor;
}

function spawnApiNextAutoPrefixColor(availableAutoColors, lastColor) {
  let nextColor = "auto";
  while (nextColor === "auto" || nextColor === lastColor) {
    if (availableAutoColors.length === 0) {
      availableAutoColors.push(...AUTO_PREFIX_COLORS);
    }
    nextColor = String(availableAutoColors.shift());
  }
  return nextColor;
}

function spawnApiColorsEnabled(options) {
  return spawnApiColorLevel(options) > 0;
}

function spawnApiColorLevel(options) {
  if (process.env.FORCE_COLOR !== undefined) {
    return forceColorLevel(process.env);
  }
  if (process.env.NO_COLOR !== undefined) {
    return 0;
  }
  if (apiCapturesOutput(options) || process.stdout.isTTY !== true) {
    return 0;
  }
  if (process.env.COLORTERM === "truecolor" || process.env.COLORTERM === "24bit") {
    return 3;
  }
  if (String(process.env.TERM ?? "").includes("256color")) {
    return 2;
  }
  return 1;
}

function spawnApiAnsiColor(color, colorLevel) {
  const styles = String(color ?? "")
    .split(".")
    .map((style) => spawnApiAnsiStyle(style, colorLevel))
    .filter(Boolean);
  if (styles.length === 0) {
    return undefined;
  }
  return {
    open: styles.map((style) => style.open).join(""),
    close: styles
      .slice()
      .reverse()
      .map((style) => style.close)
      .join(""),
  };
}

function spawnApiAnsiStyle(color, colorLevel) {
  const original = String(color ?? "").trim();
  const normalized = original.toLowerCase();
  if (normalized === "") {
    return undefined;
  }
  if (normalized === "reset") {
    return { open: "\u001b[0m", close: "\u001b[0m" };
  }
  const hex = spawnApiHexColor(original, colorLevel);
  if (hex) {
    return hex;
  }
  const key = normalized.replace(/[-_\s]/g, "");
  const style = {
    black: [30, 39],
    red: [31, 39],
    green: [32, 39],
    yellow: [33, 39],
    blue: [34, 39],
    magenta: [35, 39],
    cyan: [36, 39],
    white: [37, 39],
    gray: [90, 39],
    grey: [90, 39],
    blackbright: [90, 39],
    redbright: [91, 39],
    greenbright: [92, 39],
    yellowbright: [93, 39],
    bluebright: [94, 39],
    magentabright: [95, 39],
    cyanbright: [96, 39],
    whitebright: [97, 39],
    bgblack: [40, 49],
    bgred: [41, 49],
    bggreen: [42, 49],
    bgyellow: [43, 49],
    bgblue: [44, 49],
    bgmagenta: [45, 49],
    bgcyan: [46, 49],
    bgwhite: [47, 49],
    bggray: [100, 49],
    bggrey: [100, 49],
    bgblackbright: [100, 49],
    bgredbright: [101, 49],
    bggreenbright: [102, 49],
    bgyellowbright: [103, 49],
    bgbluebright: [104, 49],
    bgmagentabright: [105, 49],
    bgcyanbright: [106, 49],
    bgwhitebright: [107, 49],
    bold: [1, 22],
    dim: [2, 22],
    italic: [3, 23],
    underline: [4, 24],
    inverse: [7, 27],
    hidden: [8, 28],
    strikethrough: [9, 29],
  }[key];
  return style
    ? { open: `\u001b[${style[0]}m`, close: `\u001b[${style[1]}m` }
    : undefined;
}

function spawnApiHexColor(color, colorLevel) {
  const match = /^#?([0-9a-fA-F]{6}|[0-9a-fA-F]{3})$/.exec(color);
  if (!match) {
    return undefined;
  }
  const hex =
    match[1].length === 3
      ? match[1].split("").map((char) => char + char).join("")
      : match[1];
  const red = Number.parseInt(hex.slice(0, 2), 16);
  const green = Number.parseInt(hex.slice(2, 4), 16);
  const blue = Number.parseInt(hex.slice(4, 6), 16);
  if (colorLevel <= 1) {
    return {
      open: `\u001b[${spawnApiAnsi16Code(red, green, blue)}m`,
      close: "\u001b[39m",
    };
  }
  if (colorLevel === 2) {
    return {
      open: `\u001b[38;5;${spawnApiAnsi256Code(red, green, blue)}m`,
      close: "\u001b[39m",
    };
  }
  return {
    open: `\u001b[38;2;${red};${green};${blue}m`,
    close: "\u001b[39m",
  };
}

function spawnApiAnsi16Code(red, green, blue) {
  const code =
    30 +
    (Math.round(blue / 255) << 2) +
    (Math.round(green / 255) << 1) +
    Math.round(red / 255);
  const value = Math.max(red, green, blue);
  return value > 127 ? code + 60 : code;
}

function spawnApiAnsi256Code(red, green, blue) {
  if (red === green && green === blue) {
    if (red < 8) {
      return 16;
    }
    if (red > 248) {
      return 231;
    }
    return Math.round(((red - 8) / 247) * 24) + 232;
  }
  return (
    16 +
    36 * Math.round((red / 255) * 5) +
    6 * Math.round((green / 255) * 5) +
    Math.round((blue / 255) * 5)
  );
}

function spawnApiFlushClosedGroups(command, outputState, output) {
  const groupBuffers = outputState.groupBuffers;
  if (!groupBuffers) {
    return;
  }
  const position = outputState.groupPositions.get(command);
  if (position !== outputState.activeGroupPosition) {
    return;
  }
  for (
    let nextPosition = position + 1;
    nextPosition < outputState.orderedCommands.length;
    nextPosition += 1
  ) {
    outputState.activeGroupPosition = nextPosition;
    const nextCommand = outputState.orderedCommands[nextPosition];
    spawnApiFlushGroupBuffer(nextCommand, outputState, output);
    if (
      nextCommand.state !== "exited" ||
      outputState.pendingRestarts?.has(nextCommand)
    ) {
      break;
    }
  }
}

function spawnApiLogCommandText(command, text, options, outputState, output) {
  const prefix = spawnApiPrefix(command, options, outputState);
  const lineState = spawnApiLineState(command, outputState);
  if (
    lineState.lastWriteCommand !== undefined &&
    lineState.lastWriteCommand !== command &&
    lineState.lastWriteChar !== "\n"
  ) {
    spawnApiWriteOutput(lineState.lastWriteCommand, "\n", outputState, output);
  }
  if (
    lineState.lastWriteChar === undefined ||
    lineState.lastWriteChar === "\n"
  ) {
    spawnApiWriteOutput(command, prefix, outputState, output);
  }
  const textWithPrefixes = text.replaceAll("\n", (lineFeed, offset) =>
    text[offset + 1] ? lineFeed + prefix : lineFeed
  );
  spawnApiWriteOutput(command, textWithPrefixes, outputState, output);
}

function spawnApiLineState(command, outputState) {
  if (!spawnApiBuffersCommand(command, outputState)) {
    return outputState;
  }
  let lineState = outputState.groupLineStates.get(command);
  if (!lineState) {
    lineState = { lastWriteChar: undefined, lastWriteCommand: undefined };
    outputState.groupLineStates.set(command, lineState);
  }
  return lineState;
}

function spawnApiBuffersCommand(command, outputState) {
  const groupBuffers = outputState.groupBuffers;
  if (!groupBuffers) {
    return false;
  }
  const position = outputState.groupPositions.get(command);
  return position !== undefined && position > outputState.activeGroupPosition;
}

function spawnApiWriteOutput(command, chunk, outputState, output, trackLineState = true) {
  if (chunk === "") {
    return;
  }
  if (!spawnApiBuffersCommand(command, outputState)) {
    spawnApiWriteVisibleOutput(command, chunk, outputState, output, trackLineState);
    return;
  }
  outputState.groupBuffers.get(command).push({ chunk, trackLineState });
  if (trackLineState) {
    const lineState = spawnApiLineState(command, outputState);
    lineState.lastWriteCommand = command;
    lineState.lastWriteChar = String(chunk).slice(-1);
  }
}

function spawnApiWriteVisibleOutput(command, chunk, outputState, output, trackLineState = true) {
  output.write(chunk);
  if (!trackLineState) {
    return;
  }
  outputState.lastWriteCommand = command;
  outputState.lastWriteChar = String(chunk).slice(-1);
}

function spawnApiFlushGroupedOutput(outputState, output) {
  const groupBuffers = outputState.groupBuffers;
  if (!groupBuffers) {
    return;
  }
  for (const command of outputState.orderedCommands) {
    spawnApiFlushGroupBuffer(command, outputState, output);
  }
}

function spawnApiFlushGroupBuffer(command, outputState, output) {
  const chunks = outputState.groupBuffers?.get(command) ?? [];
  if (chunks.length === 0) {
    return;
  }
  const tracksLineState = chunks.some((record) => record.trackLineState);
  if (
    tracksLineState &&
    !outputState.raw &&
    outputState.lastWriteCommand !== undefined &&
    outputState.lastWriteCommand !== command &&
    outputState.lastWriteChar !== "\n"
  ) {
    spawnApiWriteVisibleOutput(outputState.lastWriteCommand, "\n", outputState, output);
  }
  for (const record of chunks) {
    spawnApiWriteVisibleOutput(
      command,
      record.chunk,
      outputState,
      output,
      record.trackLineState
    );
  }
  outputState.groupBuffers.set(command, []);
}

function spawnApiWriteTimings(events, options, output) {
  if (!options.timings || options.raw) {
    return;
  }
  output.write("--> Timings:\n");
  spawnApiWriteTable(
    [...events]
      .sort(
        (left, right) =>
          right.timings.durationSeconds - left.timings.durationSeconds
      )
      .map((event) => ({
        name: event.command.name,
        duration: (
          new Date(event.timings.endDate).getTime() -
          new Date(event.timings.startDate).getTime()
        ).toLocaleString(),
        "exit code": event.exitCode,
        killed: event.killed,
        command: event.command.command,
      })),
    output
  );
}

function spawnApiWriteTable(rows, output) {
  if (rows.length === 0) {
    return;
  }
  const columns = [];
  const widths = new Map();
  for (const row of rows) {
    for (const key of Object.keys(row)) {
      if (!widths.has(key)) {
        columns.push(key);
        widths.set(key, key.length);
      }
      widths.set(
        key,
        Math.max(widths.get(key), String(row[key] ?? "").length)
      );
    }
  }
  const cells = (row) =>
    columns.map((column) =>
      String(row[column] ?? "").padEnd(widths.get(column), " ")
    );
  const border = (left, separator, right) =>
    `--> ${left}${columns
      .map((column) => "─".repeat(widths.get(column) + 2))
      .join(separator)}${right}\n`;
  output.write(border("┌", "┬", "┐"));
  output.write(
    `--> │ ${cells(
      Object.fromEntries(columns.map((column) => [column, column]))
    ).join(" │ ")} │\n`
  );
  output.write(border("├", "┼", "┤"));
  for (const row of rows) {
    output.write(`--> │ ${cells(row).join(" │ ")} │\n`);
  }
  output.write(border("└", "┴", "┘"));
}

function spawnApiFormatDate(date, format = "yyyy-MM-dd HH:mm:ss.SSS") {
  const parts = {
    yyyy: String(date.getFullYear()),
    yy: String(date.getFullYear()).slice(-2),
    MM: spawnApiPad2(date.getMonth() + 1),
    dd: spawnApiPad2(date.getDate()),
    HH: spawnApiPad2(date.getHours()),
    mm: spawnApiPad2(date.getMinutes()),
    ss: spawnApiPad2(date.getSeconds()),
    SSS: String(date.getMilliseconds()).padStart(3, "0"),
  };
  return String(format).replace(
    /yyyy|SSS|yy|MM|dd|HH|mm|ss/g,
    (token) => parts[token]
  );
}

function spawnApiPad2(value) {
  return String(value).padStart(2, "0");
}

function spawnApiAttachInput(commands, options, outputState, output) {
  const inputStream =
    options.inputStream ?? (options.handleInput ? process.stdin : undefined);
  if (!inputStream) {
    return {
      finish() {},
      flush() {},
    };
  }
  const commandsByIndex = new Map();
  const commandsByName = new Map();
  for (const command of commands) {
    commandsByIndex.set(String(command.index), command);
    if (command.name !== "") {
      commandsByName.set(command.name, command);
    }
  }
  const hasExplicitInputTarget = (target) =>
    commandsByIndex.has(target) || commandsByName.has(target);
  const commandForExplicitInputTarget = (target) =>
    commandsByIndex.get(target) ?? commandsByName.get(target);
  const defaultInputTarget =
    options.defaultInputTarget === undefined ? 0 : options.defaultInputTarget;
  const defaultTarget = String(defaultInputTarget || 0);
  const commandForDefaultInputTarget = (target) =>
    typeof defaultInputTarget === "number"
      ? commandsByIndex.get(target) ?? commandsByName.get(target)
      : commandsByName.get(target) ?? commandsByIndex.get(target);
  const explicitInputTargets = [
    ...commandsByIndex.keys(),
    ...commandsByName.keys(),
  ];
  const pendingInput = new Map();
  let inputEnded = false;
  const writeInput = (target, command, input) => {
    if (!command) {
      spawnApiLogGlobalEvent(
        `Unable to find command "${target}", or it has no stdin open`,
        options,
        outputState,
        output
      );
      return;
    }
    if (!command.stdin && command.state !== "stopped") {
      spawnApiLogGlobalEvent(
        `Unable to find command "${target}", or it has no stdin open`,
        options,
        outputState,
        output
      );
      return;
    }
    if (command.stdin) {
      if (!spawnApiWriteCommandInput(command, input)) {
        spawnApiLogGlobalEvent(
          `Unable to find command "${target}", or it has no stdin open`,
          options,
          outputState,
          output
        );
      }
      return;
    }
    const chunks = pendingInput.get(command) ?? [];
    chunks.push(input);
    pendingInput.set(command, chunks);
  };
  const endStartedInput = () => {
    for (const command of commands) {
      command.stdin?.end?.();
    }
  };
  let inputCarry = "";
  const routeInputRecord = (record) => {
    const text = String(record);
    const parts = text.split(/:(.+)/s);
    let target = parts[0];
    let command;
    let input;
    if (parts.length > 1 && hasExplicitInputTarget(target)) {
      command = commandForExplicitInputTarget(target);
      input = parts[1];
    } else {
      target = defaultTarget;
      command = commandForDefaultInputTarget(target);
      input = record;
    }
    writeInput(target, command, input);
  };
  const onData = (data) => {
    const parsed = spawnApiInputRecords(
      inputCarry,
      data,
      false,
      explicitInputTargets
    );
    inputCarry = parsed.carry;
    for (const record of parsed.records) {
      routeInputRecord(record);
    }
  };
  const onEnd = () => {
    inputEnded = true;
    const parsed = spawnApiInputRecords(
      inputCarry,
      "",
      true,
      explicitInputTargets
    );
    inputCarry = parsed.carry;
    for (const record of parsed.records) {
      routeInputRecord(record);
    }
    endStartedInput();
  };
  inputStream.on?.("data", onData);
  inputStream.on?.("end", onEnd);
  let finished = false;
  return {
    finish() {
      if (finished) {
        return;
      }
      finished = true;
      inputStream.off?.("data", onData);
      inputStream.off?.("end", onEnd);
      inputCarry = "";
      pendingInput.clear();
      endStartedInput();
      if (
        options.pauseInputStreamOnFinish !== false &&
        typeof inputStream.pause === "function"
      ) {
        inputStream.pause();
      }
    },
    flush(command) {
      const chunks = pendingInput.get(command) ?? [];
      for (const chunk of chunks) {
        spawnApiWriteCommandInput(command, chunk);
      }
      pendingInput.delete(command);
      if (inputEnded) {
        command.stdin?.end?.();
      }
    },
  };
}

function spawnApiWriteCommandInput(command, input) {
  const stdin = command?.stdin;
  if (
    !stdin ||
    command.exited ||
    command.spawnApiCompleted ||
    stdin.destroyed ||
    stdin.writable === false ||
    stdin.writableEnded
  ) {
    return false;
  }
  try {
    stdin.write(input, () => {});
    return true;
  } catch (_error) {
    return false;
  }
}

function spawnApiInputRecords(carry, data, end, explicitInputTargets = []) {
  const text = carry + String(data);
  if (text === "") {
    return { records: [], carry: "" };
  }
  const records = text.match(/[^\n]*\n/g) ?? [];
  const consumed = records.reduce((offset, record) => offset + record.length, 0);
  const nextCarry = text.slice(consumed);
  if (end && nextCarry !== "") {
    records.push(nextCarry);
    return { records, carry: "" };
  }
  if (
    nextCarry !== "" &&
    !spawnApiShouldCarryPartialInput(nextCarry, explicitInputTargets)
  ) {
    records.push(nextCarry);
    return { records, carry: "" };
  }
  return { records, carry: nextCarry };
}

function spawnApiShouldCarryPartialInput(input, explicitInputTargets) {
  const separator = input.indexOf(":");
  return (
    separator !== -1 &&
    explicitInputTargets.includes(input.slice(0, separator))
  );
}

function spawnApiErrorCloseEvent(command, error) {
  const endDate = new Date();
  const startDate = command.startedAt ?? endDate;
  return {
    command,
    index: command.index,
    exitCode: error && error.code !== undefined ? error.code : 1,
    killed: command.killed,
    timings: {
      startDate,
      endDate,
      durationSeconds: (endDate.getTime() - startDate.getTime()) / 1000,
    },
  };
}

function spawnApiPublicCloseEvent(event) {
  return {
    command: commandInfo(event.command),
    index: event.index,
    exitCode: event.exitCode,
    killed: event.killed,
    timings: event.timings,
  };
}

function spawnApiShouldKillOthers(event, options) {
  const conditions = killOthersConditions(options);
  return (
    (event.exitCode === 0 && conditions.includes("success")) ||
    (event.exitCode !== 0 && conditions.includes("failure"))
  );
}

function spawnApiShouldRestart(
  event,
  command,
  restartCounts,
  restartLimit,
  scheduler
) {
  if (
    event.exitCode === 0 ||
    (command.killed && spawnApiKilledCommandSuppressesRestart(scheduler)) ||
    restartLimit === 0
  ) {
    return false;
  }
  const attempts = restartCounts.get(command) ?? 0;
  const restartAttempts =
    restartLimit === Number.POSITIVE_INFINITY
      ? Number.POSITIVE_INFINITY
      : Math.floor(restartLimit);
  if (!(attempts < restartAttempts)) {
    return false;
  }
  restartCounts.set(command, attempts + 1);
  return true;
}

function spawnApiShouldPublishCloseEvent(
  event,
  command,
  restartCounts,
  restartLimit,
  scheduler
) {
  if (event.exitCode === 0) {
    return true;
  }
  if (command.killed && spawnApiKilledCommandSuppressesRestart(scheduler)) {
    return true;
  }
  const attempts = restartCounts.get(command) ?? 0;
  return attempts >= restartLimit;
}

function spawnApiKilledCommandSuppressesRestart(scheduler) {
  return scheduler.caughtSignal === undefined || scheduler.caughtSignal === "SIGINT";
}

function spawnApiPendingRestartSuppressed(scheduler) {
  return scheduler.caughtSignal === "SIGINT";
}

function spawnApiRestartCommand(command, state) {
  const {
    input,
    options,
    output,
    outputState,
    fail,
    restartFormatter,
    restartDelay,
    running,
    scheduler,
    settle,
    startNext,
  } = state;
  outputState.pendingRestarts?.add(command);
  const timer = spawnApiSetTimer(scheduler, () => {
    scheduler.restartTimers.delete(command);
    if (scheduler.settled || spawnApiPendingRestartSuppressed(scheduler)) {
      outputState.pendingRestarts?.delete(command);
      running.delete(command);
      startNext();
      settle();
      return;
    }
    outputState.pendingRestarts?.delete(command);
    restartFormatter?.event(`${command.command} restarted\n`);
    spawnApiResetCommand(command);
    try {
      command.start();
      input.flush(command);
    } catch (error) {
      scheduler.stopStarting = true;
      running.delete(command);
      spawnApiCancelRestartTimers(scheduler, running);
      try {
        spawnApiKillOthers(running, options, scheduler);
      } catch (killError) {
        fail(killError);
        return;
      }
      if (running.size !== 0) {
        scheduler.pendingFailure = error;
        return;
      }
      fail(error);
    }
  }, restartDelay(command));
  scheduler.restartTimers.set(command, timer);
}

function spawnApiAttachSignals(commands, running, scheduler, options) {
  const signalListener = (signal) => {
    scheduler.caughtSignal = signal;
    scheduler.stopStarting = true;
    spawnApiCancelRestartTimers(scheduler, running);
    try {
      spawnApiKillOthers(running, options, scheduler, signal);
    } catch (_error) {
      for (const command of commands) {
        if (running.has(command)) {
          command.kill(signal);
        }
      }
    }
    scheduler.settle?.();
  };
  for (const signal of SIGNALS) {
    process.on(signal, signalListener);
  }
  return {
    finish() {
      for (const signal of SIGNALS) {
        process.off(signal, signalListener);
      }
    },
  };
}

function spawnApiCancelRestartTimers(scheduler, running) {
  for (const [command, timer] of scheduler.restartTimers) {
    clearTimeout(timer);
    scheduler.timers.delete(timer);
    scheduler.restartTimers.delete(command);
    running.delete(command);
  }
}

function spawnApiResetCommand(command) {
  command.exited = false;
  command.killed = false;
  command.killSignal = undefined;
  command.killExitSignal = undefined;
  command.killBeforePid = false;
  command.pid = undefined;
  command.process = undefined;
  command.stdin = undefined;
  command.spawnApiCompleted = false;
  command.state = "stopped";
}

function spawnApiKillOthers(running, options, scheduler, signal, output, outputState) {
  const killSignal = signal ?? options.killSignal ?? "SIGTERM";
  const killableCommands = [...running];
  const killTargets = killableCommands.map((command) => ({
    command,
    pid: command.pid,
    runId: command.runId,
  }));
  if (output && killableCommands.length > 0) {
    spawnApiLogGlobalEvent(
      `Sending ${killSignal} to other processes..`,
      options,
      outputState,
      output
    );
  }
  for (const runningCommand of killableCommands) {
    runningCommand.kill(killSignal);
  }
  const timeoutMs = Number(options.killTimeout);
  if (!timeoutMs || killSignal === "SIGKILL") {
    return;
  }
  const timer = spawnApiSetTimer(scheduler, () => {
    const stillKillable = killTargets
      .filter(
        (target) =>
          Number.isInteger(target.pid) &&
          target.command.pid === target.pid &&
          target.command.runId === target.runId &&
          Command.canKill(target.command)
      )
      .map((target) => target.command);
    if (output && stillKillable.length > 0) {
      spawnApiLogGlobalEvent(
        `Sending SIGKILL to ${stillKillable.length} processes..`,
        options,
        outputState,
        output
      );
    }
    for (const runningCommand of stillKillable) {
      runningCommand.kill("SIGKILL");
    }
  }, timeoutMs);
  scheduler.killTimers.add(timer);
}

function spawnApiLogGlobalEvent(message, options, outputState, output) {
  if (options.raw) {
    return;
  }
  let text;
  if (options.prefixColors === false) {
    text = `--> ${message}\n`;
  } else {
    const reset = spawnApiAnsiColor("reset", spawnApiColorLevel(options));
    text = reset
      ? `${reset.open}-->${reset.close} ${reset.open}${message}${reset.close}\n`
      : `--> ${message}\n`;
  }
  if (
    outputState.lastWriteChar !== undefined &&
    outputState.lastWriteChar !== "\n"
  ) {
    output.write("\n");
  }
  output.write(text);
  outputState.lastWriteCommand = undefined;
  outputState.lastWriteChar = "\n";
}

function spawnApiSetTimer(scheduler, callback, delay) {
  const timer = setTimeout(() => {
    scheduler.timers.delete(timer);
    callback();
  }, delay);
  scheduler.timers.add(timer);
  return timer;
}

function spawnApiClearTimers(scheduler) {
  for (const timer of scheduler.timers) {
    clearTimeout(timer);
  }
  scheduler.timers.clear();
  scheduler.killTimers.clear();
  scheduler.restartTimers.clear();
}

function spawnApiOptions(command, options, hidden) {
  const raw = typeof command.raw === "boolean" ? command.raw : Boolean(options.raw);
  const stdin = spawnApiForwardsInput(options) ? "pipe" : "ignore";
  const stdio = hidden
    ? [stdin, "ignore", "ignore"]
    : raw && !apiCapturesOutput(options)
      ? [stdin, "inherit", "inherit"]
      : [stdin, "pipe", "pipe"];
  return {
    cwd: commandCwd(command) ?? invocationCwd(options),
    env: {
      ...process.env,
      ...normalizeEnv(options.env),
      ...normalizeEnv(command.env),
    },
    shell: true,
    stdio,
  };
}

function spawnApiForwardsInput(options) {
  return Boolean(options.inputStream || options.handleInput);
}

function spawnApiKillProcess(command, options, signal) {
  if (options.kill !== undefined) {
    options.kill(command.pid, signal);
    return true;
  }
  if (!Number.isInteger(command.pid)) {
    return false;
  }
  if (process.platform === "win32") {
    spawnApiValidateKillSignal(signal ?? "SIGTERM");
    spawnApiKillTree(command.pid, "SIGKILL", true);
    return "SIGKILL";
  }
  spawnApiKillTree(command.pid, signal);
  return true;
}

function spawnApiKillTree(pid, signal, force = false) {
  const killSignal = signal ?? "SIGTERM";
  if (process.platform === "win32") {
    spawnApiValidateKillSignal(killSignal);
    const args = ["/pid", String(pid), "/T"];
    if (force || killSignal === "SIGKILL") {
      args.push("/F");
    }
    const child = spawnChildProcess("taskkill", args, {
      stdio: "ignore",
      windowsHide: true,
    });
    child.on("error", () => {});
    return;
  }
  for (const childPid of spawnApiDescendantPids(pid)) {
    spawnApiKillPid(childPid, killSignal);
  }
  spawnApiKillPid(pid, killSignal);
}

function spawnApiValidateKillSignal(signal) {
  // Node validates the signal before PID lookup; ESRCH means this signal is valid.
  try {
    process.kill(SIGNAL_VALIDATION_PID, signal);
  } catch (error) {
    if (error?.code === "ESRCH") {
      return;
    }
    throw error;
  }
}

function spawnApiKillPid(pid, signal) {
  try {
    process.kill(pid, signal);
  } catch (error) {
    if (error?.code !== "ESRCH") {
      throw error;
    }
  }
}

function spawnApiDescendantPids(pid) {
  const childrenByParent = spawnApiChildrenByParentPid();
  const descendants = [];
  const visited = new Set([pid]);
  const stack = [pid];
  while (stack.length > 0) {
    const parentPid = stack.pop();
    for (const childPid of childrenByParent.get(parentPid) ?? []) {
      if (visited.has(childPid)) {
        continue;
      }
      visited.add(childPid);
      descendants.push(childPid);
      stack.push(childPid);
    }
  }

  return descendants.reverse();
}

function spawnApiChildrenByParentPid() {
  const childrenByParent = new Map();
  const table = spawnApiPsProcessTable();
  for (const line of table.split(/\r?\n/)) {
    const [pidText, parentPidText] = line.trim().split(/\s+/);
    const pid = Number(pidText);
    const parentPid = Number(parentPidText);
    if (!Number.isInteger(pid) || !Number.isInteger(parentPid)) {
      continue;
    }
    const children = childrenByParent.get(parentPid) ?? [];
    children.push(pid);
    childrenByParent.set(parentPid, children);
  }

  return childrenByParent;
}

function spawnApiPsProcessTable() {
  for (const command of ["/bin/ps", "/usr/bin/ps", "ps"]) {
    const result = spawnSync(command, ["-eo", "pid=,ppid="], {
      encoding: "utf8",
    });
    if (!result.error && result.status === 0) {
      return result.stdout;
    }
    if (result.error?.code !== "ENOENT") {
      return "";
    }
  }

  return "";
}

function spawnApiMaxProcesses(maxProcesses, commandCount) {
  if (maxProcesses === undefined || maxProcesses === null) {
    return Number.POSITIVE_INFINITY;
  }
  if (typeof maxProcesses === "string" && maxProcesses.endsWith("%")) {
    const percent = Number(maxProcesses.slice(0, -1));
    if (Number.isNaN(percent) || percent === 0) {
      return commandCount;
    }
    return Math.max(1, Math.round((cpus().length * percent) / 100));
  }
  const parsed = Number(maxProcesses);
  if (Number.isNaN(parsed) || parsed === 0) {
    return commandCount;
  }
  if (parsed < 0) {
    return 1;
  }
  return Math.max(1, Math.ceil(parsed));
}

function spawnApiRestartLimit(restartTries) {
  if (restartTries === undefined || restartTries === null) {
    return 0;
  }
  const parsed = Number(restartTries);
  if (parsed < 0) {
    return Number.POSITIVE_INFINITY;
  }
  return parsed;
}

function spawnApiRestartDelay(restartDelay, nextAttempt = 1) {
  if (restartDelay === undefined || restartDelay === null) {
    return 0;
  }
  if (restartDelay === "exponential") {
    return Math.pow(2, nextAttempt - 1) * 1000;
  }
  const parsed = Number(restartDelay);
  return Number.isNaN(parsed) ? 0 : parsed;
}

function observerSubscriber(observer) {
  if (typeof observer === "function") {
    return observer;
  }
  if (observer && typeof observer.next === "function") {
    return (value) => observer.next(value);
  }
  throw new Error("subject subscriber must be a function or observer");
}

function normalizeCommands(commandInputs) {
  return commandInputs.map((input, index) => {
    if (typeof input === "string") {
      return new Command({ index, name: "", command: input });
    }
    if (!input || typeof input !== "object" || typeof input.command !== "string") {
      throw new Error(`command ${index} must be a string or command object`);
    }
    if (input.ipc) {
      throw new NativeApiUnsupportedError("command.ipc");
    }
    return new Command({
      index,
      name: input.name ?? "",
      command: input.command,
      prefixColor: input.prefixColor,
      env: input.env,
      cwd: input.cwd,
      ipc: input.ipc,
      raw: input.raw,
      hidden: input.hidden,
    });
  });
}

function markStartedCommands(commands, eventDir, fallbackStartDate) {
  for (const command of commands) {
    if (command.state !== "stopped" && Number.isInteger(command.pid)) {
      continue;
    }
    const start = readCommandStart(eventStartPath(eventDir, command.index));
    if (start !== undefined) {
      markCommandStarted(command, new Date(start.startMs), start.pid);
    }
  }
  if (commands.length === 1 && commands[0]?.state === "stopped") {
    markCommandStarted(commands[0], fallbackStartDate);
  }
}

function markCommandStarted(command, startDate, pid) {
  if (Number.isInteger(pid)) {
    command.pid = pid;
  }
  if (command.state !== "stopped") {
    return;
  }
  command.startedAt = startDate;
  command.state = "started";
  command.stateChange.next("started");
  command.timer.next({ startDate });
}

function applyControllers(commands, controllers) {
  if (controllers === undefined || controllers === null) {
    return { commands, onFinishCallbacks: [] };
  }
  if (!Array.isArray(controllers)) {
    throw new Error("options.controllers must be an array");
  }

  const onFinishCallbacks = [];
  let controlledCommands = commands;
  for (const controller of controllers) {
    if (!controller || typeof controller.handle !== "function") {
      throw new Error("options.controllers entries must implement handle(commands)");
    }
    const result = controller.handle(controlledCommands);
    if (!result || !Array.isArray(result.commands)) {
      throw new Error("controller.handle(commands) must return { commands }");
    }
    controlledCommands = result.commands;
    if (result.onFinish !== undefined) {
      if (typeof result.onFinish !== "function") {
        throw new Error("controller onFinish must be a function");
      }
      onFinishCallbacks.push(result.onFinish);
    }
  }
  assertUniqueCommandIndexes(controlledCommands);
  return { commands: controlledCommands, onFinishCallbacks };
}

function assertUniqueCommandIndexes(commands) {
  const indexes = new Set();
  for (const command of commands) {
    if (!(command instanceof Command)) {
      throw new Error("controllers must return Command objects");
    }
    if (command.ipc != null) {
      throw new NativeApiUnsupportedError("command.ipc");
    }
    if (!Number.isInteger(command.index)) {
      throw new Error("controllers must return commands with integer indexes");
    }
    if (indexes.has(command.index)) {
      throw new Error(`controllers returned duplicate command index ${command.index}`);
    }
    indexes.add(command.index);
  }
}

function runOnFinishCallbacks(result, onFinishCallbacks) {
  if (onFinishCallbacks.length === 0) {
    return result;
  }
  const runCallbacks = () =>
    Promise.all(onFinishCallbacks.map((onFinish) => onFinish())).then(
      () => undefined
    );
  return result.then(
    (events) => runCallbacks().then(() => events),
    (error) =>
      runCallbacks().then(() => {
        throw error;
      })
  );
}

function expandShortcutCommands(commands, options) {
  const expanded = commands.flatMap((command) =>
    expandShortcutCommand(command, options)
  );
  expanded.forEach((command, index) => {
    command.index = index;
  });
  return expanded;
}

function expandShortcutCommand(command, options) {
  const shortcut = parseShortcut(command.command) ?? parseRunnerWildcard(command.command);
  if (!shortcut) {
    return [command];
  }

  const cwd = commandLookupCwd(command, options);
  if (!shortcut.script.includes("*")) {
    return [shortcutCommand(command, shortcut, shortcut.script, false)];
  }

  const scriptNames = shortcut.runner === "deno"
    ? denoScriptNames(cwd)
    : Object.keys(packageScripts(cwd));
  const matchesScript = wildcardMatcher(shortcut.script);
  return scriptNames
    .filter(matchesScript)
    .map((script) => shortcutCommand(command, shortcut, script, true));
}

function parseShortcut(command) {
  const match = /^([A-Za-z][A-Za-z0-9_-]*):(\S+)(?:\s+(.*))?$/.exec(command);
  if (!match || !SHORTCUT_RUNNERS.has(match[1])) {
    return undefined;
  }
  return { runner: match[1], script: match[2], prefix: "", suffix: match[3] ?? "" };
}

function parseRunnerWildcard(command) {
  const match =
    /((?:npm|yarn|pnpm|bun)\s+run|node\s+--run|deno\s+task)\s+(\S*\*\S*)/.exec(command);
  if (!match) {
    return undefined;
  }
  const runner = runnerFromWildcardCommand(match[1]);
  const scriptEnd = match.index + match[0].length;
  return {
    runner,
    script: match[2],
    prefix: command.slice(0, match.index),
    suffix: command.slice(scriptEnd).trimStart(),
  };
}

function runnerFromWildcardCommand(command) {
  if (command === "node --run") {
    return "node";
  }
  if (command === "deno task") {
    return "deno";
  }
  return command.split(/\s+/, 1)[0];
}

function shortcutCommand(base, shortcut, script, verbatimScript) {
  const name = shortcutCommandName(base, shortcut, script, verbatimScript);
  return new Command({
    index: base.index,
    name,
    command: shortcutCommandText(shortcut, script, verbatimScript),
    prefixColor: base.prefixColor,
    env: base.env,
    cwd: base.cwd,
    ipc: base.ipc,
    raw: base.raw,
    hidden: base.hidden,
  });
}

function shortcutCommandName(base, shortcut, script, wildcardExpanded) {
  if (!wildcardExpanded) {
    return base.name === "" ? script : base.name;
  }
  const capture = wildcardCapture(shortcut.script, script) ?? script;
  return base.name === "" ? capture : `${base.name}:${capture}`;
}

function shortcutCommandText(shortcut, script, verbatimScript) {
  const scriptArgument = shellQuote(script);
  const suffix = shortcut.suffix ? ` ${shortcut.suffix}` : "";
  const prefix = shortcut.prefix ?? "";
  if (shortcut.runner === "npm") {
    return `${prefix}npm run ${scriptArgument}${suffix}`;
  }
  if (shortcut.runner === "node") {
    return `${prefix}node --run ${scriptArgument}${suffix}`;
  }
  if (shortcut.runner === "deno") {
    return `${prefix}deno task ${scriptArgument}${suffix}`;
  }
  return `${prefix}${shortcut.runner} run ${scriptArgument}${suffix}`;
}

function packageScripts(cwd) {
  const manifest = readJsonFile(join(cwd, "package.json"));
  return manifest && typeof manifest.scripts === "object" && manifest.scripts
    ? manifest.scripts
    : {};
}

function denoTasks(cwd) {
  for (const [fileName, jsonc] of [["deno.json", false], ["deno.jsonc", true]]) {
    const manifest = readJsonFile(join(cwd, fileName), jsonc);
    if (manifest && typeof manifest.tasks === "object" && manifest.tasks) {
      return manifest.tasks;
    }
  }
  return {};
}

function denoScriptNames(cwd) {
  return [
    ...Object.keys(denoTasks(cwd)),
    ...Object.keys(packageScripts(cwd)),
  ];
}

function readJsonFile(path, jsonc = false) {
  try {
    const content = readFileSync(path, "utf8");
    return JSON.parse(jsonc ? stripJsonComments(content) : content);
  } catch (_error) {
    return undefined;
  }
}

function stripJsonComments(content) {
  return content
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .replace(/(^|[^:])\/\/.*$/gm, "$1")
    .replace(/,(\s*[}\]])/g, "$1");
}

function wildcardMatcher(pattern) {
  const { include, omissions } = wildcardPatternParts(pattern);
  const expression = new RegExp(
    `^${include.split("*").map(escapeRegex).join(".*")}$`
  );
  const omissionExpressions = omissions.map(wildcardOmissionExpression);
  return (value) =>
    expression.test(value) &&
    !omissionExpressions.some((omission) => omission.test(value));
}

function wildcardOmissionExpression(pattern) {
  try {
    return new RegExp(pattern);
  } catch (_error) {
    throw new Error(`invalid wildcard omission regular expression: ${pattern}`);
  }
}

function wildcardCapture(pattern, value) {
  const { include } = wildcardPatternParts(pattern);
  const wildcardIndex = include.indexOf("*");
  if (wildcardIndex === -1) {
    return undefined;
  }
  const prefix = include.slice(0, wildcardIndex);
  const suffix = include.slice(wildcardIndex + 1);
  if (!value.startsWith(prefix) || !value.endsWith(suffix)) {
    return undefined;
  }
  return value.slice(prefix.length, value.length - suffix.length);
}

function wildcardPatternParts(pattern) {
  const omissions = [];
  const include = pattern.replace(/\(!([^)]+)\)/g, (_match, omission) => {
    omissions.push(omission);
    return "";
  });
  return { include, omissions };
}

function escapeRegex(value) {
  return value.replace(/[\\^$.*+?()[\]{}|]/g, "\\$&");
}

function expandAdditionalArguments(commands, additionalArguments) {
  if (additionalArguments === undefined || additionalArguments === null) {
    return;
  }
  if (!Array.isArray(additionalArguments)) {
    throw new Error("options.additionalArguments must be an array");
  }
  const args = additionalArguments.map(String);
  for (const command of commands) {
    command.command = command.command.replace(
      /\\?\{([@*]|[1-9][0-9]*)\}/g,
      (match, target) => {
        if (match.startsWith("\\")) {
          return match.slice(1);
        }
        if (args.length > 0) {
          if (/^[1-9][0-9]*$/.test(target)) {
            return args[Number(target) - 1] === undefined
              ? ""
              : shellQuote(args[Number(target) - 1]);
          }
          if (target === "@") {
            return quoteArguments(args);
          }
          if (target === "*") {
            return shellQuote(args.join(" "));
          }
        }
        return "";
      }
    );
  }
}

function nativeInvocation(commands, options, eventDir) {
  const args = [];
  const env = { ...process.env };
  const cwd = invocationCwd(options);
  const rawValues = commandRawValues(commands, options);
  const inheritedCommandEnv = {};

  args.push("--api-ignore-env-options");
  if (commands.length === 0) args.push("--api-empty-expansion");
  pushOption(args, "--max-processes", options.maxProcesses);
  pushOption(args, "--success", nativeSuccessCondition(commands, options.successCondition));
  pushOption(args, "--prefix-length", options.prefixLength);
  pushOption(args, "--timestamp-format", options.timestampFormat);
  pushOption(
    args,
    "--default-input-target",
    nativeCommandIdentifier(commands, options.defaultInputTarget)
  );
  pushOption(args, "--restart-tries", options.restartTries);
  pushOption(args, "--restart-after", options.restartDelay);
  pushOption(args, "--kill-signal", options.killSignal);
  pushOption(args, "--kill-timeout", options.killTimeout);

  if (options.group) args.push("--group");
  if (rawValues.global) args.push("--raw");
  if (rawValues.rawIndexes.length > 0) {
    pushOption(args, "--api-raw-indexes", rawValues.rawIndexes.join(","));
  }
  if (rawValues.formattedIndexes.length > 0) {
    pushOption(
      args,
      "--api-formatted-indexes",
      rawValues.formattedIndexes.join(",")
    );
  }
  if (options.padPrefix) args.push("--pad-prefix");
  if (options.timings) args.push("--timings");
  if (options.handleInput || options.inputStream) args.push("--handle-input");
  if (options.prefixColors === false) {
    if (Object.prototype.hasOwnProperty.call(env, "FORCE_COLOR")) {
      inheritedCommandEnv.FORCE_COLOR = env.FORCE_COLOR;
      delete env.FORCE_COLOR;
    }
  }
  if (
    options.prefixColors === false ||
    (apiCapturesOutput(options) && !forceColorEnabled(env))
  ) {
    args.push("--no-color");
  }

  const publicNames = commands.map((command) => command.name);
  const positionMatchesPublicIndex = commands.every(
    (command, position) => command.index === position
  );
  if (publicNames.some((name) => name !== "") || !positionMatchesPublicIndex) {
    const names = publicNames.map(
      (name, position) => name || String(commands[position].index)
    );
    const nameSeparator = commandNameSeparator(names);
    pushOption(args, "--api-name-separator", nameSeparator);
    pushOption(args, "--names", names.join(nameSeparator));
  }
  if (needsPublicIndexLabels(options, positionMatchesPublicIndex)) {
    pushOption(
      args,
      "--api-index-labels",
      commands.map((command) => String(command.index)).join(",")
    );
  }
  pushOption(args, "--prefix", options.prefix);

  const prefixColors = commandPrefixColors(commands, options);
  if (prefixColors) {
    pushOption(args, "--prefix-colors", prefixColors);
  }

  const hidden = hiddenCommands(commands, options);
  if (hidden.length > 0) {
    pushOption(args, "--api-hide-indexes", hidden.join(","));
  }
  const commandEnvPaths = writeCommandEnvironmentFiles(
    eventDir,
    commands,
    options,
    inheritedCommandEnv
  );

  applyKillOthers(args, options);
  for (const teardown of arrayOption(options.teardown)) {
    pushOption(args, "--teardown", teardown);
  }

  for (const command of commands) {
    pushOption(args, "--api-display-command", command.command);
  }

  args.push(
    ...commands.map((command) =>
      eventWrapperCommand(
        command.command,
        eventPath(eventDir, command.index),
        eventStartPath(eventDir, command.index),
        killPath(eventDir, command.index),
        options.handleInput || options.inputStream,
        requiredCommandEnvPath(commandEnvPaths, command),
        commandCwd(command),
        shouldDetachWrappedCommand(options)
      )
    )
  );
  return {
    args,
    cwd,
    env,
    killPaths: commands.map((command) => killPath(eventDir, command.index)),
    missingEventIsKilled: nativeKillPolicyMayStopCommands(options),
    stdio: stdioFor(options),
  };
}

function eventWrapperCommand(
  command,
  path,
  startPath,
  killPath,
  forwardStdin,
  commandEnvPath,
  cwd,
  detachWrappedCommand
) {
  const commandText = Buffer.from(command).toString("base64");
  const eventFile = Buffer.from(path).toString("base64");
  const startFile = Buffer.from(startPath).toString("base64");
  const killFile = Buffer.from(killPath).toString("base64");
  const commandEnvFile = Buffer.from(commandEnvPath).toString("base64");
  const commandCwd =
    cwd === undefined ? undefined : Buffer.from(cwd).toString("base64");
  const childStdin = forwardStdin ? "inherit" : "ignore";
  const source = [
    "const cp=require('node:child_process')",
    "const fs=require('node:fs')",
    "const signalNumbers=require('node:os').constants.signals",
    `const cmd=Buffer.from('${commandText}','base64').toString()`,
    `const file=Buffer.from('${eventFile}','base64').toString()`,
    `const startFile=Buffer.from('${startFile}','base64').toString()`,
    `const killFile=Buffer.from('${killFile}','base64').toString()`,
    `const commandEnvFile=Buffer.from('${commandEnvFile}','base64').toString()`,
    commandCwd === undefined
      ? "const cwd=undefined"
      : `const cwd=Buffer.from('${commandCwd}','base64').toString()`,
    "const commandEnv=JSON.parse(fs.readFileSync(commandEnvFile,'utf8'))",
    `const childStdin='${childStdin}'`,
    "const startMs=Date.now()",
    "let child",
    "let exiting=false",
    "let wrote=false",
    "const write=event=>{if(!wrote){wrote=true;fs.writeFileSync(file,JSON.stringify({...event,startMs,endMs:Date.now()}))}}",
    "const exitCode=signal=>128+(typeof signal==='number'?signal:(signalNumbers[signal]||1))",
    "const descendantPids=pid=>{if(process.platform==='win32'||!pid)return[];try{const ps=cp.spawnSync('ps',['-A','-o','pid=','-o','ppid='],{encoding:'utf8',timeout:200,maxBuffer:1024*1024});const rows=String(ps.stdout||'').trim().split(/\\n+/);const children=new Map();for(const row of rows){const parts=row.trim().split(/\\s+/);if(parts.length<2)continue;const childPid=Number(parts[0]);const parentPid=Number(parts[1]);if(!Number.isInteger(childPid)||!Number.isInteger(parentPid))continue;const childList=children.get(parentPid)||[];childList.push(childPid);children.set(parentPid,childList)}const result=[];const stack=[pid];while(stack.length>0){const parent=stack.pop();for(const childPid of children.get(parent)||[]){result.push(childPid);stack.push(childPid)}}return result}catch(_){return[]}}",
    "const killDescendants=(pid,signal)=>{for(const target of descendantPids(pid).reverse()){try{process.kill(target,signal)}catch(_){}}}",
    "const forward=signal=>{if(!child)return;const pid=child.pid;const killGroup=()=>{if(process.platform!=='win32'&&pid){try{process.kill(-pid,signal);return true}catch(_){}}return false};const killChild=()=>{try{child.kill(signal)}catch(_){}};const attempt=()=>{if(!killGroup())killDescendants(pid,signal);killChild()};attempt();for(const delay of [25,100,250])setTimeout(attempt,delay).unref()}",
    "const onSignal=signal=>{write({code:null,signal});forward(signal);if(!exiting){exiting=true;setTimeout(()=>{forward('SIGKILL');process.exit(exitCode(signal))},5000).unref()}}",
    "const pollKill=()=>{try{if(fs.existsSync(killFile)){const signal=JSON.parse(fs.readFileSync(killFile,'utf8'));fs.rmSync(killFile,{force:true});onSignal(signal)}}catch(_){}}",
    "for(const signal of ['SIGHUP','SIGINT','SIGTERM','SIGQUIT','SIGUSR1','SIGUSR2','SIGBREAK']){if(signalNumbers[signal]){try{process.on(signal,()=>onSignal(signal))}catch(_){}}}",
    `const detachWrappedCommand=${detachWrappedCommand ? "true" : "false"}`,
    "const spawnOptions={shell:true,detached:detachWrappedCommand,stdio:[childStdin,'inherit','inherit'],env:{...process.env,...commandEnv}}",
    "if(cwd!==undefined)spawnOptions.cwd=cwd",
    "child=cp.spawn(cmd,spawnOptions)",
    "fs.writeFileSync(startFile,JSON.stringify({startMs,pid:child.pid}))",
    "const killInterval=setInterval(pollKill,20);killInterval.unref()",
    "child.on('error',error=>{write({code:1,signal:null,error:error.message});process.exit(1)})",
    "child.on('exit',(code,signal)=>{write({code,signal});if(signal){process.exit(exitCode(signal))}else{process.exit(code??1)}})",
  ].join(";");
  const runner = process.platform === "win32" ? "call " : "command ";
  return `${runner}${shellArg(process.execPath)} -e ${shellArg(source)}`;
}

function shellArg(value) {
  const text = String(value);
  if (process.platform === "win32") {
    return `"${text.replace(/(\\*)"/g, '$1$1\\"').replace(/(\\+)$/g, "$1$1")}"`;
  }
  return `'${text.replaceAll("'", "'\\''")}'`;
}

function eventPath(eventDir, index) {
  return join(eventDir, `${index}.json`);
}

function eventStartPath(eventDir, index) {
  return join(eventDir, `${index}.start`);
}

function killPath(eventDir, index) {
  return join(eventDir, `${index}.kill`);
}

function readCommandEvents({
  commands,
  endedAt,
  eventDir,
  missingEventIsKilled,
  runExitCode,
  runKilled,
  runKillSignal,
  startedAt,
}) {
  const events = commands.flatMap((command) => {
    const event = readCommandEvent(eventPath(eventDir, command.index));
    const eventMissing = event === undefined;
    const started = existsSync(eventStartPath(eventDir, command.index));
    if (eventMissing && missingEventIsKilled && !started) {
      return [];
    }
    const killed =
      command.killed ||
      Boolean(event?.signal) ||
      runKilled ||
      (eventMissing && missingEventIsKilled);
    const exitCode =
      command.killed && runExitCode === 0
        ? event?.code ?? 0
        : event?.signal ??
          event?.code ??
          (killed ? command.killSignal ?? runKillSignal : runExitCode);
    const commandStart = readCommandStart(eventStartPath(eventDir, command.index));
    const commandStartMs =
      event?.startMs ?? commandStart?.startMs ?? startedAt.getTime();
    const commandStartedAt = new Date(
      commandStartMs
    );
    if (command.state === "stopped") {
      markCommandStarted(command, commandStartedAt, commandStart?.pid);
    }
    command.exited = true;
    command.killed = killed;
    command.state = "exited";
    command.stateChange.next("exited");
    const commandEndedAt = new Date(event?.endMs ?? endedAt.getTime());
    const closeEvent = {
      command: commandInfo(command),
      index: command.index,
      killed: command.killed,
      exitCode,
      timings: {
        startDate: commandStartedAt,
        endDate: commandEndedAt,
        durationSeconds:
          (commandEndedAt.getTime() - commandStartedAt.getTime()) / 1000,
      },
    };
    command.timer.next({
      startDate: commandStartedAt,
      endDate: commandEndedAt,
    });
    command.close.next(closeEvent);
    return [closeEvent];
  });
  events.sort((left, right) => {
    const leftEndMs = left.timings.endDate.getTime();
    const rightEndMs = right.timings.endDate.getTime();
    return leftEndMs - rightEndMs || left.index - right.index;
  });
  return events;
}

function readCommandEvent(path) {
  if (!existsSync(path)) {
    return undefined;
  }
  try {
    const content = readFileSync(path, "utf8");
    return content.trim() === "" ? undefined : JSON.parse(content);
  } catch (_error) {
    return undefined;
  }
}

function readCommandStart(path) {
  if (!existsSync(path)) {
    return undefined;
  }
  try {
    const start = JSON.parse(readFileSync(path, "utf8"));
    return Number.isFinite(start.startMs)
      ? { startMs: start.startMs, pid: start.pid }
      : undefined;
  } catch (_error) {
    return undefined;
  }
}

function commandProcessExists(pid, sameProcessGroup = false) {
  if (!Number.isInteger(pid)) {
    return false;
  }
  try {
    process.kill(process.platform === "win32" || sameProcessGroup ? pid : -pid, 0);
    return true;
  } catch (_error) {
    return false;
  }
}

function writeCommandEnvironmentFiles(
  eventDir,
  commands,
  options,
  inheritedCommandEnv
) {
  const paths = new Map();
  for (const command of commands) {
    const path = join(eventDir, `${command.index}.env.json`);
    const commandEnv = {
      ...inheritedCommandEnv,
      ...normalizeEnv(options.env),
      ...normalizeEnv(command.env),
    };
    writeFileSync(
      path,
      JSON.stringify(commandEnv),
      { mode: 0o600 }
    );
    paths.set(command.index, path);
  }
  return paths;
}

function requiredCommandEnvPath(paths, command) {
  const path = paths.get(command.index);
  if (path === undefined) {
    throw new Error(`missing environment file for command index ${command.index}`);
  }
  return path;
}

function commandRawValues(commands, options) {
  const defaultRaw = Boolean(options.raw);
  const rawValues = commands.map((command) =>
    typeof command.raw === "boolean" ? command.raw : defaultRaw
  );
  const global = defaultRaw;
  const rawIndexes = [];
  const formattedIndexes = [];
  rawValues.forEach((raw, index) => {
    if (raw && !global) {
      rawIndexes.push(index);
    } else if (!raw && global) {
      formattedIndexes.push(index);
    }
  });
  return { global, rawIndexes, formattedIndexes };
}

function nativeSuccessCondition(commands, successCondition) {
  if (typeof successCondition !== "string") {
    return successCondition;
  }
  if (successCondition.startsWith("!command-")) {
    return nativeCommandSelector(commands, successCondition, "!command-", 9);
  }
  if (successCondition.startsWith("command-")) {
    return nativeCommandSelector(commands, successCondition, "command-", 8);
  }
  return successCondition;
}

function nativeCommandSelector(commands, successCondition, prefix, selectorStart) {
  const selector = successCondition.slice(selectorStart);
  if (!/^[0-9]+$/.test(selector)) {
    return successCondition;
  }
  if (commandNames(commands).includes(selector)) {
    return successCondition;
  }
  const selectedIndex = Number(selector);
  const nativePositions = commands.flatMap((command, position) =>
    command.index === selectedIndex ? [String(position)] : []
  );
  if (nativePositions.length !== 1) {
    return commandNames(commands).includes(selector)
      ? successCondition
      : `${prefix}${commands.length}`;
  }
  return `${prefix}${nativePositions[0]}`;
}

function nativeCommandIdentifier(commands, identifier) {
  if (identifier === undefined) {
    return undefined;
  }
  return String(identifier);
}

function needsPublicIndexLabels(options, positionMatchesPublicIndex) {
  return (
    !positionMatchesPublicIndex &&
    (prefixUsesIndexLabel(options.prefix) ||
      options.handleInput ||
      options.inputStream ||
      options.defaultInputTarget !== undefined)
  );
}

function closeEventsSucceeded(events, successCondition = "all") {
  if (events.length === 0) {
    return true;
  }
  if (successCondition === "first") {
    return events[0].exitCode === 0;
  }
  if (successCondition === "last") {
    return events[events.length - 1].exitCode === 0;
  }
  const match = /^(!?)command-(.+)$/.exec(String(successCondition));
  if (!match) {
    return events.every((event) => event.exitCode === 0);
  }
  const negated = match[1] === "!";
  const selector = match[2];
  const targetEvents = closeEventsForSelector(events, selector);
  if (negated) {
    return events.every(
      (event) => targetEvents.includes(event) || event.exitCode === 0
    );
  }
  return (
    targetEvents.length > 0 &&
    targetEvents.every((event) => event.exitCode === 0)
  );
}

function commandNames(commands) {
  return commands.map((command) => command.name);
}

function invocationCwd(options) {
  return normalizeCwd(options.cwd) ?? process.cwd();
}

function commandCwd(command) {
  return normalizeCwd(command.cwd);
}

function commandLookupCwd(command, options) {
  return commandCwd(command) ?? invocationCwd(options);
}

function normalizeCwd(cwd) {
  return typeof cwd === "string" && cwd.length > 0
    ? resolve(cwd)
    : undefined;
}

function commandPrefixColors(commands, options) {
  if (options.prefixColors === false) {
    return undefined;
  }
  if (options.prefixColors !== undefined) {
    if (typeof options.prefixColors === "string") {
      return remapPrefixColors(commands, options.prefixColors.split(","));
    }
    return remapPrefixColors(commands, arrayOption(options.prefixColors));
  }
  const colors = commands.map((command) => command.prefixColor);
  return colors.some(Boolean)
    ? colors.map((color) => color || "reset").join(",")
    : undefined;
}

function prefixUsesIndexLabel(prefix) {
  if (typeof prefix !== "string") {
    return false;
  }
  return prefix.toLowerCase() === "index" || prefix.includes("{index}");
}

function remapPrefixColors(commands, colors) {
  if (colors.length === 0 || (colors.length === 1 && colors[0] === "")) {
    return "";
  }
  const lastColor = colors[colors.length - 1];
  return commands.map((command) => colors[command.index] ?? lastColor).join(",");
}

function forceColorEnabled(env) {
  return forceColorLevel(env) > 0;
}

function forceColorLevel(env) {
  const value = env.FORCE_COLOR;
  if (value === undefined) {
    return 0;
  }
  const normalized = String(value).trim().toLowerCase();
  if (normalized === "false" || normalized === "0") {
    return 0;
  }
  if (normalized === "" || normalized === "true") {
    return 1;
  }
  const level = Number.parseInt(normalized, 10);
  if (Number.isNaN(level) || level <= 0) {
    return 0;
  }
  return Math.min(level, 3);
}

function hiddenCommands(commands, options) {
  return [
    ...commands
      .flatMap((command, position) => command.hidden ? [String(position)] : []),
    ...arrayOption(options.hide).flatMap((identifier) =>
      hideIdentifiers(commands, identifier)
    ),
  ].map(String);
}

function hideIdentifiers(commands, identifier) {
  if (typeof identifier === "number") {
    const indexes = commands
      .flatMap((command, position) =>
        command.index === identifier ? [String(position)] : []
      );
    return indexes;
  }
  const value = String(identifier);
  const matchingIndexes = commands
    .flatMap((command, position) =>
      command.name === value || String(command.index) === value
        ? [String(position)]
        : []
    );
  return matchingIndexes;
}

function nativeKillPolicyMayStopCommands(options) {
  return killOthersConditions(options).length > 0;
}

function shouldDetachWrappedCommand(options) {
  return (
    process.platform !== "win32" &&
    !nativeKillPolicyMayStopCommands(options)
  );
}

function applyKillOthers(args, options) {
  const conditions = killOthersConditions(options);
  if (conditions.length === 0) {
    return;
  }
  const wantsSuccess = conditions.includes("success");
  const wantsFailure = conditions.includes("failure");
  if (wantsSuccess && wantsFailure) {
    args.push("--kill-others");
  } else if (wantsSuccess) {
    args.push("--kill-others-on-success");
  } else if (wantsFailure) {
    args.push("--kill-others-on-fail");
  }
}

function killOthersConditions(options) {
  return arrayOption(options.killOthersOn ?? options.killOthers);
}

function attachStreams(child, options) {
  const outputSink = apiOutputSink(options);
  if (!outputSink) {
    return () => Promise.resolve();
  }
  const output = outputWriter(outputSink);
  const write = (chunk) => output.write(chunk);
  child.stdout?.on("data", write);
  child.stderr?.on("data", write);
  return () => output.finish();
}

function attachInput(child, options) {
  const inputStream =
    options.inputStream ?? (options.handleInput ? process.stdin : undefined);
  if (!inputStream) {
    if (child.stdin) {
      child.stdin.end();
    }
    return () => {};
  }
  inputStream.pipe(child.stdin);
  child.stdin?.on("error", (_error) => {});
  let finished = false;
  return () => {
    if (finished) {
      return;
    }
    finished = true;
    if (child.stdin && typeof inputStream.unpipe === "function") {
      inputStream.unpipe(child.stdin);
    }
    if (options.pauseInputStreamOnFinish !== false && typeof inputStream.pause === "function") {
      inputStream.pause();
    }
  };
}

function stdioFor(options) {
  const output = apiCapturesOutput(options) ? "pipe" : "inherit";
  return ["pipe", output, output];
}

function apiOutputSink(options) {
  const logger = options.logger;
  const outputStreams = uniqueOutputStreams(
    options.outputStream,
    loggerOutputStream(logger)
  );
  if (outputStreams.length > 0 || logger) {
    const writesLogger =
      logger && !streamBackedDefaultLogger(logger, outputStreams);
    const loggerDecoder = writesLogger ? new StringDecoder("utf8") : undefined;
    return {
      write(chunk, callback) {
        try {
          if (writesLogger) {
            writeLoggerText(logger, decodeLoggerChunk(loggerDecoder, chunk));
          }
          writeOutputStreams(outputStreams, chunk, callback);
        } catch (error) {
          callback(error);
        }
      },
      end() {
        if (writesLogger) {
          writeLoggerText(logger, loggerDecoder.end());
        }
      },
    };
  }
  return undefined;
}

function apiCapturesOutput(options) {
  return Boolean(options.outputStream || options.logger);
}

function loggerOutputStream(logger) {
  if (
    logger &&
    streamBackedDefaultLogger(logger, [logger.options?.outputStream]) &&
    logger.options.outputStream instanceof Writable
  ) {
    return logger.options.outputStream;
  }
  return undefined;
}

function streamBackedDefaultLogger(logger, outputStreams) {
  return Boolean(
    outputStreams.length > 0 &&
      logger instanceof Logger &&
      logger.logCommandText === Logger.prototype.logCommandText &&
      logger.log === Logger.prototype.log
  );
}

function uniqueOutputStreams(...streams) {
  return streams.filter(
    (stream, index) =>
      stream instanceof Writable && streams.indexOf(stream) === index
  );
}

function writeOutputStreams(streams, chunk, callback) {
  if (streams.length === 0) {
    callback();
    return;
  }
  let pendingWrites = streams.length;
  let outputError;
  for (const stream of streams) {
    stream.write(chunk, (error) => {
      if (error && !outputError) {
        outputError = error;
      }
      pendingWrites -= 1;
      if (pendingWrites === 0) {
        callback(outputError);
      }
    });
  }
}

function decodeLoggerChunk(decoder, chunk) {
  return Buffer.isBuffer(chunk) ? decoder.write(chunk) : String(chunk);
}

function writeLoggerText(logger, text) {
  if (text === "") {
    return;
  }
  if (typeof logger.logCommandText === "function") {
    logger.logCommandText(text);
    return;
  }
  logger.log("", text);
}

function commandInfo(command) {
  return {
    name: command.name,
    command: command.command,
    env: command.env,
    cwd: command.cwd,
    prefixColor: command.prefixColor,
    ipc: command.ipc,
    raw: command.raw,
    hidden: command.hidden,
  };
}

function pushOption(args, name, value) {
  if (value !== undefined) {
    args.push(`${name}=${String(value)}`);
  }
}

function arrayOption(value) {
  if (value === undefined || value === null || value === false) {
    return [];
  }
  return Array.isArray(value) ? value : [value];
}

function commandNameSeparator(names) {
  let separator = "\x1f";
  while (names.some((name) => name.includes(separator))) {
    separator += "\x1f";
  }
  return separator;
}

function quoteArguments(args) {
  return args.map(shellQuote).join(" ");
}

function shellQuote(value) {
  if (process.platform === "win32") {
    return windowsShellQuote(value);
  }
  return posixShellQuote(value);
}

function posixShellQuote(value) {
  const text = String(value);
  if (text === "") {
    return "''";
  }
  if (/^[A-Za-z0-9_@%+=:,./-]+$/.test(text)) {
    return text;
  }
  return `'${text.replaceAll("'", "'\\''")}'`;
}

function windowsShellQuote(value) {
  const text = String(value);
  if (text === "") {
    return '""';
  }
  if (/^[A-Za-z0-9_@+=:,./-]+$/.test(text)) {
    return text;
  }
  return `"${text
    .replace(/(\\*)"/g, '$1$1\\"')
    .replace(/(\\+)$/g, "$1$1")
    .replace(/%/g, "^%")}"`;
}

function stringOrDefault(value, fallback) {
  return typeof value === "string" ? value : fallback;
}

function numberOrDefault(value, fallback) {
  return Number.isFinite(value) ? value : fallback;
}

function normalizeEnv(env) {
  return Object.fromEntries(
    Object.entries(env ?? {})
      .filter(([_key, value]) => value !== undefined)
      .map(([key, value]) => [key, String(value)])
  );
}

function closeEventsForSelector(events, selector) {
  const selectedIndex = Number(selector);
  if (Number.isNaN(selectedIndex)) {
    return events.filter((event) => event.command.name === selector);
  }
  return events.filter(
    (event) => event.command.name === selector || event.index === selectedIndex
  );
}

module.exports = {
  Command,
  InputHandler,
  KillOnSignal,
  KillOthers,
  LogError,
  LogExit,
  LogOutput,
  LogTimings,
  Logger,
  RestartProcess,
  concurrently,
  createConcurrently,
  default: concurrently,
};
