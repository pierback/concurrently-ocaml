"use strict";

const {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { commandInfo } = require("./command");
const {
  commandCwd,
  invocationCwd,
  normalizeEnv,
} = require("./execution-context");
const {
  attachNativeOutput,
  capturesOutput,
  stdioFor,
} = require("./output-destination");
const { forceColorEnabled } = require("./output-rendering");
const {
  arrayOption,
  hiddenCommands,
  killOthersConditions,
  nativeKillPolicyMayStopCommands,
} = require("./run-policy");
const {
  apiShellArguments,
  apiShellKind,
  apiShellOptions,
  resolveApiShell,
} = require("./shell-command");
const { nativeRunSucceeded } = require("./run-result");
const { runNative } = require("./native");

function runNativeBackend(commands, options) {
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

  const customKill = options.kill;
  const nativeKillPolicy = nativeKillPolicyMayStopCommands(options);
  commands.forEach((command, position) => {
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
  if (commands.length === 1) {
    commands[0].stdin = child.stdin;
  }

  const startPoll = setInterval(
    () => markStartedCommands(commands, eventDir, startedAt),
    20
  );
  startPoll.unref?.();
  const waitForOutput = attachNativeOutput(child, options);
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
      markStartedCommands(commands, eventDir, startedAt);
      const events = readCommandEvents({
        commands: commands,
        endedAt,
        eventDir,
        runExitCode: exitCode,
        runKilled: Boolean(signal),
        runKillSignal: options.killSignal ?? "SIGTERM",
        startedAt,
        missingEventIsKilled: invocation.missingEventIsKilled,
      });
      const nativeOutcome = readNativeOutcome(invocation.resultPath);
      waitForOutput().then(
        () => {
          cleanupEventDir();
          if (
            nativeRunSucceeded(exitCode, events, {
              killOthersOn: killOthersConditions(options),
              nativeOutcome,
              successCondition: options.successCondition,
            })
          ) {
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

  return result;
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

function nativeInvocation(commands, options, eventDir) {
  const args = [];
  const env = { ...process.env };
  const cwd = invocationCwd(options);
  const shell = resolveApiShell(options);
  const rawValues = commandRawValues(commands, options);
  const inheritedCommandEnv = {};
  const resultPath = join(eventDir, "run-result");

  args.push("--api-ignore-env-options");
  pushOption(args, "--api-result-file", resultPath);
  if (commands.length === 0) args.push("--api-empty-expansion");
  pushOption(args, "--max-processes", options.maxProcesses);
  pushOption(args, "--success", nativeSuccessCondition(commands, options.successCondition));
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
    (capturesOutput(options) && !forceColorEnabled(env))
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
        shouldDetachWrappedCommand(options),
        nativeKillPolicyMayStopCommands(options),
        shell
      )
    )
  );
  return {
    args,
    cwd,
    env,
    killPaths: commands.map((command) => killPath(eventDir, command.index)),
    missingEventIsKilled: nativeKillPolicyMayStopCommands(options),
    resultPath,
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
  detachWrappedCommand,
  nativeKillPolicy,
  shell
) {
  const eventFile = Buffer.from(path).toString("base64");
  const startFile = Buffer.from(startPath).toString("base64");
  const killFile = Buffer.from(killPath).toString("base64");
  const commandEnvFile = Buffer.from(commandEnvPath).toString("base64");
  const commandCwd =
    cwd === undefined ? undefined : Buffer.from(cwd).toString("base64");
  const shellPath = Buffer.from(shell).toString("base64");
  const shellKind = apiShellKind(shell);
  const encodedShellArguments = apiShellArguments(shellKind, command).map(
    (argument) => Buffer.from(argument).toString("base64")
  );
  const shellOptions = Buffer.from(
    JSON.stringify(apiShellOptions(shellKind))
  ).toString("base64");
  const childStdin = forwardStdin ? "inherit" : "ignore";
  const source = [
    "const cp=require('node:child_process')",
    "const fs=require('node:fs')",
    "const signalNumbers=require('node:os').constants.signals",
    `const file=Buffer.from('${eventFile}','base64').toString()`,
    `const startFile=Buffer.from('${startFile}','base64').toString()`,
    `const killFile=Buffer.from('${killFile}','base64').toString()`,
    `const commandEnvFile=Buffer.from('${commandEnvFile}','base64').toString()`,
    `const shellPath=Buffer.from('${shellPath}','base64').toString()`,
    commandCwd === undefined
      ? "const cwd=undefined"
      : `const cwd=Buffer.from('${commandCwd}','base64').toString()`,
    "const commandEnv=JSON.parse(fs.readFileSync(commandEnvFile,'utf8'))",
    `const childStdin='${childStdin}'`,
    "const startMs=Date.now()",
    "let child",
    "let exiting=false",
    "let receivedSignal=null",
    "let wrote=false",
    "const write=event=>{if(!wrote){wrote=true;fs.writeFileSync(file,JSON.stringify({...event,startMs,endMs:Date.now()}))}}",
    "const exitCode=signal=>128+(typeof signal==='number'?signal:(signalNumbers[signal]||1))",
    "const descendantPids=pid=>{if(process.platform==='win32'||!pid)return[];try{const ps=cp.spawnSync('ps',['-A','-o','pid=','-o','ppid='],{encoding:'utf8',timeout:200,maxBuffer:1024*1024});const rows=String(ps.stdout||'').trim().split(/\\n+/);const children=new Map();for(const row of rows){const parts=row.trim().split(/\\s+/);if(parts.length<2)continue;const childPid=Number(parts[0]);const parentPid=Number(parts[1]);if(!Number.isInteger(childPid)||!Number.isInteger(parentPid))continue;const childList=children.get(parentPid)||[];childList.push(childPid);children.set(parentPid,childList)}const result=[];const stack=[pid];while(stack.length>0){const parent=stack.pop();for(const childPid of children.get(parent)||[]){result.push(childPid);stack.push(childPid)}}return result}catch(_){return[]}}",
    "const killDescendants=(pid,signal)=>{for(const target of descendantPids(pid).reverse()){try{process.kill(target,signal)}catch(_){}}}",
    "const forward=signal=>{if(!child)return;const pid=child.pid;const killGroup=()=>{if(process.platform!=='win32'&&pid){try{process.kill(-pid,signal);return true}catch(_){}}return false};const killChild=()=>{try{child.kill(signal)}catch(_){}};const attempt=()=>{if(!killGroup())killDescendants(pid,signal);killChild()};attempt();for(const delay of [25,100,250])setTimeout(attempt,delay).unref()}",
    "const onSignal=signal=>{receivedSignal=receivedSignal||signal;write({code:null,signal:receivedSignal});forward(signal);if(!exiting){exiting=true;setTimeout(()=>{forward('SIGKILL');process.exit(exitCode(receivedSignal))},5000).unref()}}",
    "const pollKill=()=>{try{if(fs.existsSync(killFile)){const signal=JSON.parse(fs.readFileSync(killFile,'utf8'));fs.rmSync(killFile,{force:true});onSignal(signal)}}catch(_){}}",
    "for(const signal of ['SIGHUP','SIGINT','SIGTERM','SIGQUIT','SIGUSR1','SIGUSR2','SIGBREAK']){if(signalNumbers[signal]){try{process.on(signal,()=>onSignal(signal))}catch(_){}}}",
    `const detachWrappedCommand=${detachWrappedCommand ? "true" : "false"}`,
    `const shellArgs=${JSON.stringify(encodedShellArguments)}.map(argument=>Buffer.from(argument,'base64').toString())`,
    `const shellOptions=JSON.parse(Buffer.from('${shellOptions}','base64').toString())`,
    "const spawnOptions={detached:detachWrappedCommand,stdio:[childStdin,'inherit','inherit'],env:{...process.env,...commandEnv}}",
    "Object.assign(spawnOptions,shellOptions)",
    "if(cwd!==undefined)spawnOptions.cwd=cwd",
    "child=cp.spawn(shellPath,shellArgs,spawnOptions)",
    "fs.writeFileSync(startFile,JSON.stringify({startMs,pid:child.pid}))",
    "const killInterval=setInterval(pollKill,20);killInterval.unref()",
    "child.on('error',error=>{write({code:1,signal:null,error:error.message});process.exit(1)})",
    `const nativeKillPolicy=${nativeKillPolicy ? "true" : "false"}`,
    "const finishChildExit=(code,signal)=>{const effectiveSignal=receivedSignal||signal;if(effectiveSignal){write({code:null,signal:effectiveSignal});process.exit(exitCode(effectiveSignal))}else{write({code,signal:null});process.exit(code??1)}}",
    "child.on('exit',(code,signal)=>{if(nativeKillPolicy&&!signal&&receivedSignal===null){setTimeout(()=>finishChildExit(code,signal),25)}else{finishChildExit(code,signal)}})",
  ].join(";");
  const runner = process.platform === "win32" ? "call " : "exec ";
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

function readNativeOutcome(path) {
  try {
    const outcome = readFileSync(path, "utf8").trim();
    return ["failure", "interrupted", "success"].includes(outcome)
      ? outcome
      : undefined;
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
  if (commands.some((command) => command.name === selector)) {
    return successCondition;
  }
  const selectedIndex = Number(selector);
  const nativePositions = commands.flatMap((command, position) =>
    command.index === selectedIndex ? [String(position)] : []
  );
  if (nativePositions.length !== 1) {
    return `${prefix}${commands.length}`;
  }
  return `${prefix}${nativePositions[0]}`;
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

function shouldDetachWrappedCommand(options) {
  return (
    process.platform !== "win32" &&
    !nativeKillPolicyMayStopCommands(options)
  );
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
    : "reset";
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
    args.push("--api-kill-others-on-success");
  } else if (wantsFailure) {
    args.push("--kill-others-on-fail");
  }
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
    child.stdin?.end?.();
    if (options.pauseInputStreamOnFinish !== false && typeof inputStream.pause === "function") {
      inputStream.pause();
    }
  };
}

function pushOption(args, name, value) {
  if (value !== undefined) {
    args.push(`${name}=${String(value)}`);
  }
}

function commandNameSeparator(names) {
  let separator = "\x1f";
  while (names.some((name) => name.includes(separator))) {
    separator += "\x1f";
  }
  return separator;
}

module.exports = { eventWrapperCommand, runNativeBackend };
