"use strict";

const { Writable } = require("node:stream");
const { Subject } = require("rxjs");
const { createOutputWriter: outputWriter } = require("./output-writer");
const {
  formatDate: spawnApiFormatDate,
  shortenText: spawnApiShortenText,
  writeTable: spawnApiWriteTable,
} = require("./output-rendering");
const { arrayOption } = require("./run-policy");

class Logger {
  constructor(options) {
    options = options ?? {};
    this.options = options;
    this.hide = arrayOption(options.hide).map(String);
    this.raw = Boolean(options.raw);
    this.prefixFormat = options.prefixFormat;
    this.commandLength = options.commandLength || 10;
    this.timestampFormat = options.timestampFormat || "yyyy-MM-dd HH:mm:ss.SSS";
    this.prefixLength = 0;
    this.lastWrite = undefined;
    this.output = new Subject();
  }

  toggleColors() {}
  setPrefixLength(length) {
    this.prefixLength = length;
  }
  shortenText(text) {
    return spawnApiShortenText(text, { prefixLength: this.commandLength });
  }
  getPrefixesFor(command) {
    return {
      pid: command.pid != null ? String(command.pid) : "",
      index: String(command.index),
      name: command.name,
      command: this.shortenText(command.command),
      time: spawnApiFormatDate(new Date(), this.timestampFormat),
    };
  }
  getPrefixContent(command) {
    const prefix = this.prefixFormat || (command.name ? "name" : "index");
    if (prefix === "none") {
      return undefined;
    }
    const prefixes = this.getPrefixesFor(command);
    if (Object.prototype.hasOwnProperty.call(prefixes, prefix)) {
      return { type: "default", value: prefixes[prefix] };
    }
    const value = Object.entries(prefixes).reduce(
      (text, [key, value]) =>
        text.replaceAll(`{${key}}`, String(value)),
      prefix
    );
    return { type: "template", value };
  }
  getPrefix(command) {
    const content = this.getPrefixContent(command);
    if (!content) {
      return "";
    }
    const value = String(content.value).padEnd(this.prefixLength, " ");
    return content.type === "template" ? value : `[${value}]`;
  }
  colorText(_command, text) {
    return text;
  }
  logCommandEvent(text, command) {
    if (this.raw) {
      return;
    }
    const prefix =
      this.lastWrite?.command === command && this.lastWrite.char !== "\n"
        ? "\n"
        : "";
    this.logCommandText(`${prefix}${text}\n`, command);
  }
  logCommandText(text, command) {
    if (
      this.hide.includes(String(command.index)) ||
      this.hide.includes(command.name)
    ) {
      return;
    }
    const prefix = this.colorText(command, this.getPrefix(command));
    this.log(`${prefix}${prefix ? " " : ""}`, text, command);
  }
  logGlobalEvent(text) {
    if (this.raw) {
      return;
    }
    this.log("--> ", `${text}\n`);
  }
  logTable(rows) {
    if (this.raw || !Array.isArray(rows) || rows.length === 0) {
      return;
    }
    const output = outputWriter({
      write: (chunk, _command, callback) => {
        this.logGlobalEvent(String(chunk).replace(/^--> /, "").replace(/\n$/, ""));
        callback();
      },
    });
    spawnApiWriteTable(rows, output);
  }
  log(prefix, text, command) {
    if (this.raw) {
      this.emit(command, text);
      return;
    }
    text = String(text).replace(/\u2026/g, "...");
    if (
      this.lastWrite &&
      this.lastWrite.command !== command &&
      this.lastWrite.char !== "\n"
    ) {
      this.emit(this.lastWrite.command, "\n");
    }
    if (!this.lastWrite || this.lastWrite.char === "\n") {
      this.emit(command, prefix);
    }
    this.emit(
      command,
      text.replaceAll("\n", (lineFeed, index) =>
        lineFeed + (text[index + 1] ? prefix : "")
      )
    );
  }
  emit(command, text) {
    this.lastWrite = { command, char: text[text.length - 1] };
    this.output.next({ command, text });
    const stream = this.options.outputStream;
    if (stream instanceof Writable) {
      stream.write(text);
    }
  }
}

module.exports = { Logger };
