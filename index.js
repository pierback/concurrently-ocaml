"use strict";

const { existsSync, mkdtempSync, readFileSync, rmSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { isAbsolute, join, resolve } = require("node:path");
const { runNative } = require("./npm/lib/native");

const unsupportedControllerExports = [
  "Command",
  "InputHandler",
  "KillOnSignal",
  "KillOthers",
  "LogError",
  "LogExit",
  "LogOutput",
  "LogTimings",
  "Logger",
  "RestartProcess",
];

const optionToFlag = [
  ["prefix", "--prefix"],
  ["prefixLength", "--prefix-length"],
  ["timestampFormat", "--timestamp-format"],
  ["maxProcesses", "--max-processes"],
  ["successCondition", "--success"],
  ["restartDelay", "--restart-after"],
  ["restartTries", "--restart-tries"],
  ["killSignal", "--kill-signal"],
  ["killTimeout", "--kill-timeout"],
  ["defaultInputTarget", "--default-input-target"],
];

const arrayOptionToFlag = [
  ["teardown", "--teardown"],
];

const normalizeCommand = (input, index) => {
  if (typeof input === "string") {
    return { command: input, name: "", env: {}, index };
  }
  if (!input || typeof input !== "object") {
    throw new TypeError("[concurrently] command must be a string or object");
  }
  if (!input.command) {
    throw new Error("[concurrently] command cannot be empty");
  }
  const unsupported = [];
  if (input.ipc !== undefined) unsupported.push("ipc");
  if (unsupported.length > 0) {
    throw new Error(
      `[concurrently-ml] JS command fields not supported by the native-backed API yet: ${unsupported.join(", ")}`
    );
  }
  return {
    command: input.command,
    name: input.name || "",
    prefixColor: input.prefixColor,
    cwd: input.cwd,
    env: input.env || {},
    raw: input.raw,
    index,
  };
};

const normalizeCommands = (commands) => {
  if (!Array.isArray(commands)) {
    throw new TypeError("[concurrently] commands should be an array");
  }
  if (commands.length === 0) {
    throw new Error("[concurrently] no commands provided");
  }
  return commands.map(normalizeCommand);
};

const pushValueFlag = (args, flag, value) => {
  if (value !== undefined) {
    args.push(flag, String(value));
  }
};

const pushRepeatedFlag = (args, flag, value) => {
  if (value === undefined) {
    return;
  }
  const values = Array.isArray(value) ? value : [value];
  for (const entry of values) {
    args.push(flag, String(entry));
  }
};

const pushCsvFlag = (args, flag, value) => {
  if (value === undefined) {
    return;
  }
  const values = Array.isArray(value) ? value : [value];
  args.push(flag, values.map(String).join(","));
};

const optionArray = (value) => {
  if (value === undefined) {
    return [];
  }
  return Array.isArray(value) ? value : [value];
};

const commandCwdForNative = (commandCwd, options) => {
  if (commandCwd === undefined) {
    return undefined;
  }
  const cwd = String(commandCwd);
  if (options.cwd === undefined || isAbsolute(cwd)) {
    return cwd;
  }
  return resolve(String(options.cwd), cwd);
};

const pushApiCommandMetadata = (args, commands, options) => {
  for (const command of commands) {
    if (command.name !== "") {
      args.push("--api-command-name", `${command.index}=${command.name}`);
    }
    const commandCwd = commandCwdForNative(command.cwd, options);
    if (commandCwd !== undefined) {
      args.push("--api-command-cwd", `${command.index}=${commandCwd}`);
    }
    if (command.raw !== undefined) {
      args.push(
        "--api-command-raw",
        `${command.index}=${command.raw ? "true" : "false"}`
      );
    }
    for (const [key, value] of Object.entries(command.env)) {
      if (value !== undefined) {
        args.push("--api-command-env", `${command.index}=${key}=${String(value)}`);
      }
    }
  }
};

const cliArgsFor = (commands, options, closeEventsPath) => {
  const args = [
    "--api-close-events-file",
    closeEventsPath,
    "--api-output-events-fd",
    "3",
  ];
  pushApiCommandMetadata(args, commands, options);
  if (options.raw) args.push("--raw");
  if (options.group) args.push("--group");
  if (options.padPrefix) args.push("--pad-prefix");
  if (options.timings) args.push("--timings");
  if (options.handleInput || options.inputStream) args.push("--handle-input");
  if (options.cwd) args.push("--cwd", String(options.cwd));
  if (options.additionalArguments !== undefined) {
    args.push("--passthrough-arguments");
  }
  pushCsvFlag(args, "--hide", options.hide);

  for (const [key, flag] of optionToFlag) {
    pushValueFlag(args, flag, options[key]);
  }

  for (const [key, flag] of arrayOptionToFlag) {
    if (key !== "additionalArguments") {
      pushRepeatedFlag(args, flag, options[key]);
    }
  }

  const killOthersOn = options.killOthersOn ?? options.killOthers;
  if (killOthersOn !== undefined) {
    for (const condition of Array.isArray(killOthersOn) ? killOthersOn : [killOthersOn]) {
      if (condition === "success") args.push("--kill-others");
      else if (condition === "failure") args.push("--kill-others-on-fail");
      else {
        throw new Error(
          `[concurrently-ml] unsupported kill condition for native-backed API: ${condition}`
        );
      }
    }
  }

  const optionPrefixColors = optionArray(options.prefixColors).map(String);
  const colors =
    optionPrefixColors.length === 0
      ? commands.map((command) => command.prefixColor || "")
      : commands.map(
          (command, index) =>
            command.prefixColor ||
            optionPrefixColors[index] ||
            optionPrefixColors[optionPrefixColors.length - 1] ||
            ""
        );
  if (colors.some((color) => color !== "") || optionPrefixColors.length > 0) {
    args.push("--prefix-colors", colors.join(","));
  }

  args.push("--");
  for (const command of commands) {
    args.push(command.command);
  }
  if (options.additionalArguments !== undefined) {
    args.push("--", ...options.additionalArguments.map(String));
  }
  return args;
};

const createReplayObservable = () => {
  const listeners = new Set();
  const values = [];
  let completed = false;

  const emit = (value) => {
    if (completed) {
      return;
    }
    values.push(value);
    for (const listener of listeners) {
      listener(value);
    }
  };

  const complete = () => {
    completed = true;
    listeners.clear();
  };

  const subscribe = (listener) => {
    if (typeof listener !== "function") {
      throw new TypeError("[concurrently] observable listener must be a function");
    }
    for (const value of values) {
      listener(value);
    }
    if (!completed) {
      listeners.add(listener);
    }
    return {
      unsubscribe() {
        listeners.delete(listener);
      },
    };
  };

  return {
    emit,
    complete,
    subscribe,
    on(_event, listener) {
      return subscribe(listener);
    },
    once(_event, listener) {
      let subscription;
      subscription = subscribe((value) => {
        if (subscription) {
          subscription.unsubscribe();
        }
        listener(value);
      });
      return subscription;
    },
    addListener(_event, listener) {
      return subscribe(listener);
    },
  };
};

const createSubjectObservable = () => {
  const listeners = new Set();
  let completed = false;

  const emit = (value) => {
    if (completed) {
      return;
    }
    for (const listener of listeners) {
      listener(value);
    }
  };

  const complete = () => {
    completed = true;
    listeners.clear();
  };

  const subscribe = (listener) => {
    if (typeof listener !== "function") {
      throw new TypeError("[concurrently] observable listener must be a function");
    }
    if (!completed) {
      listeners.add(listener);
    }
    return {
      unsubscribe() {
        listeners.delete(listener);
      },
    };
  };

  return {
    emit,
    complete,
    subscribe,
    on(_event, listener) {
      return subscribe(listener);
    },
    once(_event, listener) {
      let subscription;
      subscription = subscribe((value) => {
        if (subscription) {
          subscription.unsubscribe();
        }
        listener(value);
      });
      return subscription;
    },
    addListener(_event, listener) {
      return subscribe(listener);
    },
  };
};

const unsupportedCommandHandleMember = (member) => {
  const fail = () => {
    throw new Error(
      `[concurrently-ml] command ${member} is not supported by the native-backed JS API yet`
    );
  };
  return {
    on: fail,
    once: fail,
    addListener: fail,
    subscribe: fail,
  };
};

const createCommandHandle = (command) => {
  return {
    index: command.index,
    name: command.name,
    command: command.command,
    prefixColor: command.prefixColor,
    env: command.env,
    cwd: command.cwd,
    ipc: undefined,
    close: createReplayObservable(),
    stdout: createSubjectObservable(),
    stderr: createSubjectObservable(),
    timer: createReplayObservable(),
    stateChange: createReplayObservable(),
    error: unsupportedCommandHandleMember("error observable"),
    killed: false,
    exited: false,
    state: "stopped",
    process: undefined,
    pid: undefined,
    stdin: undefined,
    kill() {
      throw new Error(
        "[concurrently-ml] per-command kill is not supported by the native-backed JS API yet"
      );
    },
  };
};

const exitCodeValue = (value) => {
  const number = Number(value);
  return Number.isInteger(number) && String(number) === String(value) ? number : value;
};

const stripAnsi = (text) => text.replace(/\x1b\[[0-9;]*m/g, "");

const observeCloseStatus = (statuses, commands, line) => {
  line = stripAnsi(line);
  const match = line.match(/^\[[^\]]*\] (.*) exited with code (.+)$/);
  if (!match) {
    return;
  }
  const commandText = match[1];
  const exitCode = exitCodeValue(match[2]);
  const command = commands.find(
    (candidate) =>
      candidate.command === commandText && !statuses.has(candidate.index)
  );
  if (command) {
    statuses.set(command.index, {
      exitCode,
      killed: typeof exitCode === "string" && exitCode.startsWith("SIG"),
    });
  }
};

const observeOutput = (statuses, commands, readState, chunk, outputStream) => {
  outputStream.write(chunk);
  readState.buffer += chunk.toString();
  const lines = readState.buffer.split(/\r?\n/);
  readState.buffer = lines.pop() || "";
  for (const line of lines) {
    observeCloseStatus(statuses, commands, line);
  }
};

const closeEventsFor = (commands, statuses, code, signal, startedAt, endedAt) =>
  commands.map((command) => ({
    command,
    index: command.index,
    killed: statuses.get(command.index)?.killed ?? (signal !== null),
    exitCode: statuses.get(command.index)?.exitCode ?? (signal || code || 0),
    timings: {
      startDate: startedAt,
      endDate: endedAt,
      durationSeconds: (endedAt.getTime() - startedAt.getTime()) / 1000,
    },
  }));

const createApiCloseEventsPath = () => {
  const directory = mkdtempSync(join(tmpdir(), "concurrently-ml-api-"));
  return {
    directory,
    path: join(directory, "close-events.json"),
  };
};

const readApiCloseEvents = (closeEventsFile) => {
  return () => {
    let data = "";
    try {
      if (!existsSync(closeEventsFile.path)) {
        return null;
      }
      data = readFileSync(closeEventsFile.path, "utf8");
    } finally {
      rmSync(closeEventsFile.directory, { recursive: true, force: true });
    }
    const trimmed = data.trim();
    if (trimmed === "") {
      return null;
    }
    return JSON.parse(trimmed);
  };
};

const nativeCloseEventsFor = (commands, nativeEvents, fallbackEvents) => {
  if (!Array.isArray(nativeEvents)) {
    return fallbackEvents;
  }
  if (nativeEvents.length === 0) {
    return [];
  }
  const finalEventsByIndex = new Map();
  for (const event of nativeEvents) {
    if (!Number.isInteger(event.index)) {
      continue;
    }
    finalEventsByIndex.set(event.index, event);
  }
  return commands.flatMap((command) => {
    const event = finalEventsByIndex.get(command.index);
    if (!event) {
      return [];
    }
    return [
      {
        command,
        index: command.index,
        killed: event.killed === true,
        exitCode: event.exitCode,
        timings: {
          startDate: new Date(event.timings.startedAt * 1000),
          endDate: new Date(event.timings.endedAt * 1000),
          durationSeconds: event.timings.durationSeconds,
        },
      },
    ];
  });
};

const emitCommandState = (command, state) => {
  if (command.state === state) {
    return;
  }
  command.state = state;
  command.stateChange.emit(state);
};

const emitTimerStart = (command, at) => {
  const startDate = new Date(at * 1000);
  command.startedAt = startDate;
  command.timer.emit({ startDate });
};

const emitTimerEnd = (command, at) => {
  const endDate = new Date(at * 1000);
  const startDate = command.startedAt || endDate;
  command.timer.emit({ startDate, endDate });
};

const handleApiOutputEvent = (commandHandles, event) => {
  if (!event || !Number.isInteger(event.index)) {
    return;
  }
  const command = commandHandles[event.index];
  if (!command) {
    return;
  }
  if (event.type === "output") {
    const chunk = Buffer.from(String(event.chunkHex || ""), "hex");
    if (event.stream === "stdout") {
      command.stdout.emit(chunk);
    } else if (event.stream === "stderr") {
      command.stderr.emit(chunk);
    }
    return;
  }
  if (event.type !== "lifecycle") {
    return;
  }
  if (event.state === "started") {
    emitCommandState(command, "started");
    emitTimerStart(command, Number(event.at));
  } else if (event.state === "exited") {
    command.killed = event.killed === true;
    command.exited = true;
    emitCommandState(command, "exited");
    emitTimerEnd(command, Number(event.at));
  }
};

const observeApiOutputEvents = (stream, commandHandles, fail) => {
  const state = { buffer: "" };
  stream.on("data", (chunk) => {
    state.buffer += chunk.toString("utf8");
    const lines = state.buffer.split("\n");
    state.buffer = lines.pop() || "";
    for (const line of lines) {
      if (line === "") {
        continue;
      }
      try {
        handleApiOutputEvent(commandHandles, JSON.parse(line));
      } catch (error) {
        fail(error);
        return;
      }
    }
  });
  stream.on("end", () => {
    const line = state.buffer.trim();
    if (line === "") {
      return;
    }
    try {
      handleApiOutputEvent(commandHandles, JSON.parse(line));
    } catch (error) {
      fail(error);
    }
  });
  stream.on("error", fail);
};

function concurrently(inputs, options = {}) {
  const commands = normalizeCommands(inputs);
  const commandHandles = commands.map(createCommandHandle);
  const startedAt = new Date();
  const closeEventsFile = createApiCloseEventsPath();
  const child = runNative(cliArgsFor(commands, options, closeEventsFile.path), {
    stdio: [
      options.inputStream || options.handleInput ? "pipe" : "ignore",
      "pipe",
      "pipe",
      "pipe",
    ],
  });

  const parseApiCloseEvents = readApiCloseEvents(closeEventsFile);
  const outputStream = options.outputStream || process.stdout;
  const errorStream = options.errorStream || process.stderr;
  const closeStatuses = new Map();
  const stdoutReadState = { buffer: "" };
  const stderrReadState = { buffer: "" };
  let apiOutputEventError = null;
  const failApiOutputEvents = (error) => {
    apiOutputEventError = error;
    child.kill();
  };
  if (child.stdio[3]) {
    observeApiOutputEvents(child.stdio[3], commandHandles, failApiOutputEvents);
  }
  child.stdout.on("data", (chunk) => {
    observeOutput(closeStatuses, commands, stdoutReadState, chunk, outputStream);
  });
  child.stderr.on("data", (chunk) => {
    observeOutput(closeStatuses, commands, stderrReadState, chunk, errorStream);
  });
  if (options.inputStream && child.stdin) {
    options.inputStream.pipe(child.stdin);
  } else if (options.handleInput && child.stdin) {
    process.stdin.pipe(child.stdin);
  }

  const result = new Promise((resolve, reject) => {
    child.on("error", (error) => {
      rmSync(closeEventsFile.directory, { recursive: true, force: true });
      reject(error);
    });
    child.on("close", (code, signal) => {
      const endedAt = new Date();
      if (apiOutputEventError) {
        reject(apiOutputEventError);
        return;
      }
      if (stdoutReadState.buffer !== "") {
        observeCloseStatus(closeStatuses, commands, stdoutReadState.buffer);
      }
      if (stderrReadState.buffer !== "") {
        observeCloseStatus(closeStatuses, commands, stderrReadState.buffer);
      }
      const fallbackCloseEvents = closeEventsFor(
        commands,
        closeStatuses,
        code,
        signal,
        startedAt,
        endedAt
      );
      let closeEvents;
      try {
        closeEvents = nativeCloseEventsFor(
          commands,
          parseApiCloseEvents(),
          fallbackCloseEvents
        );
      } catch (error) {
        reject(error);
        return;
      }
      for (const closeEvent of closeEvents) {
        const command = commandHandles[closeEvent.index];
        if (!command) {
          continue;
        }
        command.killed = closeEvent.killed;
        command.exited = true;
        if (command.state !== "exited") {
          emitCommandState(command, "exited");
          emitTimerEnd(command, closeEvent.timings.endDate.getTime() / 1000);
        }
        command.close.emit(closeEvent);
        command.close.complete();
      }
      commandHandles.forEach((command) => {
        command.close.complete();
        command.stdout.complete();
        command.stderr.complete();
        command.timer.complete();
        command.stateChange.complete();
      });
      if (code === 0 && signal === null) {
        resolve(closeEvents);
      } else {
        reject(closeEvents);
      }
    });
  });

  return { result, commands: commandHandles };
}

function createConcurrently(defaultOptions = {}) {
  return (inputs, options = {}) =>
    concurrently(inputs, { ...defaultOptions, ...options });
}

module.exports = concurrently;
module.exports.default = concurrently;
module.exports.concurrently = concurrently;
module.exports.createConcurrently = createConcurrently;

for (const name of unsupportedControllerExports) {
  module.exports[name] = undefined;
}
