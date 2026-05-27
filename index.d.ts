import {
  ChildProcess as BaseChildProcess,
  MessageOptions,
  SendHandle,
  SpawnOptions,
} from "node:child_process";
import { EventEmitter } from "node:events";
import { Readable, Writable } from "node:stream";

export type CommandIdentifier = string | number;
export type ProcessCloseCondition = "failure" | "success";
export type RestartDelay = number | "exponential";
export type SuccessCondition =
  | "all"
  | "first"
  | "last"
  | `command-${string | number}`
  | `!command-${string | number}`;
export type KillProcess = (pid: number, signal?: string) => void;

export interface CommandInfo {
  name: string;
  command: string;
  env?: Record<string, unknown>;
  cwd?: string;
  prefixColor?: string;
  ipc?: number;
  raw?: boolean;
  hidden?: boolean;
}

export type ConcurrentlyCommandInput =
  | string
  | ({ command: string } & Partial<CommandInfo>);

export interface TimerEvent {
  startDate: Date;
  endDate?: Date;
}

export interface MessageEvent {
  message: object;
  handle?: SendHandle;
}

export interface OutgoingMessageEvent extends MessageEvent {
  options?: MessageOptions;
  onSent(error?: unknown): void;
}

export type ChildProcess = EventEmitter &
  Pick<BaseChildProcess, "pid" | "stdin" | "stdout" | "stderr" | "send">;
export type SpawnCommand = (
  command: string,
  options: SpawnOptions
) => ChildProcess;

export interface SubjectLike<T> {
  subscribe(observer: ((value: T) => void) | { next(value: T): void }): {
    unsubscribe(): void;
  };
}

export interface CloseEvent {
  command: CommandInfo;
  index: number;
  killed: boolean;
  exitCode: string | number;
  timings: {
    startDate: Date;
    endDate: Date;
    durationSeconds: number;
  };
}

export interface ConcurrentlyResult {
  commands: Command[];
  result: Promise<CloseEvent[]>;
}

export interface FlowController {
  handle(commands: Command[]): {
    commands: Command[];
    onFinish?: () => void | Promise<void>;
  };
}

export type LoggerSink =
  | {
      logCommandText(text: string): void;
      log?(prefix: string, text: string): void;
    }
  | {
      log(prefix: string, text: string): void;
      logCommandText?(text: string): void;
    };

export interface ConcurrentlyOptions {
  logger?: Logger | LoggerSink;
  outputStream?: Writable;
  group?: boolean;
  prefixColors?: string | string[] | false;
  maxProcesses?: number | string;
  raw?: boolean;
  hide?: CommandIdentifier | CommandIdentifier[];
  cwd?: string;
  env?: Record<string, unknown>;
  additionalArguments?: string[];
  controllers?: FlowController[];
  successCondition?: SuccessCondition;
  prefix?: string;
  prefixLength?: number;
  padPrefix?: boolean;
  timestampFormat?: string;
  defaultInputTarget?: CommandIdentifier;
  inputStream?: Readable;
  handleInput?: boolean;
  pauseInputStreamOnFinish?: boolean;
  restartDelay?: RestartDelay;
  restartTries?: number;
  killOthers?: ProcessCloseCondition | ProcessCloseCondition[];
  killOthersOn?: ProcessCloseCondition | ProcessCloseCondition[];
  spawn?: SpawnCommand;
  killSignal?: string;
  killTimeout?: number;
  kill?: KillProcess;
  timings?: boolean;
  teardown?: readonly string[];
}

export declare class Command implements CommandInfo {
  readonly index: number;
  readonly name: string;
  readonly command: string;
  readonly prefixColor?: string;
  readonly env: Record<string, unknown>;
  readonly cwd?: string;
  readonly ipc?: number;
  readonly raw?: boolean;
  readonly hidden?: boolean;
  pid?: number;
  killed: boolean;
  exited: boolean;
  state: "stopped" | "started" | "errored" | "exited";
  readonly close: SubjectLike<CloseEvent>;
  readonly error: SubjectLike<unknown>;
  readonly stdout: SubjectLike<Buffer>;
  readonly stderr: SubjectLike<Buffer>;
  readonly timer: SubjectLike<TimerEvent>;
  readonly stateChange: SubjectLike<"started" | "errored" | "exited">;
  readonly messages: {
    incoming: SubjectLike<MessageEvent>;
    outgoing: SubjectLike<OutgoingMessageEvent>;
  };
  process?: ChildProcess;
  stdin?: Writable;
  constructor(info: CommandInfo & { index: number });
  constructor(
    info: CommandInfo & { index: number },
    spawnOpts: SpawnOptions,
    spawn: SpawnCommand,
    killProcess: KillProcess
  );
  start(): void;
  send(
    message: object,
    handle?: SendHandle,
    options?: MessageOptions
  ): Promise<void>;
  kill(code?: string): void;
  static canKill(command: Command): command is Command & {
    pid: number;
    process: ChildProcess;
  };
}

export declare class Logger {
  constructor(options?: {
    hide?: CommandIdentifier[];
    raw?: boolean;
    prefixFormat?: string;
    commandLength?: number;
    timestampFormat?: string;
    outputStream?: Writable;
  });
  toggleColors(on: boolean): void;
  setPrefixLength(length: number): void;
  getPrefixContent(command: Command): { type: "default" | "template"; value: string } | undefined;
  getPrefix(command: Command): string;
  colorText(command: Command, text: string): string;
  logCommandEvent(text: string, command: Command): void;
  logCommandText(text: string, command: Command): void;
  logGlobalEvent(text: string): void;
  logTable(tableContents: Record<string, unknown>[]): void;
  log(prefix: string, text: string, command?: Command): void;
  emit(command: Command | undefined, text: string): void;
}

export declare class InputHandler implements FlowController {
  constructor(options: unknown);
  handle(commands: Command[]): { commands: Command[] };
}
export declare class KillOnSignal implements FlowController {
  constructor(options: unknown);
  handle(commands: Command[]): { commands: Command[] };
}
export declare class KillOthers implements FlowController {
  constructor(options: unknown);
  handle(commands: Command[]): { commands: Command[] };
}
export declare class LogError implements FlowController {
  constructor(options: unknown);
  handle(commands: Command[]): { commands: Command[] };
}
export declare class LogExit implements FlowController {
  constructor(options: unknown);
  handle(commands: Command[]): { commands: Command[] };
}
export declare class LogOutput implements FlowController {
  constructor(options: unknown);
  handle(commands: Command[]): { commands: Command[] };
}
export declare class LogTimings implements FlowController {
  constructor(options: unknown);
  handle(commands: Command[]): { commands: Command[] };
  static mapCloseEventToTimingInfo(event: CloseEvent): {
    name: string;
    duration: string;
    "exit code": string | number;
    killed: boolean;
    command: string;
  };
}
export declare class RestartProcess implements FlowController {
  readonly tries: number;
  constructor(options: unknown);
  handle(commands: Command[]): { commands: Command[] };
}

export declare function concurrently(
  commands: ConcurrentlyCommandInput[],
  options?: Partial<ConcurrentlyOptions>
): ConcurrentlyResult;

export declare function createConcurrently(
  commands: ConcurrentlyCommandInput[],
  options?: Partial<ConcurrentlyOptions>
): ConcurrentlyResult;

// @ts-expect-error keep upstream concurrently's CommonJS + default export shape.
export = concurrently;
export default concurrently;
