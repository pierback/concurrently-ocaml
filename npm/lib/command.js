"use strict";

const { spawnSync } = require("node:child_process");
const { ReplaySubject, Subject } = require("rxjs");
const { normalizeEnv } = require("./execution-context");

class Command {
  constructor(info, spawnOpts, spawn, killProcess) {
    info = info ?? {};
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
    this.processGroupId = undefined;
    this.stdin = undefined;
    this.killSignal = undefined;
    this.killExitSignal = undefined;
    this.killTreePids = [];
    this.killTreeProcessGroupIds = [];
    this.killProcess = undefined;
    this.killBeforePid = false;
    this.startedAt = undefined;
    this.close = new Subject();
    this.error = new Subject();
    this.stdout = new Subject();
    this.stderr = new Subject();
    this.timer = new Subject();
    this.stateChange = new Subject();
    this.messages = {
      incoming: new Subject(),
      outgoing: new ReplaySubject(),
    };
    this.process = undefined;
    this.spawn = spawn;
    this.spawnOpts = spawnOpts;
    this.runId = 0;
    this.spawnApiCompleted = false;
    this.killProcess =
      typeof killProcess === "function"
        ? (code) => killProcess(this.pid, code)
        : undefined;
    this.subscriptions = [];
  }

  start() {
    this.runId += 1;
    const runId = this.runId;
    this.spawnApiCompleted = false;
    let child;
    try {
      child = this.spawn(this.command, this.spawnOpts);
    } catch (error) {
      this.changeState("errored");
      throw error;
    }
    this.process = child;
    this.pid = child.pid;
    this.processGroupId = processGroupId(child.pid);
    this.changeState("started");
    const startDate = new Date();
    const highResStartTime = process.hrtime();
    this.timer.next({ startDate });
    this.subscriptions = this.maybeSetupIPC(child);
    child.on?.("error", (error) => {
      if (this.runId !== runId) {
        return;
      }
      this.cleanUp();
      const endDate = new Date();
      this.timer.next({ startDate, endDate });
      this.error.next(error);
      this.changeState("errored");
    });
    child.on?.("close", (exitCode, signal) => {
      if (this.runId !== runId) {
        return;
      }
      this.cleanUp();
      this.exited = true;
      if (this.state !== "errored") {
        this.changeState("exited");
      }
      const endDate = new Date();
      const [seconds, nanoseconds] = process.hrtime(highResStartTime);
      const closeEvent = {
        command: this,
        index: this.index,
        exitCode:
          process.platform === "win32" &&
          this.killed &&
          (this.killExitSignal || this.killSignal)
            ? this.killExitSignal || this.killSignal
            : exitCode ?? String(signal),
        killed: this.killed,
        timings: {
          startDate,
          endDate,
          durationSeconds: seconds + nanoseconds / 1e9,
        },
      };
      this.timer.next({ startDate, endDate });
      (this.spawnApiClose ?? this.close).next(closeEvent);
    });
    child.stdout?.on?.("data", (chunk) => this.stdout.next(chunk));
    child.stderr?.on?.("data", (chunk) => this.stderr.next(chunk));
    this.stdin = child.stdin || undefined;
    this.stdin?.on?.("error", () => {});
  }

  changeState(state) {
    this.state = state;
    this.stateChange.next(state);
  }

  maybeSetupIPC(child) {
    if (!this.ipc) {
      return [];
    }
    const onMessage = (message, handle) => {
      this.messages.incoming.next({ message, handle });
    };
    child.on?.("message", onMessage);
    const outgoing = this.messages.outgoing.subscribe((event) => {
      if (typeof child.send !== "function") {
        event.onSent(new Error("Command does not have an IPC channel"));
        return;
      }
      child.send(event.message, event.handle, event.options, (error) => {
        event.onSent(error);
      });
    });
    return [
      {
        unsubscribe() {
          child.off?.("message", onMessage);
        },
      },
      outgoing,
    ];
  }

  send(message, handle, options) {
    if (this.ipc == null) {
      throw new Error("Command IPC is disabled");
    }
    if (this.state !== "stopped" && this.process === undefined) {
      return Promise.reject(new Error("Command IPC channel is closed"));
    }
    return new Promise((resolve, reject) => {
      this.messages.outgoing.next({
        message,
        handle,
        options,
        onSent(error) {
          if (error) {
            reject(error);
          } else {
            resolve();
          }
        },
      });
    });
  }

  kill(code = "SIGTERM") {
    if (!canRequestKill(this)) {
      return;
    }
    const killed = this.killProcess(code);
    if (killed !== false) {
      this.killed = true;
      this.killSignal = code;
      this.killExitSignal = typeof killed === "string" ? killed : undefined;
    }
  }

  cleanUp() {
    const child = this.process;
    for (const subscription of this.subscriptions) {
      subscription.unsubscribe();
    }
    this.subscriptions = [];
    this.messages.outgoing = new ReplaySubject();
    if (this.killed) {
      destroyChildStreams(child);
    }
    this.process = undefined;
    this.stdin = undefined;
  }

  static canKill(command) {
    return Boolean(
      command &&
        !command.exited &&
        command.process &&
        typeof command.killProcess === "function" &&
        Number.isInteger(command.pid)
    );
  }
}

function canRequestKill(command) {
  return Boolean(
    command &&
      !command.exited &&
      command.process &&
      typeof command.killProcess === "function" &&
      (Number.isInteger(command.pid) || command.killBeforePid)
  );
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

function destroyChildStreams(child) {
  child?.stdin?.destroy?.();
  child?.stdout?.destroy?.();
  child?.stderr?.destroy?.();
}

function processGroupId(pid) {
  if (process.platform === "win32" || !Number.isInteger(pid)) {
    return undefined;
  }
  for (const command of ["/bin/ps", "/usr/bin/ps", "ps"]) {
    const result = spawnSync(command, ["-o", "pgid=", "-p", String(pid)], {
      encoding: "utf8",
    });
    if (!result.error && result.status === 0) {
      const pgid = Number(result.stdout.trim());
      return Number.isInteger(pgid) ? pgid : undefined;
    }
    if (result.error?.code !== "ENOENT") {
      return undefined;
    }
  }
  return undefined;
}

function stringOrDefault(value, fallback) {
  return typeof value === "string" ? value : fallback;
}

function numberOrDefault(value, fallback) {
  return Number.isFinite(value) ? value : fallback;
}

module.exports = {
  Command,
  canRequestKill,
  commandInfo,
};
