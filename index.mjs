import api from "./npm/lib/api.js";

export const Command = api.Command;
export const InputHandler = api.InputHandler;
export const KillOnSignal = api.KillOnSignal;
export const KillOthers = api.KillOthers;
export const LogError = api.LogError;
export const LogExit = api.LogExit;
export const LogOutput = api.LogOutput;
export const LogTimings = api.LogTimings;
export const Logger = api.Logger;
export const RestartProcess = api.RestartProcess;
export const __esModule = true;
export const concurrently = api.concurrently;
export const createConcurrently = api.createConcurrently;
const moduleExports = api.concurrently;
export { moduleExports as "module.exports" };
export default concurrently;
