"use strict";

const { spawn } = require("node:child_process");
const { dirname, join } = require("node:path");

const resolveUpstreamCliPath = () => {
  const packageJsonPath = require.resolve("concurrently-js/package.json");
  return join(dirname(packageJsonPath), "dist", "bin", "concurrently.js");
};

const runUpstreamCli = (args, options = {}) =>
  spawn(process.execPath, [resolveUpstreamCliPath(), ...args], {
    cwd: options.cwd ?? process.cwd(),
    env: options.env ?? process.env,
    stdio: options.stdio ?? "inherit",
  });

module.exports = {
  resolveUpstreamCliPath,
  runUpstreamCli,
};
