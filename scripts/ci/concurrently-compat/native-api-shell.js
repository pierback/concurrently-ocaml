const {
  chmodSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} = require("node:fs");
const { tmpdir } = require("node:os");
const { resolve } = require("node:path");
const { spawn } = require("node:child_process");
const {
  createDiscardSink,
  restoreEnvironmentValue,
} = require("./native-api-support");

const npmScriptShellEnv = "npm_config_script_shell";
const nativeApiMissingShell =
  process.platform === "win32"
    ? "Z:\\concurrently-shell-missing.exe"
    : "/definitely/missing-concurrently-shell";

async function runNativeApiShell({
  assertEqual,
  commands,
  nativeApiExplicitShell,
}) {
  const { shellQuote } = commands;

  await runNativeApiShellOptionSmoke();

  async function runNativeApiShellOptionSmoke() {
    const api = require(resolve("index.js"));
    const sink = createDiscardSink();
    const shellFailure = await api.concurrently(["echo shell-option-check"], {
      outputStream: sink,
      raw: true,
      shell: nativeApiMissingShell,
    }).result.then(
      () => "resolved",
      (error) => error
    );
    if (shellFailure === "resolved") {
      throw new Error("native JS API shell option unexpectedly succeeded");
    }
    if (!Array.isArray(shellFailure) || shellFailure.length === 0) {
      throw new Error(
        `native JS API shell option returned non-close-event rejection: ${shellFailure}`
      );
    }
    if (shellFailure[0].exitCode === 0 || shellFailure[0].exitCode === "0") {
      throw new Error(
        `native JS API shell option reported success with missing shell: ${JSON.stringify(shellFailure)}`
      );
    }

    if (process.platform !== "win32") {
      const shellRoot = mkdtempSync(resolve(tmpdir(), "concurrently-ml-shell-"));
      try {
        const shellLog = resolve(shellRoot, "shell.log");
        const shellPath = resolve(shellRoot, "shell");
        const cmdLog = resolve(shellRoot, "cmd.log");
        const cmdPath = resolve(shellRoot, "cmd.exe");
        const powershellLog = resolve(shellRoot, "powershell.log");
        const powershellPath = resolve(shellRoot, "pwsh");
        const readShellInvocations = () =>
          readFileSync(shellLog, "utf8")
            .trim()
            .split(/\r?\n/)
            .filter((line) => line !== "");
        const readCmdInvocations = () =>
          readFileSync(cmdLog, "utf8")
            .trim()
            .split(/\r?\n/)
            .filter((line) => line !== "");
        const readPowershellInvocations = () =>
          readFileSync(powershellLog, "utf8")
            .trim()
            .split(/\r?\n/)
            .filter((line) => line !== "");
        writeFileSync(
          shellPath,
          `#!/bin/sh\nprintf '%s\\n' "$2" >> ${shellQuote(shellLog)}\nexec /bin/sh "$@"\n`
        );
        writeFileSync(
          powershellPath,
          [
            "#!/bin/sh",
            `printf '%s\\n' "$@" >> ${shellQuote(powershellLog)}`,
            `if [ "$1" = "-NoProfile" ] && [ "$2" = "-Command" ]; then exec /bin/sh -c "$3"; fi`,
            "exit 64",
            "",
          ].join("\n")
        );
        writeFileSync(
          cmdPath,
          [
            "#!/bin/sh",
            `printf '%s\\n' "$@" >> ${shellQuote(cmdLog)}`,
            "command=$4",
            "command=${command#\\\"}",
            "command=${command%\\\"}",
            `if [ "$1" = "/d" ] && [ "$2" = "/s" ] && [ "$3" = "/c" ]; then exec /bin/sh -c "$command"; fi`,
            "exit 64",
            "",
          ].join("\n")
        );
        chmodSync(shellPath, 0o755);
        chmodSync(cmdPath, 0o755);
        chmodSync(powershellPath, 0o755);
        await api.concurrently(["echo shell-native-check"], {
          outputStream: sink,
          raw: true,
          shell: shellPath,
        }).result;
        const shellInvocations = readShellInvocations();
        assertEqual(
          shellInvocations.length,
          1,
          "native JS API shell option should not launch wrapper through custom shell"
        );
        assertEqual(
          shellInvocations[0],
          "echo shell-native-check",
          "native JS API shell option custom shell command"
        );

        await api.concurrently(["echo shell-cmd-native"], {
          outputStream: sink,
          raw: true,
          shell: cmdPath,
        }).result;
        const cmdNativeInvocations = readCmdInvocations();
        assertEqual(
          JSON.stringify(cmdNativeInvocations),
          JSON.stringify(["/d", "/s", "/c", `"echo shell-cmd-native"`]),
          "native JS API cmd shell option arguments"
        );

        await api.concurrently(["echo shell-powershell-native"], {
          outputStream: sink,
          raw: true,
          shell: powershellPath,
        }).result;
        const powershellNativeInvocations = readPowershellInvocations();
        assertEqual(
          JSON.stringify(powershellNativeInvocations),
          JSON.stringify(["-NoProfile", "-Command", "echo shell-powershell-native"]),
          "native JS API powershell shell option arguments"
        );

        writeFileSync(powershellLog, "");
        await api.concurrently(["echo shell-powershell-main"], {
          outputStream: sink,
          raw: true,
          shell: powershellPath,
          teardown: ["echo shell-powershell-cleanup"],
        }).result;
        const powershellTeardownInvocations = readPowershellInvocations();
        assertEqual(
          JSON.stringify(powershellTeardownInvocations),
          JSON.stringify([
            "-NoProfile",
            "-Command",
            "echo shell-powershell-main",
            "-NoProfile",
            "-Command",
            "echo shell-powershell-cleanup",
          ]),
          "native JS API powershell shell option teardown arguments"
        );

        writeFileSync(cmdLog, "");
        await api.concurrently(["echo shell-cmd-main"], {
          outputStream: sink,
          raw: true,
          shell: cmdPath,
          teardown: ["echo shell-cmd-cleanup"],
        }).result;
        const cmdTeardownInvocations = readCmdInvocations();
        assertEqual(
          JSON.stringify(cmdTeardownInvocations),
          JSON.stringify([
            "/d",
            "/s",
            "/c",
            `"echo shell-cmd-main"`,
            "/d",
            "/s",
            "/c",
            `"echo shell-cmd-cleanup"`,
          ]),
          "native JS API cmd shell option teardown arguments"
        );

        writeFileSync(shellLog, "");
        await api.concurrently(["echo shell-teardown-main"], {
          outputStream: sink,
          raw: true,
          shell: shellPath,
          teardown: ["echo shell-teardown-cleanup"],
        }).result;
        const shellTeardownInvocations = readShellInvocations();
        assertEqual(
          JSON.stringify(shellTeardownInvocations),
          JSON.stringify(["echo shell-teardown-main", "echo shell-teardown-cleanup"]),
          "native JS API shell option custom shell teardown commands"
        );

        const previousScriptShell = process.env[npmScriptShellEnv];
        process.env[npmScriptShellEnv] = shellPath;
        try {
          writeFileSync(shellLog, "");
          await api.concurrently(["echo shell-env-teardown-main"], {
            outputStream: sink,
            raw: true,
            teardown: ["echo shell-env-teardown-cleanup"],
          }).result;
          const shellEnvTeardownInvocations = readShellInvocations();
          assertEqual(
            JSON.stringify(shellEnvTeardownInvocations),
            JSON.stringify([
              "echo shell-env-teardown-main",
              "echo shell-env-teardown-cleanup",
            ]),
            "native JS API npm_config_script_shell teardown commands"
          );
        } finally {
          restoreEnvironmentValue(npmScriptShellEnv, previousScriptShell);
        }

        process.env[npmScriptShellEnv] = shellPath;
        try {
          writeFileSync(shellLog, "");
          const run = api.concurrently(
            ["node -e \"setTimeout(()=>process.exit(0),100)\""],
            {
              outputStream: sink,
              raw: true,
              teardown: ["echo shell-env-snapshot-cleanup"],
            }
          );
          process.env[npmScriptShellEnv] = nativeApiMissingShell;
          await run.result;
          const shellEnvSnapshotInvocations = readShellInvocations();
          assertEqual(
            JSON.stringify(shellEnvSnapshotInvocations),
            JSON.stringify([
              "node -e \"setTimeout(()=>process.exit(0),100)\"",
              "echo shell-env-snapshot-cleanup",
            ]),
            "native JS API npm_config_script_shell snapshot commands"
          );
        } finally {
          restoreEnvironmentValue(npmScriptShellEnv, previousScriptShell);
        }
      } finally {
        rmSync(shellRoot, { recursive: true, force: true });
      }
    }

    const previousScriptShell = process.env[npmScriptShellEnv];
    process.env[npmScriptShellEnv] = nativeApiExplicitShell;
    try {
      let observedShell;
      await api.concurrently(["echo shell-env-check"], {
        outputStream: sink,
        raw: true,
        spawn(command, options) {
          observedShell = options.shell;
          return spawn(command, [], options);
        },
      }).result;
      assertEqual(
        observedShell,
        nativeApiExplicitShell,
        "native JS API npm_config_script_shell forwarding"
      );
    } finally {
      restoreEnvironmentValue(npmScriptShellEnv, previousScriptShell);
    }

    console.log("compat ok: native JS API shell option");
  }
}

module.exports = { runNativeApiShell };
