const { existsSync } = require("node:fs");
const { spawn, spawnSync } = require("node:child_process");
const { delimiter, dirname, resolve, sep } = require("node:path");

function createCliCommandRunner({ localBinary, npmConcurrentlyVersion }) {
  const npmConcurrentlyCommand = resolveNpmConcurrentlyCommand();

  function runLocal(testCase) {
    return runCommand(localBinary, testCase.args, {
      ...testCase,
      side: "local",
    });
  }

  function runUpstream(testCase) {
    return runCommand(npmConcurrentlyCommand, testCase.args, {
      ...testCase,
      side: "npm",
    });
  }

  function resolveNpmConcurrentlyCommand() {
    const local = resolveLocalPinnedConcurrentlyBinary();
    if (local) {
      return commandForConcurrentlyBinary(local);
    }

    const result = spawnFileSync(
      npmCommand(),
      [
        "exec",
        "--yes",
        "--package",
        `concurrently@${npmConcurrentlyVersion}`,
        "--",
        commandLocator(),
        "concurrently",
      ],
      {
        cwd: resolve("."),
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
      }
    );

    if (result.error) {
      throw result.error;
    }
    if (result.status !== 0) {
      throw new Error(
        `failed to resolve concurrently@${npmConcurrentlyVersion}\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`
      );
    }

    const binary = commandLocatorResult(result.stdout);
    if (!binary) {
      throw new Error(`${commandLocator()} concurrently returned no binary path`);
    }
    return commandForConcurrentlyBinary(binary);
  }

  function resolveLocalPinnedConcurrentlyBinary() {
    const configured = process.env.CONCURRENTLY_BIN;
    if (configured) {
      const configuredBinary = resolveVoltaShim(configured);
      assertPinnedConcurrentlyVersion(configuredBinary);
      return configuredBinary;
    }

    const which = spawnFileSync(commandLocator(), ["concurrently"], {
      cwd: resolve("."),
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    });
    const binary = resolveVoltaShim(commandLocatorResult(which.stdout));
    if (!binary) {
      return null;
    }

    return assertPinnedConcurrentlyVersion(binary) ? binary : null;
  }

  function npmCommand() {
    return process.platform === "win32" ? "npm.cmd" : "npm";
  }

  function commandLocator() {
    return process.platform === "win32" ? "where" : "which";
  }

  function commandLocatorResult(stdout) {
    const binaries = stdout.trim().split(/\r?\n/).filter(Boolean);
    if (process.platform !== "win32") {
      return binaries.pop() ?? "";
    }
    return (
      binaries.find((binary) => binary.toLowerCase().endsWith(".cmd")) ??
      binaries.pop() ??
      ""
    );
  }

  function spawnFileSync(command, args, options) {
    return spawnSync(command, args, {
      ...options,
      shell: windowsCommandScript(command),
    });
  }

  function spawnFile(command, args, options) {
    return spawn(command, args, {
      ...options,
      shell: windowsCommandScript(command),
    });
  }

  function windowsCommandScript(command) {
    return process.platform === "win32" && command.toLowerCase().endsWith(".cmd");
  }

  function resolveVoltaShim(binary) {
    if (!binary || !binary.includes(`${sep}.volta${sep}bin${sep}`)) {
      return binary;
    }

    const result = spawnFileSync("volta", ["which", "concurrently"], {
      cwd: resolve("."),
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    });
    if (result.status !== 0) {
      return binary;
    }

    return result.stdout.trim().split(/\r?\n/).pop() || binary;
  }

  function assertPinnedConcurrentlyVersion(binary) {
    const version = spawnFileSync(binary, ["--version"], {
      cwd: resolve("."),
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    });
    if (version.status !== 0) {
      return false;
    }

    const actual = version.stdout.trim();
    if (actual !== npmConcurrentlyVersion) {
      if (process.env.CONCURRENTLY_BIN) {
        throw new Error(
          `CONCURRENTLY_BIN must point to concurrently@${npmConcurrentlyVersion}, got ${actual}`
        );
      }
      return false;
    }
    return true;
  }

  function commandForConcurrentlyBinary(binary) {
    if (process.platform === "win32" && binary.toLowerCase().endsWith(".cmd")) {
      const packageRoot = resolve(dirname(binary), "..", "concurrently");
      const jsBinary = [
        resolve(packageRoot, "dist", "bin", "index.js"),
        resolve(packageRoot, "dist", "bin", "concurrently.js"),
      ].find((candidate) => existsSync(candidate));
      if (jsBinary) {
        return { command: process.execPath, args: [jsBinary] };
      }
    }

    return { command: binary, args: [] };
  }

  function runCommand(commandInput, args, testCase) {
    if (testCase.prepare) {
      testCase.prepare();
    }

    const commandSpec =
      typeof commandInput === "string"
        ? { command: commandInput, args: [] }
        : commandInput;
    const command = commandSpec.command;
    const commandArgs = [...commandSpec.args, ...args];

    if (
      testCase.inputDelayMs !== undefined ||
      testCase.inputWrites !== undefined ||
      testCase.parentSignal !== undefined
    ) {
      return runAsync(command, commandArgs, testCase);
    }

    const result = spawnFileSync(command, commandArgs, {
      cwd: testCase.cwd ?? resolve("."),
      encoding: "utf8",
      env: environmentFor(testCase),
      input: testCase.input ?? "",
      stdio: ["pipe", "pipe", "pipe"],
      timeout: testCase.timeoutMs ?? 60000,
    });

    if (result.error) {
      throw new Error(`${testCase.name} (${testCase.side}): ${result.error.message}`);
    }

    return {
      status: result.status,
      signal: result.signal,
      stdout: result.stdout,
      stderr: result.stderr,
    };
  }

  function runAsync(command, args, testCase) {
    return new Promise((resolvePromise, rejectPromise) => {
      const child = spawnFile(command, args, {
        cwd: testCase.cwd ?? resolve("."),
        env: environmentFor(testCase),
        stdio: ["pipe", "pipe", "pipe"],
      });
      let stdout = "";
      let stderr = "";
      let settled = false;
      const inputTimers = [];
      let signalTimer;
      const timeout = setTimeout(() => {
        if (settled) {
          return;
        }
        settled = true;
        if (signalTimer) {
          clearTimeout(signalTimer);
        }
        child.kill("SIGKILL");
        rejectPromise(new Error(`${testCase.name} (${testCase.side}): timed out`));
      }, testCase.timeoutMs ?? 60000);
      const clearSignalTimer = () => {
        if (signalTimer) {
          clearTimeout(signalTimer);
        }
      };
      const maybeSendParentSignal = () => {
        const parentSignal = testCase.parentSignal;
        if (!parentSignal || signalTimer) {
          return;
        }
        if (!stdout.includes(parentSignal.afterStdout)) {
          return;
        }
        signalTimer = setTimeout(() => {
          child.kill(parentSignal.signal);
        }, parentSignal.delayMs);
      };

      child.stdout.setEncoding("utf8");
      child.stderr.setEncoding("utf8");
      child.stdout.on("data", (chunk) => {
        stdout += chunk;
        maybeSendParentSignal();
      });
      child.stderr.on("data", (chunk) => {
        stderr += chunk;
      });
      child.stdin.on("error", (error) => {
        if (error.code === "EPIPE") {
          // Delayed test input can race with a child that already closed stdin.
          // The process close event still carries the behavior under comparison.
          return;
        }
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timeout);
        clearSignalTimer();
        inputTimers.forEach(clearTimeout);
        rejectPromise(new Error(`${testCase.name}: stdin ${error.message}`));
      });
      child.on("error", (error) => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timeout);
        clearSignalTimer();
        inputTimers.forEach(clearTimeout);
        rejectPromise(new Error(`${testCase.name}: ${error.message}`));
      });
      child.on("close", (status, signal) => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timeout);
        clearSignalTimer();
        inputTimers.forEach(clearTimeout);
        resolvePromise({ status, signal, stdout, stderr });
      });

      if (
        testCase.inputDelayMs !== undefined ||
        testCase.inputWrites !== undefined
      ) {
        const inputWrites =
          testCase.inputWrites ??
          [{ delayMs: testCase.inputDelayMs, input: testCase.input ?? "" }];
        inputWrites.forEach((write, index) => {
          const writeInput = () => {
            child.stdin.write(write.input);
            if (index === inputWrites.length - 1) {
              child.stdin.end();
            }
          };
          if (write.afterStdout !== undefined) {
            const stdoutContains = (text) =>
              stdout.includes(text) ||
              stdout.replace(/\r\n/g, "\n").includes(text);
            const poll = () => {
              if (stdoutContains(write.afterStdout)) {
                writeInput();
                return;
              }
              inputTimers.push(setTimeout(poll, 20));
            };
            poll();
          } else {
            inputTimers.push(setTimeout(writeInput, write.delayMs));
          }
        });
      } else {
        child.stdin.end();
      }
    });
  }

  function environmentFor(testCase) {
    const env = { ...process.env, NO_COLOR: "1" };
    if (testCase.env) {
      for (const [key, value] of Object.entries(testCase.env)) {
        if (value === null) {
          delete env[key];
        } else {
          env[key] = value;
        }
      }
    }
    if (testCase.bypassVoltaNodeShim) {
      // Volta parses package.json in cwd before Node starts; this fixture needs
      // upstream concurrently to observe the invalid manifest itself.
      env.PATH = `${dirname(process.execPath)}${delimiter}${env.PATH ?? ""}`;
    }
    return env;
  }

  return { runCommand, runLocal, runUpstream };
}

module.exports = { createCliCommandRunner };
