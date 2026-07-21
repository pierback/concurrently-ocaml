"use strict";

const { cpus } = require("node:os");
const {
  spawn: spawnChildProcess,
  spawnSync,
} = require("node:child_process");
const { Subject } = require("rxjs");
const {
  Command,
  canRequestKill: commandCanRequestKill,
  commandInfo,
} = require("./command");
const {
  commandCwd,
  invocationCwd,
  normalizeEnv,
} = require("./execution-context");
const {
  capturesOutput,
  createSpawnOutputDestination,
} = require("./output-destination");
const { formatDate } = require("./output-rendering");
const { createOutputSession } = require("./spawn-output-session");
const {
  arrayOption,
  hiddenCommands,
  killOthersConditions,
} = require("./run-policy");
const {
  apiShellInvocation,
  resolveApiShell,
} = require("./shell-command");
const { closeEventsSucceeded } = require("./run-result");

const SIGNALS = ["SIGINT", "SIGTERM", "SIGHUP"];
const SIGNAL_SUBSCRIBERS = new Map(
  SIGNALS.map((signal) => [signal, new Set()])
);
const SIGNAL_DISPATCHERS = new Map(
  SIGNALS.map((signal) => [
    signal,
    () => {
      for (const listener of [...SIGNAL_SUBSCRIBERS.get(signal)]) {
        listener(signal);
      }
    },
  ])
);
const SIGNAL_VALIDATION_PID = 2147483647;
const KILLED_COMMAND_CLEANUP_RETRY_DELAYS_MS = [25, 100, 500, 1000, 2500];

function runSpawnBackend(commands, options) {
  const outputDestination = createSpawnOutputDestination(options);
  const closeEvents = [];
  const hiddenPositions = new Set(hiddenCommands(commands, options));
  const output = createOutputSession(commands, options, outputDestination);
  const running = new Set();
  const scheduler = {
    settled: false,
    stopStarting: false,
    timers: new Set(),
    restartTimers: new Map(),
    pendingFailure: undefined,
    signalKillScheduled: false,
    settle: undefined,
  };
  const restartCounts = new Map();
  let nextIndex = 0;
  const maxProcesses = spawnApiMaxProcesses(options.maxProcesses, commands.length);
  const input = spawnApiAttachInput(commands, options, output);
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
      output.flushGrouped();
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
      output.flushGrouped();
      spawnApiRunTeardown(options, output)
        .then(() => {
          output.writeTimings(closeEvents);
          return output.finish();
        })
        .then(
          () => {
            if (closeEventsSucceeded(closeEvents, options.successCondition)) {
              resolve(closeEvents);
            } else {
              reject(closeEvents);
            }
          },
          (error) => {
            output.finish().then(
              () => reject(error),
              () => reject(error)
            );
          }
        );
    };
    scheduler.settle = settle;
    const startNext = () => {
      if (spawnApiAbortRequested(options)) {
        scheduler.stopStarting = true;
      }
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

  return result;
}

function spawnApiAbortRequested(options) {
  return Boolean(
    options.abortSignal?.aborted ||
      arrayOption(options.controllers).some(
        (controller) => controller?.abortController?.signal?.aborted
      )
  );
}

function subscribeSpawnApiCommand(command, state) {
  const {
    closeEvents,
    hidden,
    output,
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
  const formatter = output.formatterFor(command);
  command.spawnApiClose = new Subject();
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
          `${command.command} stopped at ${formatDate(
            event.endDate,
            options.timestampFormat
          )} after ${event.endDate.getTime() - event.startDate.getTime()}ms\n`
        );
      } else {
        formatter.event(
          `${command.command} started at ${formatDate(
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
    spawnApiCleanupKilledCommand(command);
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
    output.flushClosed(command);
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
        spawnApiKillOthers(running, options, scheduler, undefined, output);
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
  command.spawn = command.spawn ?? options.spawn ?? spawnApiDefaultSpawn;
  command.spawnOpts = command.spawnOpts ?? spawnApiOptions(command, options, hidden);
  command.killProcess =
    command.killProcess ?? ((signal) => spawnApiKillProcess(command, options, signal));
}

function spawnApiAttachInput(commands, options, output) {
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
      output.logGlobal(
        `Unable to find command "${target}", or it has no stdin open`
      );
      return;
    }
    if (!command.stdin && command.state !== "stopped") {
      output.logGlobal(
        `Unable to find command "${target}", or it has no stdin open`
      );
      return;
    }
    if (command.stdin) {
      if (!spawnApiWriteCommandInput(command, input)) {
        output.logGlobal(
          `Unable to find command "${target}", or it has no stdin open`
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
    fail,
    restartFormatter,
    restartDelay,
    running,
    scheduler,
    settle,
    startNext,
  } = state;
  output.setRestartPending(command, true);
  const timer = spawnApiSetTimer(scheduler, () => {
    scheduler.restartTimers.delete(command);
    if (scheduler.settled || spawnApiPendingRestartSuppressed(scheduler)) {
      output.setRestartPending(command, false);
      running.delete(command);
      startNext();
      settle();
      return;
    }
    output.setRestartPending(command, false);
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
    if (scheduler.settled) {
      return;
    }
    scheduler.caughtSignal = signal;
    scheduler.stopStarting = true;
    spawnApiCancelRestartTimers(scheduler, running);
    spawnApiMarkRunningCommandsKilled(running, signal);
    if (scheduler.signalKillScheduled) {
      return;
    }
    scheduler.signalKillScheduled = true;
    setImmediate(() => {
      scheduler.signalKillScheduled = false;
      if (scheduler.settled) {
        return;
      }
      try {
        spawnApiKillOthers(running, options, scheduler, scheduler.caughtSignal);
      } catch (_error) {
        for (const command of commands) {
          if (running.has(command)) {
            command.kill(scheduler.caughtSignal);
          }
        }
      }
      scheduler.settle?.();
    });
  };
  for (const signal of SIGNALS) {
    spawnApiSubscribeSignal(signal, signalListener);
  }
  return {
    finish() {
      for (const signal of SIGNALS) {
        spawnApiUnsubscribeSignal(signal, signalListener);
      }
    },
  };
}

function spawnApiSubscribeSignal(signal, listener) {
  const subscribers = SIGNAL_SUBSCRIBERS.get(signal);
  if (subscribers.size === 0) {
    process.on(signal, SIGNAL_DISPATCHERS.get(signal));
  }
  subscribers.add(listener);
}

function spawnApiUnsubscribeSignal(signal, listener) {
  const subscribers = SIGNAL_SUBSCRIBERS.get(signal);
  subscribers.delete(listener);
  if (subscribers.size === 0) {
    process.off(signal, SIGNAL_DISPATCHERS.get(signal));
  }
}

function spawnApiMarkRunningCommandsKilled(running, signal) {
  for (const command of running) {
    if (commandCanRequestKill(command)) {
      command.killed = true;
      command.killSignal = signal;
    }
  }
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
  command.killTreePids = [];
  command.killTreeProcessGroupIds = [];
  command.killBeforePid = false;
  command.pid = undefined;
  command.processGroupId = undefined;
  command.process = undefined;
  command.stdin = undefined;
  command.spawnApiCompleted = false;
  command.state = "stopped";
}

function spawnApiKillOthers(running, options, scheduler, signal, output) {
  const killSignal = signal ?? options.killSignal ?? "SIGTERM";
  const killableCommands = [...running];
  const killTargets = killableCommands.map((command) => ({
    command,
    pid: command.pid,
    runId: command.runId,
  }));
  if (output && killableCommands.length > 0) {
    output.logGlobal(`Sending ${killSignal} to other processes..`);
  }
  for (const runningCommand of killableCommands) {
    runningCommand.kill(killSignal);
  }
  const timeoutMs = Number(options.killTimeout);
  if (!timeoutMs || killSignal === "SIGKILL") {
    return;
  }
  spawnApiSetTimer(scheduler, () => {
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
      output.logGlobal(`Sending SIGKILL to ${stillKillable.length} processes..`);
    }
    for (const runningCommand of stillKillable) {
      runningCommand.kill("SIGKILL");
    }
  }, timeoutMs);
}

function spawnApiCleanupKilledCommand(command) {
  if (
    process.platform === "win32" ||
    !command.killed ||
    !Number.isInteger(command.pid)
  ) {
    return;
  }
  const killed = spawnApiKillTree(
    command.pid,
    "SIGKILL",
    true,
    command.killTreePids,
    command.processGroupId,
    command.killTreeProcessGroupIds
  );
  command.killTreePids = killed.pids;
  command.killTreeProcessGroupIds = killed.processGroupIds;
  spawnApiScheduleKilledCommandCleanup(command);
}

function spawnApiScheduleKilledCommandCleanup(command) {
  const pid = command.pid;
  const processGroupId = command.processGroupId;
  let killTreePids = [...command.killTreePids];
  let killTreeProcessGroupIds = [...command.killTreeProcessGroupIds];
  for (const delayMs of KILLED_COMMAND_CLEANUP_RETRY_DELAYS_MS) {
    const cleanupTimer = setTimeout(() => {
      try {
        const killed = spawnApiKillTree(
          pid,
          "SIGKILL",
          true,
          killTreePids,
          processGroupId,
          killTreeProcessGroupIds
        );
        killTreePids = killed.pids;
        killTreeProcessGroupIds = killed.processGroupIds;
      } catch (_error) {
        // Cleanup retries run after the public close path; they must not crash the host.
      }
    }, delayMs);
    cleanupTimer.unref?.();
  }
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
  scheduler.restartTimers.clear();
}

function spawnApiOptions(command, options, hidden) {
  const raw = typeof command.raw === "boolean" ? command.raw : Boolean(options.raw);
  const stdin = spawnApiForwardsInput(options) ? "pipe" : "ignore";
  const stdio = hidden
    ? [stdin, "ignore", "ignore"]
    : raw && !capturesOutput(options)
      ? [stdin, "inherit", "inherit"]
      : [stdin, "pipe", "pipe"];
  if (command.ipc != null) {
    if (!(command.ipc > 2)) {
      throw new Error("[concurrently] the IPC channel number should be > 2");
    }
    stdio[command.ipc] = "ipc";
  }
  return {
    cwd: commandCwd(command) ?? invocationCwd(options),
    env: {
      ...process.env,
      ...normalizeEnv(options.env),
      ...normalizeEnv(command.env),
    },
    detached: process.platform !== "win32",
    shell: resolveApiShell(options),
    stdio,
  };
}

function spawnApiTeardownOptions(options) {
  const output = capturesOutput(options) ? "pipe" : "inherit";
  return {
    cwd: invocationCwd(options),
    env: {
      ...process.env,
      ...normalizeEnv(options.env),
    },
    detached: process.platform !== "win32",
    shell: resolveApiShell(options),
    stdio: ["inherit", output, output],
  };
}

function spawnApiDefaultSpawn(command, options) {
  const { shell, ...spawnOptions } = options;
  const invocation = apiShellInvocation(resolveApiShell({ shell }), command);
  return spawnChildProcess(invocation.file, invocation.args, {
    ...spawnOptions,
    ...invocation.options,
  });
}

function spawnApiRunTeardown(options, output) {
  const teardownCommands = arrayOption(options.teardown);
  if (teardownCommands.length === 0) {
    return Promise.resolve();
  }
  return teardownCommands.reduce(
    (previous, command) =>
      previous.then((shouldContinue) =>
        shouldContinue
          ? spawnApiRunTeardownCommand(command, options, output)
          : false
      ),
    Promise.resolve(true)
  );
}

function spawnApiRunTeardownCommand(command, options, output) {
  return new Promise((resolve, reject) => {
    output.logGlobal(`Running teardown command "${command}"`);
    let child;
    try {
      child = (options.spawn ?? spawnApiDefaultSpawn)(
        command,
        spawnApiTeardownOptions(options)
      );
    } catch (error) {
      spawnApiLogTeardownError(command, error, output);
      reject(error);
      return;
    }
    child.stdout?.on?.("data", (chunk) => output.write(chunk));
    child.stderr?.on?.("data", (chunk) => output.write(chunk));
    child.once?.("error", (error) => {
      spawnApiLogTeardownError(command, error, output);
      reject(error);
    });
    child.once?.("close", (exitCode, signal) => {
      const code = exitCode ?? signal;
      output.logGlobal(`Teardown command "${command}" exited with code ${code}`);
      resolve(signal !== "SIGINT");
    });
  });
}

function spawnApiLogTeardownError(command, error, output) {
  const errorText = String(error instanceof Error ? error.stack || error : error);
  output.logGlobal(`Teardown command "${command}" errored:`);
  output.logGlobal(errorText);
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
  let killed;
  try {
    killed = spawnApiKillTree(
      command.pid,
      signal,
      false,
      command.killTreePids,
      command.processGroupId,
      command.killTreeProcessGroupIds
    );
  } catch (error) {
    try {
      const cleaned = spawnApiKillTree(
        command.pid,
        "SIGKILL",
        true,
        command.killTreePids,
        command.processGroupId,
        command.killTreeProcessGroupIds
      );
      command.killTreePids = cleaned.pids;
      command.killTreeProcessGroupIds = cleaned.processGroupIds;
      spawnApiScheduleKilledCommandCleanup(command);
    } catch (_cleanupError) {
      // Preserve the public signal validation error; cleanup is best-effort.
    }
    throw error;
  }
  command.killTreePids = killed.pids;
  command.killTreeProcessGroupIds = killed.processGroupIds;
  return true;
}

function spawnApiKillTree(
  pid,
  signal,
  force = false,
  knownDescendants = [],
  processGroupId = pid,
  knownProcessGroupIds = []
) {
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
    child.unref();
    return { pids: [], processGroupIds: [] };
  }
  const descendants = spawnApiDescendantProcesses(pid);
  const childPids = [...new Set([
    ...descendants.map((descendant) => descendant.pid),
    ...knownDescendants,
  ])].filter((childPid) => childPid !== pid);
  const processGroupIds = [...new Set([
    processGroupId,
    ...descendants.map((descendant) => descendant.processGroupId),
    ...knownProcessGroupIds,
  ])].filter((groupId) => Number.isInteger(groupId));
  for (const childPid of childPids) {
    spawnApiKillPid(childPid, killSignal);
  }
  for (const groupId of processGroupIds) {
    spawnApiKillProcessGroup(groupId, killSignal);
  }
  spawnApiKillPid(pid, killSignal);
  return { pids: childPids, processGroupIds };
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

function spawnApiKillProcessGroup(pid, signal) {
  if (!Number.isInteger(pid)) {
    return;
  }
  try {
    process.kill(-pid, signal);
  } catch (error) {
    if (error?.code !== "ESRCH" && error?.code !== "EPERM") {
      throw error;
    }
  }
}

function spawnApiDescendantProcesses(pid) {
  const processesByParent = spawnApiProcessesByParentPid();
  const descendants = [];
  const visited = new Set([pid]);
  const stack = [pid];
  while (stack.length > 0) {
    const parentPid = stack.pop();
    for (const child of processesByParent.get(parentPid) ?? []) {
      const childPid = child.pid;
      if (visited.has(childPid)) {
        continue;
      }
      visited.add(childPid);
      descendants.push(child);
      stack.push(childPid);
    }
  }

  return descendants.reverse();
}

function spawnApiProcessesByParentPid() {
  const processesByParent = new Map();
  const table = spawnApiPsProcessTable();
  for (const line of table.split(/\r?\n/)) {
    const [pidText, parentPidText, processGroupIdText] = line.trim().split(/\s+/);
    const pid = Number(pidText);
    const parentPid = Number(parentPidText);
    const processGroupId = Number(processGroupIdText);
    if (
      !Number.isInteger(pid) ||
      !Number.isInteger(parentPid) ||
      !Number.isInteger(processGroupId)
    ) {
      continue;
    }
    const children = processesByParent.get(parentPid) ?? [];
    children.push({ pid, processGroupId });
    processesByParent.set(parentPid, children);
  }

  return processesByParent;
}

function spawnApiPsProcessTable() {
  for (const command of ["/bin/ps", "/usr/bin/ps", "ps"]) {
    const result = spawnSync(command, ["-eo", "pid=,ppid=,pgid="], {
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

module.exports = { runSpawnBackend };
