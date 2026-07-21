"use strict";

const { Writable } = require("node:stream");
const assert = require("node:assert");
const { Command } = require("./command");
const { prepareCommands } = require("./command-preparation");
const { Logger } = require("./logger");
const {
  formatDate,
  timingInfoFromCloseEvent,
} = require("./output-rendering");
const {
  arrayOption,
  normalizeApiOptions,
  requiresSpawnBackend,
} = require("./run-policy");
const { runOnFinishCallbacks } = require("./run-result");
const { runNativeBackend } = require("./native-backend");
const { runSpawnBackend } = require("./spawn-backend");

class InputHandler {
  constructor(options) {
    options = options ?? {};
    this.logger = options.logger;
    this.defaultInputTarget = options.defaultInputTarget || 0;
    this.inputStream = options.inputStream;
    this.pauseInputStreamOnFinish = options.pauseInputStreamOnFinish !== false;
  }

  handle(commands) {
    const inputStream = this.inputStream;
    if (!inputStream) {
      return { commands };
    }

    const commandsByIdentifier = new Map();
    for (const command of commands) {
      commandsByIdentifier.set(String(command.index), command);
      commandsByIdentifier.set(command.name, command);
    }

    const onData = (data) => {
      const text = String(data);
      const parts = text.split(/:(.+)/s);
      let target = parts[0];
      let command = commandsByIdentifier.get(target);
      let input;

      if (parts.length > 1 && command) {
        input = parts[1];
      } else {
        target = String(this.defaultInputTarget);
        command = commandsByIdentifier.get(target);
        input = text;
      }

      if (command?.stdin) {
        command.stdin.write(input);
      } else {
        this.logger?.logGlobalEvent?.(
          `Unable to find command "${target}", or it has no stdin open\n`
        );
      }
    };

    inputStream.on("data", onData);
    return {
      commands,
      onFinish: once(() => {
        inputStream.off("data", onData);
        if (this.pauseInputStreamOnFinish) {
          inputStream.pause();
        }
      }),
    };
  }
}

class KillOnSignal {
  constructor(_options) {}

  handle(_commands) {
    throw unsupportedControllerError("KillOnSignal");
  }
}

class KillOthers {
  constructor(options) {
    options = options ?? {};
    this.logger = options.logger;
    this.abortController = options.abortController;
    this.conditions = arrayOption(options.conditions);
    this.killSignal = options.killSignal;
    this.timeoutMs = options.timeoutMs;
    this.forceKillTimers = new Set();
  }

  handle(commands) {
    const conditions = this.conditions.filter(
      (condition) => condition === "failure" || condition === "success"
    );
    if (conditions.length === 0) {
      return { commands };
    }

    const subscriptions = commands.map((command) =>
      command.close.subscribe(({ exitCode }) => {
        const state = exitCode === 0 ? "success" : "failure";
        if (!conditions.includes(state)) {
          return;
        }

        this.abortController?.abort();
        const killableCommands = commands.filter((candidate) =>
          Command.canKill(candidate)
        );
        if (killableCommands.length === 0) {
          return;
        }

        this.logger?.logGlobalEvent?.(
          `Sending ${this.killSignal || "SIGTERM"} to other processes..`
        );
        killableCommands.forEach((candidate) => candidate.kill(this.killSignal));
        this.maybeForceKill(killableCommands);
      })
    );

    return {
      commands,
      onFinish: once(() => {
        unsubscribeAll(subscriptions);
        for (const timer of this.forceKillTimers) {
          clearTimeout(timer);
        }
        this.forceKillTimers.clear();
      }),
    };
  }

  maybeForceKill(commands) {
    if (!this.timeoutMs || this.killSignal === "SIGKILL") {
      return;
    }
    const timer = setTimeout(() => {
      this.forceKillTimers.delete(timer);
      const killableCommands = commands.filter((command) => Command.canKill(command));
      if (killableCommands.length === 0) {
        return;
      }
      this.logger?.logGlobalEvent?.(
        `Sending SIGKILL to ${killableCommands.length} processes..`
      );
      killableCommands.forEach((command) => command.kill("SIGKILL"));
    }, this.timeoutMs);
    this.forceKillTimers.add(timer);
  }
}

class LogError {
  constructor(options) {
    options = options ?? {};
    this.logger = options.logger;
  }

  handle(commands) {
    const subscriptions = commands.map((command) =>
      command.error.subscribe((event) => {
        this.logger?.logCommandEvent?.(
          `Error occurred when executing command: ${command.command}`,
          command
        );
        const errorText = String(
          event instanceof Error ? event.stack || event : event
        );
        this.logger?.logCommandEvent?.(errorText, command);
      })
    );
    return {
      commands,
      onFinish: once(() => unsubscribeAll(subscriptions)),
    };
  }
}

class LogExit {
  constructor(options) {
    options = options ?? {};
    this.logger = options.logger;
  }

  handle(commands) {
    const subscriptions = commands.map((command) =>
      command.close.subscribe(({ exitCode }) => {
        this.logger?.logCommandEvent?.(
          `${command.command} exited with code ${exitCode}`,
          command
        );
      })
    );
    return {
      commands,
      onFinish: once(() => unsubscribeAll(subscriptions)),
    };
  }
}

class LogOutput {
  constructor(options) {
    options = options ?? {};
    this.logger = options.logger;
  }

  handle(commands) {
    const subscriptions = commands.flatMap((command) => [
      command.stdout.subscribe((text) =>
        this.logger?.logCommandText?.(text.toString(), command)
      ),
      command.stderr.subscribe((text) =>
        this.logger?.logCommandText?.(text.toString(), command)
      ),
    ]);
    return {
      commands,
      onFinish: once(() => unsubscribeAll(subscriptions)),
    };
  }
}

class LogTimings {
  constructor(options) {
    options = options ?? {};
    this.logger = options.logger;
    this.timestampFormat = options.timestampFormat || "yyyy-MM-dd HH:mm:ss.SSS";
  }

  handle(commands) {
    if (!this.logger) {
      return { commands };
    }

    const subscriptions = [];
    const closeSubscriptions = [];
    const closeEvents = [];
    for (const command of commands) {
      const timerSubscription = command.timer.subscribe(
        ({ startDate, endDate }) => {
          if (endDate) {
            const durationMs = endDate.getTime() - startDate.getTime();
            this.logger?.logCommandEvent?.(
              `${command.command} stopped at ${formatDate(
                endDate,
                this.timestampFormat
              )} after ${durationMs.toLocaleString()}ms`,
              command
            );
          } else {
            this.logger?.logCommandEvent?.(
              `${command.command} started at ${formatDate(
                startDate,
                this.timestampFormat
              )}`,
              command
            );
          }
        }
      );
      const closeSubscription = command.close.subscribe((event) => {
        if (closeEvents.length >= commands.length) {
          return;
        }
        closeEvents.push(event);
        if (closeEvents.length === commands.length) {
          unsubscribeAll(closeSubscriptions);
        }
      });
      closeSubscriptions.push(closeSubscription);
      subscriptions.push(timerSubscription, closeSubscription);
    }

    return {
      commands,
      onFinish: once(() => {
        if (commands.length > 0 && closeEvents.length === commands.length) {
          this.printExitInfoTimingTable(closeEvents);
        }
        unsubscribeAll(subscriptions);
      }),
    };
  }

  printExitInfoTimingTable(exitInfos) {
    const sorted = [...exitInfos].sort(
      (left, right) =>
        right.timings.durationSeconds - left.timings.durationSeconds
    );
    const rows = sorted.map(LogTimings.mapCloseEventToTimingInfo);
    this.logger?.logGlobalEvent?.("Timings:");
    this.logger?.logTable?.(rows);
    return exitInfos;
  }

  static mapCloseEventToTimingInfo(event) {
    return timingInfoFromCloseEvent(event);
  }
}

class RestartProcess {
  constructor(options) {
    options = options ?? {};
    const tries = options.tries;
    this.tries =
      tries == null ? 0 : Number(tries) < 0 ? Infinity : Number(tries);
  }

  handle(commands) {
    if (this.tries === 0) {
      return { commands };
    }
    throw unsupportedControllerError("RestartProcess");
  }
}

function once(callback) {
  let called = false;
  return () => {
    if (called) {
      return;
    }
    called = true;
    return callback();
  };
}

function unsubscribeAll(subscriptions) {
  subscriptions.forEach((subscription) => subscription.unsubscribe());
}

function finishAfterSetupFailure(callbacks) {
  for (const callback of callbacks) {
    try {
      Promise.resolve(callback()).catch(() => {});
    } catch (_error) {
      // Preserve the setup error that caused cleanup.
    }
  }
}

function unsupportedControllerError(name) {
  return new Error(`${name} is not supported by the current scheduler`);
}

function concurrently(commandInputs, options = {}) {
  assertCommandInputs(commandInputs);
  assert.ok(commandInputs.length > 0, "[concurrently] no commands provided");
  assertNativeOptions(options);
  options = normalizeApiOptions(options);

  const commands = prepareCommands(commandInputs, options);
  const controlled = applyControllers(commands, options.controllers);
  const controlledCommands = controlled.commands;
  let rawResult;
  try {
    if (
      controlledCommands.length === 0 &&
      arrayOption(options.teardown).length === 0
    ) {
      rawResult = Promise.resolve([]);
    } else if (requiresSpawnBackend(controlledCommands, options)) {
      rawResult = runSpawnBackend(controlledCommands, options);
    } else {
      rawResult = runNativeBackend(controlledCommands, options);
    }
    return {
      commands: controlledCommands,
      result: runOnFinishCallbacks(rawResult, controlled.onFinishCallbacks),
    };
  } catch (error) {
    finishAfterSetupFailure(controlled.onFinishCallbacks);
    throw error;
  }
}

function createConcurrently(commandInputs, options) {
  return concurrently(commandInputs, options);
}

function assertCommandInputs(commandInputs) {
  assert.ok(Array.isArray(commandInputs), "[concurrently] commands should be an array");
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
  if (options.shell !== undefined && typeof options.shell !== "string") {
    throw new Error("options.shell must be a string");
  }
}

function assertNativeLogger(logger) {
  if (
    typeof logger.logCommandText !== "function" &&
    typeof logger.log !== "function"
  ) {
    throw new Error(
      "options.logger must implement logCommandText(text, command) or log(prefix, text, command)"
    );
  }
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
  try {
    for (const controller of controllers) {
      if (!controller || typeof controller.handle !== "function") {
        throw new Error(
          "options.controllers entries must implement handle(commands)"
        );
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
  } catch (error) {
    finishAfterSetupFailure(onFinishCallbacks);
    throw error;
  }
}

function assertUniqueCommandIndexes(commands) {
  const indexes = new Set();
  for (const command of commands) {
    if (!(command instanceof Command)) {
      throw new Error("controllers must return Command objects");
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
