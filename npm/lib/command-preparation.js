"use strict";

const assert = require("node:assert");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const { Command } = require("./command");
const { commandLookupCwd } = require("./execution-context");

const SHORTCUT_RUNNERS = new Set(["npm", "yarn", "pnpm", "bun", "node", "deno"]);

function prepareCommands(commandInputs, options) {
  const commands = expandShortcutCommands(normalizeCommands(commandInputs), options);
  expandAdditionalArguments(commands, options.additionalArguments);
  return commands;
}

function normalizeCommands(commandInputs) {
  return commandInputs.map((input, index) => {
    if (typeof input === "string") {
      assert.ok(input.length > 0, "[concurrently] command cannot be empty");
      return new Command({ index, name: "", command: input });
    }
    const command = input && typeof input === "object" ? input.command : undefined;
    assert.ok(
      typeof command === "string" && command.length > 0,
      "[concurrently] command cannot be empty"
    );
    return new Command({
      index,
      name: input.name ?? "",
      command,
      prefixColor: input.prefixColor,
      env: input.env,
      cwd: input.cwd,
      ipc: input.ipc,
      raw: input.raw,
      hidden: input.hidden,
    });
  });
}

function expandShortcutCommands(commands, options) {
  const expanded = commands.flatMap((command) =>
    expandShortcutCommand(command, options)
  );
  expanded.forEach((command, index) => {
    command.index = index;
  });
  return expanded;
}

function expandShortcutCommand(command, options) {
  const shortcut = parseShortcut(command.command) ?? parseRunnerWildcard(command.command);
  if (!shortcut) {
    return [command];
  }

  const cwd = commandLookupCwd(command, options);
  if (!shortcut.script.includes("*")) {
    return [shortcutCommand(command, shortcut, shortcut.script, false)];
  }

  const scriptNames = shortcut.runner === "deno"
    ? denoScriptNames(cwd)
    : Object.keys(packageScripts(cwd));
  const matchesScript = wildcardMatcher(shortcut.script);
  return scriptNames
    .filter(matchesScript)
    .map((script) => shortcutCommand(command, shortcut, script, true));
}

function parseShortcut(command) {
  const match = /^([A-Za-z][A-Za-z0-9_-]*):(\S+)(?:\s+(.*))?$/.exec(command);
  if (!match || !SHORTCUT_RUNNERS.has(match[1])) {
    return undefined;
  }
  return { runner: match[1], script: match[2], prefix: "", suffix: match[3] ?? "" };
}

function parseRunnerWildcard(command) {
  const match =
    /((?:npm|yarn|pnpm|bun)\s+run|node\s+--run|deno\s+task)\s+(\S*\*\S*)/.exec(command);
  if (!match) {
    return undefined;
  }
  const runner = runnerFromWildcardCommand(match[1]);
  const scriptEnd = match.index + match[0].length;
  return {
    runner,
    script: match[2],
    prefix: command.slice(0, match.index),
    suffix: command.slice(scriptEnd).trimStart(),
  };
}

function runnerFromWildcardCommand(command) {
  if (command === "node --run") {
    return "node";
  }
  if (command === "deno task") {
    return "deno";
  }
  return command.split(/\s+/, 1)[0];
}

function shortcutCommand(base, shortcut, script, verbatimScript) {
  const name = shortcutCommandName(base, shortcut, script, verbatimScript);
  return new Command({
    index: base.index,
    name,
    command: shortcutCommandText(shortcut, script),
    prefixColor: base.prefixColor,
    env: base.env,
    cwd: base.cwd,
    ipc: base.ipc,
    raw: base.raw,
    hidden: base.hidden,
  });
}

function shortcutCommandName(base, shortcut, script, wildcardExpanded) {
  if (!wildcardExpanded) {
    return base.name === "" ? script : base.name;
  }
  const capture = wildcardCapture(shortcut.script, script) ?? script;
  return base.name === "" ? capture : `${base.name}:${capture}`;
}

function shortcutCommandText(shortcut, script) {
  const scriptArgument = shellQuote(script);
  const suffix = shortcut.suffix ? ` ${shortcut.suffix}` : "";
  const prefix = shortcut.prefix ?? "";
  if (shortcut.runner === "npm") {
    return `${prefix}npm run ${scriptArgument}${suffix}`;
  }
  if (shortcut.runner === "node") {
    return `${prefix}node --run ${scriptArgument}${suffix}`;
  }
  if (shortcut.runner === "deno") {
    return `${prefix}deno task ${scriptArgument}${suffix}`;
  }
  return `${prefix}${shortcut.runner} run ${scriptArgument}${suffix}`;
}

function packageScripts(cwd) {
  const manifest = readJsonFile(join(cwd, "package.json"));
  return manifest && typeof manifest.scripts === "object" && manifest.scripts
    ? manifest.scripts
    : {};
}

function denoTasks(cwd) {
  for (const [fileName, jsonc] of [["deno.json", false], ["deno.jsonc", true]]) {
    const manifest = readJsonFile(join(cwd, fileName), jsonc);
    if (manifest && typeof manifest.tasks === "object" && manifest.tasks) {
      return manifest.tasks;
    }
  }
  return {};
}

function denoScriptNames(cwd) {
  return [
    ...Object.keys(denoTasks(cwd)),
    ...Object.keys(packageScripts(cwd)),
  ];
}

function readJsonFile(path, jsonc = false) {
  try {
    const content = readFileSync(path, "utf8");
    return JSON.parse(jsonc ? stripJsonComments(content) : content);
  } catch (_error) {
    return undefined;
  }
}

function stripJsonComments(content) {
  return content
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .replace(/(^|[^:])\/\/.*$/gm, "$1")
    .replace(/,(\s*[}\]])/g, "$1");
}

function wildcardMatcher(pattern) {
  const { include, omissions } = wildcardPatternParts(pattern);
  const expression = new RegExp(
    `^${include.split("*").map(escapeRegex).join(".*")}$`
  );
  const omissionExpressions = omissions.map(wildcardOmissionExpression);
  return (value) =>
    expression.test(value) &&
    !omissionExpressions.some((omission) => omission.test(value));
}

function wildcardOmissionExpression(pattern) {
  try {
    return new RegExp(pattern);
  } catch (_error) {
    throw new Error(`invalid wildcard omission regular expression: ${pattern}`);
  }
}

function wildcardCapture(pattern, value) {
  const { include } = wildcardPatternParts(pattern);
  const wildcardIndex = include.indexOf("*");
  if (wildcardIndex === -1) {
    return undefined;
  }
  const prefix = include.slice(0, wildcardIndex);
  const suffix = include.slice(wildcardIndex + 1);
  if (!value.startsWith(prefix) || !value.endsWith(suffix)) {
    return undefined;
  }
  return value.slice(prefix.length, value.length - suffix.length);
}

function wildcardPatternParts(pattern) {
  const omissions = [];
  const include = pattern.replace(/\(!([^)]+)\)/g, (_match, omission) => {
    omissions.push(omission);
    return "";
  });
  return { include, omissions };
}

function escapeRegex(value) {
  return value.replace(/[\\^$.*+?()[\]{}|]/g, "\\$&");
}

function expandAdditionalArguments(commands, additionalArguments) {
  if (additionalArguments === undefined || additionalArguments === null) {
    return;
  }
  if (!Array.isArray(additionalArguments)) {
    throw new Error("options.additionalArguments must be an array");
  }
  const args = additionalArguments.map(String);
  for (const command of commands) {
    command.command = command.command.replace(
      /\\?\{([@*]|[1-9][0-9]*)\}/g,
      (match, target) => {
        if (match.startsWith("\\")) {
          return match.slice(1);
        }
        if (args.length > 0) {
          if (/^[1-9][0-9]*$/.test(target)) {
            return args[Number(target) - 1] === undefined
              ? ""
              : shellQuote(args[Number(target) - 1]);
          }
          if (target === "@") {
            return quoteArguments(args);
          }
          if (target === "*") {
            return shellQuote(args.join(" "));
          }
        }
        return "";
      }
    );
  }
}

function quoteArguments(args) {
  return args.map(shellQuote).join(" ");
}

function shellQuote(value) {
  if (process.platform === "win32") {
    return windowsShellQuote(value);
  }
  return posixShellQuote(value);
}

function posixShellQuote(value) {
  const text = String(value);
  if (text === "") {
    return "''";
  }
  if (/^[A-Za-z0-9_@%+=:,./-]+$/.test(text)) {
    return text;
  }
  return `'${text.replaceAll("'", "'\\''")}'`;
}

function windowsShellQuote(value) {
  const text = String(value);
  if (text === "") {
    return '""';
  }
  if (/^[A-Za-z0-9_@+=:,./-]+$/.test(text)) {
    return text;
  }
  return `"${text
    .replace(/(\\*)"/g, '$1$1\\"')
    .replace(/(\\+)$/g, "$1$1")
    .replace(/%/g, "^%")}"`;
}

module.exports = { prepareCommands };
