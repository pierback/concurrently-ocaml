/// <reference types="node" />

import { Readable, Writable } from "node:stream";

export type CommandIdentifier = string | number;
export type ProcessCloseCondition = "success" | "failure";

export interface ConcurrentlyCommandInputObject {
  command: string;
  name?: string;
  prefixColor?: string;
  cwd?: string;
  env?: Record<string, unknown>;
  ipc?: number;
  raw?: boolean;
}

export type ConcurrentlyCommandInput = string | ConcurrentlyCommandInputObject;

export interface ConcurrentlyOptions {
  cwd?: string;
  hide?: CommandIdentifier | CommandIdentifier[];
  prefix?: string;
  prefixColors?: string | readonly string[];
  prefixLength?: number;
  padPrefix?: boolean;
  raw?: boolean;
  timestampFormat?: string;
  defaultInputTarget?: CommandIdentifier;
  inputStream?: Readable;
  outputStream?: Writable;
  errorStream?: Writable;
  handleInput?: boolean;
  restartDelay?: number | "exponential";
  restartTries?: number;
  killOthers?: ProcessCloseCondition | ProcessCloseCondition[];
  killOthersOn?: ProcessCloseCondition | ProcessCloseCondition[];
  killSignal?: string;
  killTimeout?: number;
  timings?: boolean;
  group?: boolean;
  teardown?: readonly string[];
  additionalArguments?: string[];
}

export interface CloseEvent {
  command: {
    command: string;
    name: string;
    index: number;
    prefixColor?: string;
  };
  index: number;
  killed: boolean;
  exitCode: string | number;
  timings: {
    startDate: Date;
    endDate: Date;
    durationSeconds: number;
  };
}

export interface TimerEvent {
  startDate: Date;
  endDate?: Date;
}

export interface Subscription {
  unsubscribe(): void;
}

export interface CommandObservable<T> {
  subscribe(listener: (event: T) => void): Subscription;
  on(event: string, listener: (event: T) => void): Subscription;
  once(event: string, listener: (event: T) => void): Subscription;
  addListener(event: string, listener: (event: T) => void): Subscription;
}

export interface UnsupportedCommandObservable {
  on(...args: unknown[]): never;
  once(...args: unknown[]): never;
  addListener(...args: unknown[]): never;
  subscribe(...args: unknown[]): never;
}

export interface Command {
  index: number;
  name: string;
  command: string;
  prefixColor?: string;
  env: Record<string, unknown>;
  cwd?: string;
  ipc?: number;
  close: CommandObservable<CloseEvent>;
  error: UnsupportedCommandObservable;
  stdout: CommandObservable<Buffer>;
  stderr: CommandObservable<Buffer>;
  timer: CommandObservable<TimerEvent>;
  stateChange: CommandObservable<"started" | "errored" | "exited">;
  killed: boolean;
  exited: boolean;
  state: "stopped" | "started" | "errored" | "exited";
  process?: unknown;
  pid?: number;
  stdin?: Writable;
  kill(code?: string): never;
}

export interface ConcurrentlyResult {
  result: Promise<CloseEvent[]>;
  commands: Command[];
}

export declare function concurrently(
  commands: ConcurrentlyCommandInput[],
  options?: Partial<ConcurrentlyOptions>
): ConcurrentlyResult;

export declare function createConcurrently(
  defaultOptions?: Partial<ConcurrentlyOptions>
): typeof concurrently;
export default concurrently;
