"use strict";

const { resolve } = require("node:path");

function invocationCwd(options) {
  return normalizeCwd(options.cwd) ?? process.cwd();
}

function commandCwd(command) {
  return normalizeCwd(command.cwd);
}

function commandLookupCwd(command, options) {
  return commandCwd(command) ?? invocationCwd(options);
}

function normalizeCwd(cwd) {
  return typeof cwd === "string" && cwd.length > 0
    ? resolve(cwd)
    : undefined;
}

function normalizeEnv(env) {
  return Object.fromEntries(
    Object.entries(env ?? {})
      .filter(([_key, value]) => value !== undefined)
      .map(([key, value]) => [key, String(value)])
  );
}

module.exports = {
  commandCwd,
  commandLookupCwd,
  invocationCwd,
  normalizeEnv,
};
