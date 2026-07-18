"use strict";

const NPM_SCRIPT_SHELL_ENV = "npm_config_script_shell";

function arrayOption(value) {
  if (value === undefined || value === null || value === false) {
    return [];
  }
  return Array.isArray(value) ? value : [value];
}

function normalizeApiOptions(options) {
  const normalized = { ...options };
  if (!isNonEmptyString(normalized.shell)) {
    const npmScriptShell = process.env[NPM_SCRIPT_SHELL_ENV];
    normalized.shell = isNonEmptyString(npmScriptShell) ? npmScriptShell : null;
  }
  return normalized;
}

function isNonEmptyString(value) {
  return typeof value === "string" && value.length > 0;
}

function requiresSpawnBackend(commands, options) {
  return Boolean(
    options.spawn !== undefined ||
    commandsNeedSpawnApi(commands) ||
    loggerNeedsCommandContext(options.logger) ||
    teardownNeedsSpawnApiShell(options) ||
    (options.kill !== undefined && nativeKillPolicyMayStopCommands(options))
  );
}

function commandsNeedSpawnApi(commands) {
  return commands.some((command) => command.ipc != null);
}

function loggerNeedsCommandContext(logger) {
  return Boolean(
    logger &&
      ((typeof logger.logCommandText === "function" &&
        logger.logCommandText.length > 1) ||
        (typeof logger.log === "function" && logger.log.length > 2))
  );
}

function teardownNeedsSpawnApiShell(options) {
  return arrayOption(options.teardown).length > 0 && hasShellOverride(options);
}

function hasShellOverride(options) {
  return isNonEmptyString(options.shell);
}

function hiddenCommands(commands, options) {
  return [
    ...commands
      .flatMap((command, position) => command.hidden ? [String(position)] : []),
    ...arrayOption(options.hide).flatMap((identifier) =>
      hideIdentifiers(commands, identifier)
    ),
  ].map(String);
}

function hideIdentifiers(commands, identifier) {
  if (typeof identifier === "number") {
    const indexes = commands
      .flatMap((command, position) =>
        command.index === identifier ? [String(position)] : []
      );
    return indexes;
  }
  const value = String(identifier);
  const matchingIndexes = commands
    .flatMap((command, position) =>
      command.name === value || String(command.index) === value
        ? [String(position)]
        : []
    );
  return matchingIndexes;
}

function killOthersConditions(options) {
  return arrayOption(options.killOthersOn ?? options.killOthers);
}

function nativeKillPolicyMayStopCommands(options) {
  return killOthersConditions(options).length > 0;
}

module.exports = {
  arrayOption,
  hiddenCommands,
  killOthersConditions,
  nativeKillPolicyMayStopCommands,
  normalizeApiOptions,
  requiresSpawnBackend,
};
