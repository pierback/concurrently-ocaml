"use strict";

const { Writable } = require("node:stream");
const { StringDecoder } = require("node:string_decoder");
const { Logger } = require("./logger");
const { createOutputWriter: outputWriter } = require("./output-writer");

function spawnApiOutputSink(options) {
  return apiOutputSink(options) ?? {
    write(chunk, _command, callback) {
      process.stdout.write(chunk, callback);
    },
  };
}

function createSpawnOutputDestination(options) {
  return outputWriter(spawnApiOutputSink(options));
}

function attachStreams(child, options) {
  const outputSink = apiOutputSink(options);
  if (!outputSink) {
    return () => Promise.resolve();
  }
  const output = outputWriter(outputSink);
  const write = (chunk) => output.write(chunk);
  child.stdout?.on("data", write);
  child.stderr?.on("data", write);
  return () => output.finish();
}

function stdioFor(options) {
  const output = apiCapturesOutput(options) ? "pipe" : "inherit";
  return ["pipe", output, output];
}

function apiOutputSink(options) {
  const logger = options.logger;
  const outputStreams = uniqueOutputStreams(
    options.outputStream,
    loggerOutputStream(logger)
  );
  if (outputStreams.length > 0 || logger) {
    const writesLogger =
      logger && !streamBackedDefaultLogger(logger, outputStreams);
    const loggerDecoder = writesLogger ? new StringDecoder("utf8") : undefined;
    return {
      write(chunk, command, callback) {
        try {
          if (writesLogger) {
            writeLoggerText(logger, decodeLoggerChunk(loggerDecoder, chunk), command);
          }
          writeOutputStreams(outputStreams, chunk, callback);
        } catch (error) {
          callback(error);
        }
      },
      end() {
        if (writesLogger) {
          writeLoggerText(logger, loggerDecoder.end());
        }
      },
    };
  }
  return undefined;
}

function apiCapturesOutput(options) {
  return Boolean(options.outputStream || options.logger);
}

function loggerOutputStream(logger) {
  if (
    logger &&
    streamBackedDefaultLogger(logger, [logger.options?.outputStream]) &&
    logger.options.outputStream instanceof Writable
  ) {
    return logger.options.outputStream;
  }
  return undefined;
}

function streamBackedDefaultLogger(logger, outputStreams) {
  return Boolean(
    outputStreams.length > 0 &&
      logger instanceof Logger &&
      logger.logCommandText === Logger.prototype.logCommandText &&
      logger.log === Logger.prototype.log
  );
}

function uniqueOutputStreams(...streams) {
  return streams.filter(
    (stream, index) =>
      stream instanceof Writable && streams.indexOf(stream) === index
  );
}

function writeOutputStreams(streams, chunk, callback) {
  if (streams.length === 0) {
    callback();
    return;
  }
  let pendingWrites = streams.length;
  let outputError;
  for (const stream of streams) {
    stream.write(chunk, (error) => {
      if (error && !outputError) {
        outputError = error;
      }
      pendingWrites -= 1;
      if (pendingWrites === 0) {
        callback(outputError);
      }
    });
  }
}

function decodeLoggerChunk(decoder, chunk) {
  return Buffer.isBuffer(chunk) ? decoder.write(chunk) : String(chunk);
}

function writeLoggerText(logger, text, command) {
  if (text === "") {
    return;
  }
  if (typeof logger.logCommandText === "function") {
    logger.logCommandText(text, command);
    return;
  }
  logger.log("", text, command);
}

module.exports = {
  attachNativeOutput: attachStreams,
  capturesOutput: apiCapturesOutput,
  createSpawnOutputDestination,
  stdioFor,
};
