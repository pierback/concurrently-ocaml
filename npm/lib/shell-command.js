"use strict";

function resolveApiShell(options) {
  if (isNonEmptyString(options.shell)) {
    return options.shell;
  }
  return defaultApiShell();
}

function defaultApiShell() {
  if (process.platform !== "win32") {
    return "/bin/sh";
  }
  const comspec = process.env.ComSpec;
  return isNonEmptyString(comspec) ? comspec : "cmd.exe";
}

function isNonEmptyString(value) {
  return typeof value === "string" && value.length > 0;
}

function apiShellInvocation(shellPath, command) {
  const kind = apiShellKind(shellPath);
  return {
    args: apiShellArguments(kind, command),
    file: shellPath,
    options: apiShellOptions(kind),
  };
}

function apiShellArguments(kind, command) {
  if (kind === "cmd") {
    return ["/d", "/s", "/c", `"${command}"`];
  }
  if (kind === "powershell") {
    return ["-NoProfile", "-Command", command];
  }
  return ["-c", command];
}

function apiShellOptions(kind) {
  return kind === "cmd" ? { windowsVerbatimArguments: true } : {};
}

function apiShellKind(shellPath) {
  const base = String(shellPath)
    .replace(/\\/g, "/")
    .split("/")
    .pop()
    .toLowerCase()
    .replace(/\.exe$/i, "");
  if (base === "cmd") {
    return "cmd";
  }
  if (base === "powershell" || base === "pwsh") {
    return "powershell";
  }
  return "posix";
}

function assertApiShellSupportsIpc(options, platform = process.platform) {
  if (
    platform === "win32" &&
    Array.isArray(options?.stdio) &&
    options.stdio.includes("ipc")
  ) {
    throw new Error(
      "[concurrently] command IPC on Windows requires options.spawn to launch the IPC-aware process directly"
    );
  }
}

module.exports = {
  apiShellArguments,
  apiShellInvocation,
  apiShellKind,
  apiShellOptions,
  assertApiShellSupportsIpc,
  resolveApiShell,
};
