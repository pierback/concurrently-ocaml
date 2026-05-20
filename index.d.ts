import concurrently = require("concurrently-js");

export {
  CloseEvent,
  Command,
  CommandIdentifier,
  ConcurrentlyCommandInput,
  ConcurrentlyOptions,
  ConcurrentlyResult,
  FlowController,
  InputHandler,
  KillOnSignal,
  KillOthers,
  LogError,
  LogExit,
  LogOutput,
  LogTimings,
  Logger,
  RestartProcess,
  TimerEvent,
  concurrently,
  createConcurrently,
} from "concurrently-js";
// @ts-expect-error keep upstream concurrently's CommonJS + default export shape.
export = concurrently;
export default concurrently;
