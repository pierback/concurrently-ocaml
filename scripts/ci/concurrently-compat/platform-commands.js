const { mkdirSync, mkdtempSync, rmSync, writeFileSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { resolve } = require("node:path");

function createPlatformCommands() {
  const windowsCommandFixture = createWindowsCommandFixture();
  const inputEchoCommand =
    process.platform === "win32"
      ? windowsCommandFixture.stdinEchoCommand("")
      : "node -e \"process.stdin.once('data',d=>{process.stdout.write(d);process.exit(0)})\"";
  const firstInputEchoCommand =
    process.platform === "win32"
      ? windowsCommandFixture.stdinEchoCommand("first:")
      : "node -e \"process.stdin.once('data',d=>{process.stdout.write('first:'+d);process.exit(0)})\"";
  const secondInputEchoCommand =
    process.platform === "win32"
      ? windowsCommandFixture.stdinEchoCommand("second:")
      : "node -e \"process.stdin.once('data',d=>{process.stdout.write('second:'+d);process.exit(0)})\"";
  const firstChunkInputCommand =
    "node -e \"process.stdin.on('data',d=>process.stdout.write('first:'+d)); setTimeout(()=>process.exit(0),500)\"";
  const secondChunkInputCommand =
    "node -e \"process.stdin.on('data',d=>process.stdout.write('second:'+d)); setTimeout(()=>process.exit(0),500)\"";
  const signalReadyCommand =
    "node -e \"process.stdout.write('ready\\n'); setTimeout(()=>process.exit(0),5000)\"";
  const signalTrappedSuccessCommand =
    "node -e \"process.on('SIGTERM',()=>process.exit(0)); process.stdout.write('ready\\n'); setTimeout(()=>process.exit(99),5000)\"";
  const delayedOkCommand = "sh -c 'sleep 0.05; printf ok'";

  function nodePrintCommand(text) {
    if (process.platform === "win32") {
      return windowsCommandFixture.printCommand(text);
    }
    return nodeEvalCommand(`process.stdout.write('${jsSingleQuoted(text)}')`);
  }

  function nodeStderrCommand(text) {
    if (process.platform === "win32") {
      return windowsCommandFixture.stderrCommand(text);
    }
    return nodeEvalCommand(`process.stderr.write('${jsSingleQuoted(text)}')`);
  }

  function nodeDelayPrintCommand(text, delayMs) {
    if (process.platform === "win32") {
      return windowsCommandFixture.delayPrintCommand(text, delayMs);
    }
    return nodeEvalCommand(
      `setTimeout(function(){` +
        `process.stdout.write('${jsSingleQuoted(text)}')` +
        `},${delayMs})`
    );
  }

  function nodeExitCommand(exitCode) {
    if (process.platform === "win32") {
      return windowsCommandFixture.exitCommand(exitCode);
    }
    return nodeEvalCommand(`process.exit(${exitCode})`);
  }

  function nodeHangCommand() {
    if (process.platform === "win32") {
      return windowsCommandFixture.hangCommand();
    }
    return nodeEvalCommand("setInterval(function(){},1000)");
  }

  function nodeEvalCommand(source) {
    if (process.platform === "win32") {
      if (source === "process.stdout.write(process.argv.slice(1).join('|'))") {
        return windowsCommandFixture.argvPipeCommand();
      }
      if (
        source ===
        "process.stdout.write(process.cwd()+'\\n'+process.env.CONCURRENTLY_COMPAT_ENV)"
      ) {
        return windowsCommandFixture.cwdEnvCommand();
      }
    }
    return `${nodeExecutableCommand()} -e "${source.replaceAll('"', '\\"')}"`;
  }

  return {
    cleanup() {
      windowsCommandFixture.cleanup();
    },
    delayedOkCommand,
    firstChunkInputCommand,
    firstInputEchoCommand,
    inputEchoCommand,
    jsSingleQuoted,
    nodeDelayPrintCommand,
    nodeEvalCommand,
    nodeExitCommand,
    nodeHangCommand,
    nodePrintCommand,
    nodeStderrCommand,
    quotedWindowsScriptCommand: windowsCommandFixture.quotedScriptCommand,
    secondChunkInputCommand,
    secondInputEchoCommand,
    shellQuote,
    signalReadyCommand,
    signalTrappedSuccessCommand,
  };
}

function createWindowsCommandFixture() {
  const root = mkdtempSync(resolve(tmpdir(), "concurrently-ocaml-win-cmd-"));
  const scriptDir = resolve(root, "script dir");
  const script = resolve(scriptDir, "echo args.cmd");
  let nextScriptId = 0;
  mkdirSync(scriptDir, { recursive: true });
  writeFileSync(script, "@echo off\r\necho script:%~1:%~2\r\n");

  function command(name, body) {
    const file = resolve(root, `${nextScriptId++}-${name}.cmd`);
    writeFileSync(file, `@echo off\r\n${body}`);
    return `"${file}"`;
  }

  return {
    quotedScriptCommand: `"${script}" "alpha beta" plain`,
    printCommand(text) {
      return command("print", `<nul set /p "=${text}"\r\nexit /b 0\r\n`);
    },
    stderrCommand(text) {
      return command("stderr", `1>&2 <nul set /p "=${text}"\r\nexit /b 0\r\n`);
    },
    delayPrintCommand(text, delayMs) {
      return command(
        "delay-print",
        `powershell -NoProfile -Command "Start-Sleep -Milliseconds ${delayMs}" >nul\r\n<nul set /p "=${text}"\r\nexit /b 0\r\n`
      );
    },
    exitCommand(exitCode) {
      return command("exit", `exit /b ${exitCode}\r\n`);
    },
    hangCommand() {
      return command("hang", ":loop\r\nping -n 2 127.0.0.1 >nul\r\ngoto loop\r\n");
    },
    stdinEchoCommand(prefix) {
      return command("stdin-echo", `set /p line=\r\necho ${prefix}%line%\r\n`);
    },
    argvPipeCommand() {
      return command(
        "argv-pipe",
        "setlocal EnableDelayedExpansion\r\n" +
          'set "out="\r\n' +
          ":loop\r\n" +
          'if "%~1"=="" goto done\r\n' +
          'if defined out (set "out=!out!|%~1") else set "out=%~1"\r\n' +
          "shift\r\n" +
          "goto loop\r\n" +
          ":done\r\n" +
          '<nul set /p "=!out!"\r\n' +
          "exit /b 0\r\n"
      );
    },
    cwdEnvCommand() {
      return command(
        "cwd-env",
        'echo %CD%\r\n<nul set /p "=%CONCURRENTLY_COMPAT_ENV%"\r\nexit /b 0\r\n'
      );
    },
    cleanup() {
      rmSync(root, { force: true, recursive: true });
    },
  };
}

function nodeExecutableCommand() {
  if (process.platform === "win32") {
    return `"${process.execPath}"`;
  }
  return "node";
}

function shellQuote(value) {
  return `'${value.replaceAll("'", "'\\''")}'`;
}

function jsSingleQuoted(value) {
  return value.replaceAll("\\", "\\\\").replaceAll("'", "\\'");
}

module.exports = { createPlatformCommands };
