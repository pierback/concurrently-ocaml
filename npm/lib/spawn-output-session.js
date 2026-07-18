"use strict";

const { StringDecoder } = require("node:string_decoder");
const { capturesOutput: apiCapturesOutput } = require("./output-destination");
const {
  forceColorLevel,
  formatDate: spawnApiFormatDate,
  shortenText: spawnApiShortenText,
  writeTable: spawnApiWriteTable,
} = require("./output-rendering");
const { arrayOption } = require("./run-policy");

const AUTO_PREFIX_COLORS = [
  "cyan",
  "magenta",
  "green",
  "yellow",
  "blue",
];

function spawnApiOutputState(commands, options) {
  return {
    activeGroupPosition: 0,
    groupBuffers: options.group
      ? new Map(commands.map((command) => [command, []]))
      : undefined,
    groupLineStates: options.group ? new Map() : undefined,
    groupPositions: options.group
      ? new Map(commands.map((command, position) => [command, position]))
      : undefined,
    autoColorPositions: new Map(commands.map((command, position) => [command, position])),
    prefixColors: spawnApiPrefixColorsForCommands(commands, options.prefixColors),
    pendingRestarts: options.group ? new Set() : undefined,
    raw: Boolean(options.raw),
    lastWriteChar: undefined,
    lastWriteCommand: undefined,
    orderedCommands: commands,
    prefixLength: options.padPrefix
      ? commands.reduce((length, command) => {
          const content = spawnApiPrefixContent(command, options);
          return Math.max(length, content?.value.length ?? 0);
        }, 0)
      : 0,
  };
}

function createOutputSession(commands, options, writer) {
  const state = spawnApiOutputState(commands, options);

  return {
    formatterFor(command) {
      return spawnApiOutputFormatter(command, options, writer, state);
    },
    flushClosed(command) {
      spawnApiFlushClosedGroups(command, state, writer);
    },
    flushGrouped() {
      spawnApiFlushGroupedOutput(state, writer);
    },
    setRestartPending(command, pending) {
      if (pending) {
        state.pendingRestarts?.add(command);
      } else {
        state.pendingRestarts?.delete(command);
      }
    },
    logGlobal(message) {
      spawnApiLogGlobalEvent(message, options, state, writer);
    },
    write(chunk, command) {
      writer.write(chunk, command);
    },
    writeTimings(events) {
      spawnApiWriteTimings(events, options, writer);
    },
    finish() {
      return writer.finish();
    },
  };
}

function spawnApiOutputFormatter(command, options, output, outputState) {
  const raw = typeof command.raw === "boolean" ? command.raw : Boolean(options.raw);
  if (raw) {
    return {
      stdout(chunk) {
        spawnApiWriteOutput(command, chunk, outputState, output, false);
      },
      stderr(chunk) {
        if (apiCapturesOutput(options)) {
          spawnApiWriteOutput(command, chunk, outputState, output, false);
          return;
        }
        process.stderr.write(chunk);
      },
      event() {},
      close() {},
    };
  }
  const stdoutDecoder = new StringDecoder("utf8");
  const stderrDecoder = new StringDecoder("utf8");
  const writeText = (text) => {
    if (text === "") {
      return;
    }
    spawnApiLogCommandText(command, text, options, outputState, output);
  };
  return {
    stdout(chunk) {
      writeText(Buffer.isBuffer(chunk) ? stdoutDecoder.write(chunk) : String(chunk));
    },
    stderr(chunk) {
      writeText(Buffer.isBuffer(chunk) ? stderrDecoder.write(chunk) : String(chunk));
    },
    event(text) {
      writeText(text);
    },
    close(event) {
      writeText(stdoutDecoder.end());
      writeText(stderrDecoder.end());
      const lineState = spawnApiLineState(command, outputState);
      if (
        lineState.lastWriteCommand === command &&
        lineState.lastWriteChar !== "\n"
      ) {
        spawnApiWriteOutput(command, "\n", outputState, output);
      }
      const exitCode = event.exitCode ?? 1;
      writeText(`${command.command} exited with code ${exitCode}\n`);
    },
  };
}

function spawnApiPrefix(command, options, outputState) {
  if (options.prefix === "none") {
    return "";
  }
  const content = spawnApiPrefixContent(command, options);
  if (!content) {
    return "";
  }
  if (options.padPrefix) {
    outputState.prefixLength = Math.max(
      outputState.prefixLength,
      content.value.length
    );
  }
  const value = options.padPrefix
    ? content.value.padEnd(outputState.prefixLength, " ")
    : content.value;
  if (content.type === "template" && value === "") {
    return "";
  }
  const bracketed = content.type === "template" ? value : `[${value}]`;
  const colored = spawnApiColorizePrefix(bracketed, command, options, outputState);
  return `${colored} `;
}

function spawnApiPrefixContent(command, options) {
  const prefix = options.prefix;
  if (prefix === undefined) {
    return { type: "default", value: command.name || String(command.index) };
  }
  if (prefix === "index") {
    return { type: "default", value: String(command.index) };
  }
  if (prefix === "name") {
    return { type: "default", value: command.name || String(command.index) };
  }
  if (prefix === "command") {
    return { type: "default", value: spawnApiShortenText(command.command, options) };
  }
  if (prefix === "pid") {
    return {
      type: "default",
      value: command.pid === undefined ? "" : String(command.pid),
    };
  }
  if (prefix === "time") {
    return {
      type: "default",
      value: spawnApiFormatDate(new Date(), options.timestampFormat),
    };
  }
  if (typeof prefix === "string") {
    return {
      type: "template",
      value: spawnApiTemplatePrefix(command, options, prefix),
    };
  }
  return { type: "default", value: command.name || String(command.index) };
}

function spawnApiTemplatePrefix(command, options, prefix) {
  const replacements = {
    "{index}": String(command.index),
    "{name}": command.name,
    "{command}": spawnApiShortenText(command.command, options),
    "{pid}": command.pid === undefined ? "" : String(command.pid),
    "{time}": spawnApiFormatDate(new Date(), options.timestampFormat),
  };
  return prefix.replace(
    /\{(?:index|name|command|pid|time)\}/g,
    (placeholder) => replacements[placeholder]
  );
}

function spawnApiColorizePrefix(prefix, command, options, outputState) {
  const colorLevel = spawnApiColorLevel(options);
  if (colorLevel === 0 || options.prefixColors === false) {
    return prefix;
  }
  const color = spawnApiPrefixColor(command, options, outputState);
  const ansi = spawnApiAnsiColor(color, colorLevel);
  return ansi ? `${ansi.open}${prefix}${ansi.close}` : prefix;
}

function spawnApiPrefixColor(command, options, outputState) {
  if (options.prefixColors !== undefined) {
    const colors = outputState?.prefixColors;
    if (colors.length === 0) {
      return undefined;
    }
    const colorPosition = outputState?.autoColorPositions?.get(command) ?? command.index;
    return spawnApiResolvedPrefixColor(colors, colorPosition);
  }
  return command.prefixColor ?? "reset";
}

function spawnApiPrefixColorsForCommands(commands, prefixColors) {
  if (prefixColors === undefined || prefixColors === false) {
    return undefined;
  }
  const colors =
    typeof prefixColors === "string"
      ? prefixColors.split(",")
      : arrayOption(prefixColors);
  if (colors.length === 0) {
    return [];
  }
  const fallback = colors[colors.length - 1];
  return commands.map((command) => colors[command.index] ?? fallback);
}

function spawnApiResolvedPrefixColor(colors, index) {
  const colorsWithoutAutos = colors.filter((color) => color !== "auto");
  const availableAutoColors = AUTO_PREFIX_COLORS.filter(
    (color) => !colorsWithoutAutos.includes(color.replace(/Bright$/, ""))
  );
  let lastColor;
  for (let position = 0; position <= index; position += 1) {
    const configured = colors[position] ?? colors[colors.length - 1];
    if (configured !== "auto") {
      lastColor = configured;
      continue;
    }
    lastColor = spawnApiNextAutoPrefixColor(availableAutoColors, lastColor);
  }
  return lastColor;
}

function spawnApiNextAutoPrefixColor(availableAutoColors, lastColor) {
  let nextColor = "auto";
  while (nextColor === "auto" || nextColor === lastColor) {
    if (availableAutoColors.length === 0) {
      availableAutoColors.push(...AUTO_PREFIX_COLORS);
    }
    nextColor = String(availableAutoColors.shift());
  }
  return nextColor;
}

function spawnApiColorLevel(options) {
  if (process.env.FORCE_COLOR !== undefined) {
    return forceColorLevel(process.env);
  }
  if (process.env.NO_COLOR !== undefined) {
    return 0;
  }
  if (apiCapturesOutput(options) || process.stdout.isTTY !== true) {
    return 0;
  }
  if (process.env.COLORTERM === "truecolor" || process.env.COLORTERM === "24bit") {
    return 3;
  }
  if (String(process.env.TERM ?? "").includes("256color")) {
    return 2;
  }
  return 1;
}

function spawnApiAnsiColor(color, colorLevel) {
  const styles = String(color ?? "")
    .split(".")
    .map((style) => spawnApiAnsiStyle(style, colorLevel))
    .filter(Boolean);
  if (styles.length === 0) {
    return undefined;
  }
  return {
    open: styles.map((style) => style.open).join(""),
    close: styles
      .slice()
      .reverse()
      .map((style) => style.close)
      .join(""),
  };
}

function spawnApiAnsiStyle(color, colorLevel) {
  const original = String(color ?? "").trim();
  const normalized = original.toLowerCase();
  if (normalized === "") {
    return undefined;
  }
  if (normalized === "reset") {
    return { open: "\u001b[0m", close: "\u001b[0m" };
  }
  const hex = spawnApiHexColor(original, colorLevel);
  if (hex) {
    return hex;
  }
  const key = normalized.replace(/[-_\s]/g, "");
  const style = {
    black: [30, 39],
    red: [31, 39],
    green: [32, 39],
    yellow: [33, 39],
    blue: [34, 39],
    magenta: [35, 39],
    cyan: [36, 39],
    white: [37, 39],
    gray: [90, 39],
    grey: [90, 39],
    blackbright: [90, 39],
    redbright: [91, 39],
    greenbright: [92, 39],
    yellowbright: [93, 39],
    bluebright: [94, 39],
    magentabright: [95, 39],
    cyanbright: [96, 39],
    whitebright: [97, 39],
    bgblack: [40, 49],
    bgred: [41, 49],
    bggreen: [42, 49],
    bgyellow: [43, 49],
    bgblue: [44, 49],
    bgmagenta: [45, 49],
    bgcyan: [46, 49],
    bgwhite: [47, 49],
    bggray: [100, 49],
    bggrey: [100, 49],
    bgblackbright: [100, 49],
    bgredbright: [101, 49],
    bggreenbright: [102, 49],
    bgyellowbright: [103, 49],
    bgbluebright: [104, 49],
    bgmagentabright: [105, 49],
    bgcyanbright: [106, 49],
    bgwhitebright: [107, 49],
    bold: [1, 22],
    dim: [2, 22],
    italic: [3, 23],
    underline: [4, 24],
    inverse: [7, 27],
    hidden: [8, 28],
    strikethrough: [9, 29],
  }[key];
  return style
    ? { open: `\u001b[${style[0]}m`, close: `\u001b[${style[1]}m` }
    : undefined;
}

function spawnApiHexColor(color, colorLevel) {
  const match = /^#?([0-9a-fA-F]{6}|[0-9a-fA-F]{3})$/.exec(color);
  if (!match) {
    return undefined;
  }
  const hex =
    match[1].length === 3
      ? match[1].split("").map((char) => char + char).join("")
      : match[1];
  const red = Number.parseInt(hex.slice(0, 2), 16);
  const green = Number.parseInt(hex.slice(2, 4), 16);
  const blue = Number.parseInt(hex.slice(4, 6), 16);
  if (colorLevel <= 1) {
    return {
      open: `\u001b[${spawnApiAnsi16Code(red, green, blue)}m`,
      close: "\u001b[39m",
    };
  }
  if (colorLevel === 2) {
    return {
      open: `\u001b[38;5;${spawnApiAnsi256Code(red, green, blue)}m`,
      close: "\u001b[39m",
    };
  }
  return {
    open: `\u001b[38;2;${red};${green};${blue}m`,
    close: "\u001b[39m",
  };
}

function spawnApiAnsi16Code(red, green, blue) {
  const code =
    30 +
    (Math.round(blue / 255) << 2) +
    (Math.round(green / 255) << 1) +
    Math.round(red / 255);
  const value = Math.max(red, green, blue);
  return value > 127 ? code + 60 : code;
}

function spawnApiAnsi256Code(red, green, blue) {
  if (red === green && green === blue) {
    if (red < 8) {
      return 16;
    }
    if (red > 248) {
      return 231;
    }
    return Math.round(((red - 8) / 247) * 24) + 232;
  }
  return (
    16 +
    36 * Math.round((red / 255) * 5) +
    6 * Math.round((green / 255) * 5) +
    Math.round((blue / 255) * 5)
  );
}

function spawnApiFlushClosedGroups(command, outputState, output) {
  const groupBuffers = outputState.groupBuffers;
  if (!groupBuffers) {
    return;
  }
  const position = outputState.groupPositions.get(command);
  if (position !== outputState.activeGroupPosition) {
    return;
  }
  for (
    let nextPosition = position + 1;
    nextPosition < outputState.orderedCommands.length;
    nextPosition += 1
  ) {
    outputState.activeGroupPosition = nextPosition;
    const nextCommand = outputState.orderedCommands[nextPosition];
    spawnApiFlushGroupBuffer(nextCommand, outputState, output);
    if (
      nextCommand.state !== "exited" ||
      outputState.pendingRestarts?.has(nextCommand)
    ) {
      break;
    }
  }
}

function spawnApiLogCommandText(command, text, options, outputState, output) {
  const prefix = spawnApiPrefix(command, options, outputState);
  const lineState = spawnApiLineState(command, outputState);
  if (
    lineState.lastWriteCommand !== undefined &&
    lineState.lastWriteCommand !== command &&
    lineState.lastWriteChar !== "\n"
  ) {
    spawnApiWriteOutput(lineState.lastWriteCommand, "\n", outputState, output);
  }
  if (
    lineState.lastWriteChar === undefined ||
    lineState.lastWriteChar === "\n"
  ) {
    spawnApiWriteOutput(command, prefix, outputState, output);
  }
  const textWithPrefixes = text.replaceAll("\n", (lineFeed, offset) =>
    text[offset + 1] ? lineFeed + prefix : lineFeed
  );
  spawnApiWriteOutput(command, textWithPrefixes, outputState, output);
}

function spawnApiLineState(command, outputState) {
  if (!spawnApiBuffersCommand(command, outputState)) {
    return outputState;
  }
  let lineState = outputState.groupLineStates.get(command);
  if (!lineState) {
    lineState = { lastWriteChar: undefined, lastWriteCommand: undefined };
    outputState.groupLineStates.set(command, lineState);
  }
  return lineState;
}

function spawnApiBuffersCommand(command, outputState) {
  const groupBuffers = outputState.groupBuffers;
  if (!groupBuffers) {
    return false;
  }
  const position = outputState.groupPositions.get(command);
  return position !== undefined && position > outputState.activeGroupPosition;
}

function spawnApiWriteOutput(command, chunk, outputState, output, trackLineState = true) {
  if (chunk === "") {
    return;
  }
  if (!spawnApiBuffersCommand(command, outputState)) {
    spawnApiWriteVisibleOutput(command, chunk, outputState, output, trackLineState);
    return;
  }
  outputState.groupBuffers.get(command).push({ chunk, trackLineState });
  if (trackLineState) {
    const lineState = spawnApiLineState(command, outputState);
    lineState.lastWriteCommand = command;
    lineState.lastWriteChar = String(chunk).slice(-1);
  }
}

function spawnApiWriteVisibleOutput(command, chunk, outputState, output, trackLineState = true) {
  output.write(chunk, command);
  if (!trackLineState) {
    return;
  }
  outputState.lastWriteCommand = command;
  outputState.lastWriteChar = String(chunk).slice(-1);
}

function spawnApiFlushGroupedOutput(outputState, output) {
  const groupBuffers = outputState.groupBuffers;
  if (!groupBuffers) {
    return;
  }
  for (const command of outputState.orderedCommands) {
    spawnApiFlushGroupBuffer(command, outputState, output);
  }
}

function spawnApiFlushGroupBuffer(command, outputState, output) {
  const chunks = outputState.groupBuffers?.get(command) ?? [];
  if (chunks.length === 0) {
    return;
  }
  const tracksLineState = chunks.some((record) => record.trackLineState);
  if (
    tracksLineState &&
    !outputState.raw &&
    outputState.lastWriteCommand !== undefined &&
    outputState.lastWriteCommand !== command &&
    outputState.lastWriteChar !== "\n"
  ) {
    spawnApiWriteVisibleOutput(outputState.lastWriteCommand, "\n", outputState, output);
  }
  for (const record of chunks) {
    spawnApiWriteVisibleOutput(
      command,
      record.chunk,
      outputState,
      output,
      record.trackLineState
    );
  }
  outputState.groupBuffers.set(command, []);
}

function spawnApiWriteTimings(events, options, output) {
  if (!options.timings || options.raw) {
    return;
  }
  output.write("--> Timings:\n");
  spawnApiWriteTable(
    [...events]
      .sort(
        (left, right) =>
          right.timings.durationSeconds - left.timings.durationSeconds
      )
      .map((event) => ({
        name: event.command.name,
        duration: (
          new Date(event.timings.endDate).getTime() -
          new Date(event.timings.startDate).getTime()
        ).toLocaleString(),
        "exit code": event.exitCode,
        killed: event.killed,
        command: event.command.command,
      })),
    output
  );
}

function spawnApiLogGlobalEvent(message, options, outputState, output) {
  if (options.raw) {
    return;
  }
  let text;
  if (options.prefixColors === false) {
    text = `--> ${message}\n`;
  } else {
    const reset = spawnApiAnsiColor("reset", spawnApiColorLevel(options));
    text = reset
      ? `${reset.open}-->${reset.close} ${reset.open}${message}${reset.close}\n`
      : `--> ${message}\n`;
  }
  if (
    outputState.lastWriteChar !== undefined &&
    outputState.lastWriteChar !== "\n"
  ) {
    output.write("\n");
  }
  output.write(text);
  outputState.lastWriteCommand = undefined;
  outputState.lastWriteChar = "\n";
}

module.exports = { createOutputSession };
