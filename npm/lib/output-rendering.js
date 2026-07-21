"use strict";

function spawnApiShortenText(text, options) {
  let maxLength = Number(options.prefixLength ?? 10);
  if (Number.isNaN(maxLength) || maxLength === 0) {
    maxLength = 10;
  }
  if (!text || text.length <= maxLength) {
    return text;
  }
  const contentLength = maxLength - 2;
  const endLength = Math.floor(contentLength / 2);
  const beginningLength = contentLength - endLength;
  return `${spawnApiSlice(text, 0, beginningLength)}..${spawnApiSlice(
    text,
    text.length - endLength,
    text.length
  )}`;
}

function spawnApiSlice(text, start, end) {
  return text.slice(spawnApiSliceIndex(text, start), spawnApiSliceIndex(text, end));
}

function spawnApiSliceIndex(text, index) {
  const integer = Number.isFinite(index) ? Math.trunc(index) : index;
  if (Number.isNaN(integer)) {
    return 0;
  }
  if (integer < 0) {
    return Math.max(text.length + integer, 0);
  }
  return Math.min(integer, text.length);
}

function spawnApiWriteTable(rows, output) {
  if (rows.length === 0) {
    return;
  }
  const columns = [];
  const widths = new Map();
  for (const row of rows) {
    for (const key of Object.keys(row)) {
      if (!widths.has(key)) {
        columns.push(key);
        widths.set(key, key.length);
      }
      widths.set(
        key,
        Math.max(widths.get(key), String(row[key] ?? "").length)
      );
    }
  }
  const cells = (row) =>
    columns.map((column) =>
      String(row[column] ?? "").padEnd(widths.get(column), " ")
    );
  const border = (left, separator, right) =>
    `--> ${left}${columns
      .map((column) => "─".repeat(widths.get(column) + 2))
      .join(separator)}${right}\n`;
  output.write(border("┌", "┬", "┐"));
  output.write(
    `--> │ ${cells(
      Object.fromEntries(columns.map((column) => [column, column]))
    ).join(" │ ")} │\n`
  );
  output.write(border("├", "┼", "┤"));
  for (const row of rows) {
    output.write(`--> │ ${cells(row).join(" │ ")} │\n`);
  }
  output.write(border("└", "┴", "┘"));
}

function spawnApiFormatDate(date, format = "yyyy-MM-dd HH:mm:ss.SSS") {
  const parts = {
    yyyy: String(date.getFullYear()),
    yy: String(date.getFullYear()).slice(-2),
    MM: spawnApiPad2(date.getMonth() + 1),
    dd: spawnApiPad2(date.getDate()),
    HH: spawnApiPad2(date.getHours()),
    mm: spawnApiPad2(date.getMinutes()),
    ss: spawnApiPad2(date.getSeconds()),
    SSS: String(date.getMilliseconds()).padStart(3, "0"),
  };
  return String(format).replace(
    /yyyy|SSS|yy|MM|dd|HH|mm|ss/g,
    (token) => parts[token]
  );
}

function timingInfoFromCloseEvent({ command, timings, killed, exitCode }) {
  return {
    name: command.name,
    duration: (
      new Date(timings.endDate).getTime() -
      new Date(timings.startDate).getTime()
    ).toLocaleString(),
    "exit code": exitCode,
    killed,
    command: command.command,
  };
}

function spawnApiPad2(value) {
  return String(value).padStart(2, "0");
}

function forceColorEnabled(env) {
  return forceColorLevel(env) > 0;
}

function forceColorLevel(env) {
  const value = env.FORCE_COLOR;
  if (value === undefined) {
    return 0;
  }
  const normalized = String(value).trim().toLowerCase();
  if (normalized === "false" || normalized === "0") {
    return 0;
  }
  if (normalized === "" || normalized === "true") {
    return 1;
  }
  const level = Number.parseInt(normalized, 10);
  if (Number.isNaN(level) || level <= 0) {
    return 0;
  }
  return Math.min(level, 3);
}

module.exports = {
  forceColorEnabled,
  forceColorLevel,
  formatDate: spawnApiFormatDate,
  shortenText: spawnApiShortenText,
  timingInfoFromCloseEvent,
  writeTable: spawnApiWriteTable,
};
