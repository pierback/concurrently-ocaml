"use strict";

const { Writable } = require("node:stream");
const assert = require("node:assert");
const { Command } = require("./command");
const { prepareCommands } = require("./command-preparation");
const { Logger } = require("./logger");
const {
  arrayOption,
  normalizeApiOptions,
  requiresSpawnBackend,
} = require("./run-policy");
const { runOnFinishCallbacks } = require("./run-result");
const { runNativeBackend } = require("./native-backend");
const { runSpawnBackend } = require("./spawn-backend");

class PassThroughController {
  constructor(options) {
    this.options = options ?? {};
  }

  handle(commands) {
    return { commands };
  }
}

class InputHandler extends PassThroughController {
  constructor(options) {
    super(options);
  }

  handle(commands) {
    return super.handle(commands);
  }
}

class KillOnSignal extends PassThroughController {
  constructor(options) {
    super(options);
  }

  handle(commands) {
    return super.handle(commands);
  }
}

class KillOthers extends PassThroughController {
  constructor(options) {
    super(options);
    this.logger = this.options.logger;
    this.conditions = arrayOption(this.options.conditions);
    this.killSignal = this.options.killSignal;
    this.timeoutMs = this.options.timeoutMs;
  }

  handle(commands) {
    return super.handle(commands);
  }

  maybeForceKill(commands) {
    if (!this.timeoutMs || this.killSignal === "SIGKILL") {
      return;
    }
    setTimeout(() => {
      const killableCommands = commands.filter((command) => Command.canKill(command));
      if (killableCommands.length === 0) {
        return;
      }
      this.logger?.logGlobalEvent?.(
        `Sending SIGKILL to ${killableCommands.length} processes..`
      );
      killableCommands.forEach((command) => command.kill("SIGKILL"));
    }, this.timeoutMs);
  }
}

class LogError extends PassThroughController {
  constructor(options) {
    super(options);
  }

  handle(commands) {
    return super.handle(commands);
  }
}

class LogExit extends PassThroughController {
  constructor(options) {
    super(options);
  }

  handle(commands) {
    return super.handle(commands);
  }
}

class LogOutput extends PassThroughController {
  constructor(options) {
    super(options);
  }

  handle(commands) {
    return super.handle(commands);
  }
}

class LogTimings extends PassThroughController {
  constructor(options) {
    super(options);
    this.logger = this.options.logger;
  }

  handle(commands) {
    return super.handle(commands);
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

class RestartProcess extends PassThroughController {
  constructor(options) {
    super(options);
    const tries = this.options.tries;
    this.tries =
      tries == null ? 0 : Number(tries) < 0 ? Infinity : Number(tries);
  }

  handle(commands) {
    return super.handle(commands);
  }
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
