"use strict";

const {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} = require("node:fs");
const { constants: osConstants, tmpdir } = require("node:os");
const { join, resolve } = require("node:path");
const { Writable } = require("node:stream");
const { runNative } = require("./native");

const SHORTCUT_RUNNERS = new Set(["npm", "yarn", "pnpm", "bun", "node", "deno"]);

class NativeApiUnsupportedError extends Error {
  constructor(feature) {
    super(`${feature} is not supported by the native concurrently-ml JavaScript facade`);
    this.name = "NativeApiUnsupportedError";
  }
}

class Command {
  constructor(info = {}) {
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
    this.killProcess = undefined;
  }

  start() {
    throw new NativeApiUnsupportedError("Command.start()");
  }

  send() {
    throw new NativeApiUnsupportedError("Command.send()");
  }

  kill(code = "SIGTERM") {
    assertCatchableKillSignal(code);
    if (!this.killProcess) {
      throw new NativeApiUnsupportedError("Command.kill()");
    }
    this.killProcess(code);
  }

  static canKill(command) {
    return Boolean(
      command &&
        Number.isInteger(command.pid) &&
        typeof command.killProcess === "function"
    );
  }
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
  if (commands.length === 0 && arrayOption(options.teardown).length === 0) {
    return { commands, result: Promise.resolve([]) };
  }
  expandAdditionalArguments(commands, options.additionalArguments);
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
    invocation = nativeInvocation(commands, options, eventDir);
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

  const killWrappedCommand = (code) => {
    if (commands[0].exited) {
      return false;
    }
    writeFileSync(invocation.killPaths[0], JSON.stringify(code), { mode: 0o600 });
    commands[0].killed = true;
    commands[0].killSignal = code;
    return true;
  };

  if (commands.length === 1) {
    commands[0].state = "started";
    commands[0].pid = child.pid;
    commands[0].stdin = child.stdin;
    commands[0].killProcess = killWrappedCommand;
  }

  const waitForOutput = attachStreams(child, options);
  const finishInput = attachInput(child, options);

  const result = new Promise((resolve, reject) => {
    child.on("error", (error) => {
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
      finishInput();
      const endedAt = new Date();
      const exitCode = signal ?? (code ?? 1);
      const events = readCommandEvents({
        commands,
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
          if (code === 0) {
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

  return { commands, result };
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
  for (const key of ["controllers", "logger", "spawn", "kill"]) {
    if (
      Object.prototype.hasOwnProperty.call(options, key) &&
      options[key] !== undefined
    ) {
      throw new NativeApiUnsupportedError(`options.${key}`);
    }
  }
  if (
    options.outputStream !== undefined &&
    !(options.outputStream instanceof Writable)
  ) {
    throw new Error("options.outputStream must be a writable stream");
  }
}

function assertCatchableKillSignal(signal) {
  const normalizedSignal = String(signal).trim().toUpperCase();
  const numericSignal = typeof signal === "number" ? signal : Number.NaN;
  if (
    normalizedSignal === "SIGKILL" ||
    normalizedSignal === "SIGSTOP" ||
    numericSignal === osConstants.signals.SIGKILL ||
    numericSignal === osConstants.signals.SIGSTOP
  ) {
    throw new NativeApiUnsupportedError(`Command.kill(${normalizedSignal})`);
  }
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
  pushOption(args, "--success", options.successCondition);
  pushOption(args, "--prefix", options.prefix);
  pushOption(args, "--prefix-length", options.prefixLength);
  pushOption(args, "--timestamp-format", options.timestampFormat);
  pushOption(args, "--default-input-target", options.defaultInputTarget);
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
    (options.outputStream && !forceColorEnabled(env))
  ) {
    args.push("--no-color");
  }

  const publicNames = commands.map((command) => command.name);
  if (publicNames.some((name) => name !== "")) {
    const names = publicNames.map((name, index) => name || String(index));
    const nameSeparator = commandNameSeparator(names);
    pushOption(args, "--api-name-separator", nameSeparator);
    pushOption(args, "--names", names.join(nameSeparator));
  }

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
        commandEnvPaths[command.index],
        commandCwd(command)
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
  cwd
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
    "const forward=signal=>{if(child&&child.exitCode===null&&child.signalCode===null){if(process.platform!=='win32'){try{process.kill(-child.pid,signal);return}catch(_){}}try{child.kill(signal)}catch(_){}}}",
    "const onSignal=signal=>{write({code:null,signal});forward(signal);if(!exiting){exiting=true;setTimeout(()=>process.exit(exitCode(signal)),5000).unref()}}",
    "const pollKill=()=>{try{if(fs.existsSync(killFile)){const signal=JSON.parse(fs.readFileSync(killFile,'utf8'));fs.rmSync(killFile,{force:true});onSignal(signal)}}catch(_){}}",
    "for(const signal of ['SIGHUP','SIGINT','SIGTERM','SIGQUIT','SIGUSR1','SIGUSR2','SIGBREAK']){if(signalNumbers[signal]){try{process.on(signal,()=>onSignal(signal))}catch(_){}}}",
    "fs.writeFileSync(startFile,String(startMs))",
    "const spawnOptions={shell:true,detached:process.platform!=='win32',stdio:[childStdin,'inherit','inherit'],env:{...process.env,...commandEnv}}",
    "if(cwd!==undefined)spawnOptions.cwd=cwd",
    "child=cp.spawn(cmd,spawnOptions)",
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
    command.exited = true;
    command.killed = killed;
    command.state = "exited";
    const commandStartMs =
      event?.startMs ??
      readCommandStartMs(eventStartPath(eventDir, command.index)) ??
      startedAt.getTime();
    const commandStartedAt = new Date(
      commandStartMs
    );
    const commandEndedAt = new Date(event?.endMs ?? endedAt.getTime());
    return [{
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
    }];
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

function readCommandStartMs(path) {
  if (!existsSync(path)) {
    return undefined;
  }
  const timestamp = Number(readFileSync(path, "utf8"));
  return Number.isFinite(timestamp) ? timestamp : undefined;
}

function writeCommandEnvironmentFiles(
  eventDir,
  commands,
  options,
  inheritedCommandEnv
) {
  return commands.map((command) => {
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
    return path;
  });
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
    return arrayOption(options.prefixColors).join(",");
  }
  const colors = commands.map((command) => command.prefixColor);
  return colors.some(Boolean)
    ? colors.map((color) => color || "reset").join(",")
    : undefined;
}

function forceColorEnabled(env) {
  const value = env.FORCE_COLOR;
  return value !== undefined && value !== "0" && value !== "false";
}

function hiddenCommands(commands, options) {
  return [
    ...commands
      .filter((command) => command.hidden)
      .map((command) => String(command.index)),
    ...arrayOption(options.hide).flatMap((identifier) =>
      hideIdentifiers(commands, identifier)
    ),
  ].map(String);
}

function hideIdentifiers(commands, identifier) {
  if (typeof identifier === "number") {
    return [String(identifier)];
  }
  const value = String(identifier);
  const matchingIndexes = commands
    .filter((command) => command.name === value)
    .map((command) => String(command.index));
  return matchingIndexes.length > 0 ? matchingIndexes : [value];
}

function nativeKillPolicyMayStopCommands(options) {
  return arrayOption(options.killOthersOn ?? options.killOthers).length > 0;
}

function applyKillOthers(args, options) {
  const conditions = arrayOption(options.killOthersOn ?? options.killOthers);
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

function attachStreams(child, options) {
  const outputStream = options.outputStream;
  if (!outputStream) {
    return () => Promise.resolve();
  }
  let pendingWrites = 0;
  let outputError;
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
  const write = (chunk) => {
    pendingWrites += 1;
    try {
      outputStream.write(chunk, (error) => {
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
  };
  child.stdout?.on("data", write);
  child.stderr?.on("data", write);
  return () => {
    if (pendingWrites === 0) {
      return outputError ? Promise.reject(outputError) : Promise.resolve();
    }
    return new Promise((resolve, reject) => {
      waiters.push({ resolve, reject });
    });
  };
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
  const output = options.outputStream ? "pipe" : "inherit";
  return ["pipe", output, output];
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
