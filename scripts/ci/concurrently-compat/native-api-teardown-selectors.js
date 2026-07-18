const { resolve } = require("node:path");
const { spawn } = require("node:child_process");
const { PassThrough, Writable } = require("node:stream");
const { createDiscardSink } = require("./native-api-support");

async function runNativeApiTeardownSelectors({ assertEqual, commands }) {
  const { nodeExitCommand, nodePrintCommand } = commands;

  await runNativeApiTeardownCustomSpawnSmoke();
  await runNativeApiNumericNameSuccessSelectorSmoke();
  await runNativeApiNumericNameDefaultInputTargetSmoke();

  async function runNativeApiTeardownCustomSpawnSmoke() {
    const api = require(resolve("index.js"));
    const calls = [];
    let output = "";
    const sink = new Writable({
      write(chunk, _encoding, callback) {
        output += chunk.toString();
        callback();
      },
    });

    const run = api.concurrently([nodePrintCommand("main")], {
      outputStream: sink,
      prefixColors: false,
      spawn(command, options) {
        calls.push(command);
        return spawn(command, [], options);
      },
      teardown: [nodePrintCommand("teardown")],
    });
    const events = await run.result;

    assertEqual(events.length, 1, "native JS API custom spawn teardown event count");
    assertEqual(events[0].exitCode, 0, "native JS API custom spawn teardown exit code");
    assertEqual(calls.length, 2, "native JS API custom spawn teardown call count");
    if (!output.includes("[0] main")) {
      throw new Error(
        `native JS API custom spawn teardown dropped main output: ${JSON.stringify(output)}`
      );
    }
    if (!output.includes("Running teardown command")) {
      throw new Error(
        `native JS API custom spawn teardown missed start log: ${JSON.stringify(output)}`
      );
    }
    if (!output.includes("teardown")) {
      throw new Error(
        `native JS API custom spawn teardown missed raw output: ${JSON.stringify(output)}`
      );
    }
    console.log("compat ok: native JS API custom spawn teardown");
  }

  async function runNativeApiNumericNameSuccessSelectorSmoke() {
    const api = require(resolve("index.js"));
    const sink = createDiscardSink();
    const run = api.concurrently(
      [
        { name: "1", command: nodeExitCommand(7) },
        { command: nodeExitCommand(0) },
      ],
      {
        raw: true,
        outputStream: sink,
        successCondition: "!command-1",
        controllers: [
          {
            handle(commands) {
              return { commands: [commands[1], commands[0]] };
            },
          },
        ],
      }
    );
    const events = await run.result;

    assertEqual(
      events.some((event) => event.index === 0 && event.command.name === "1" && event.exitCode === 7),
      true,
      "native JS API numeric name selector includes named command"
    );
    assertEqual(
      events.some((event) => event.index === 1 && event.exitCode === 0),
      true,
      "native JS API numeric name selector includes indexed command"
    );

    const publicIndexRun = api.concurrently(
      [
        { command: nodeExitCommand(7) },
        { command: nodeExitCommand(0) },
      ],
      {
        raw: true,
        outputStream: sink,
        successCondition: "command-1",
        controllers: [
          {
            handle(commands) {
              return { commands: [commands[1], commands[0]] };
            },
          },
        ],
      }
    );
    const publicIndexEvents = await publicIndexRun.result;
    assertEqual(
      publicIndexEvents.some((event) => event.index === 1 && event.exitCode === 0),
      true,
      "native JS API numeric selector uses public command index"
    );
    console.log("compat ok: native JS API numeric command name success selector");
  }

  async function runNativeApiNumericNameDefaultInputTargetSmoke() {
    const api = require(resolve("index.js"));
    let output = "";
    const input = new PassThrough();
    const sink = new Writable({
      write(chunk, _encoding, callback) {
        output += chunk.toString();
        callback();
      },
    });
    const namedCommand =
      "node -e \"process.stdin.once('data',d=>{console.log('named:'+d.toString().trim());process.exit(0)}); setTimeout(()=>process.exit(2),1000)\"";
    const indexedCommand =
      "node -e \"process.stdin.once('data',d=>{console.log('indexed:'+d.toString().trim());process.exit(0)}); setTimeout(()=>process.exit(0),300)\"";
    const run = api.concurrently(
      [
        { name: "1", command: namedCommand },
        { command: indexedCommand },
      ],
      {
        inputStream: input,
        outputStream: sink,
        defaultInputTarget: "1",
        prefixColors: false,
        controllers: [
          {
            handle(commands) {
              return { commands: [commands[1], commands[0]] };
            },
          },
        ],
      }
    );
    input.end("hello\n");
    await run.result;

    if (!output.includes("named:hello")) {
      throw new Error(
        `native JS API numeric default input target missed named command: ${JSON.stringify(output)}`
      );
    }
    if (output.includes("indexed:hello")) {
      throw new Error(
        `native JS API numeric default input target used indexed command: ${JSON.stringify(output)}`
      );
    }

    let publicIndexOutput = "";
    const publicIndexInput = new PassThrough();
    const publicIndexSink = new Writable({
      write(chunk, _encoding, callback) {
        publicIndexOutput += chunk.toString();
        callback();
      },
    });
    const publicIndexRun = api.concurrently(
      [
        {
          command:
            "node -e \"process.stdin.once('data',d=>{console.log('zero:'+d.toString().trim());process.exit(0)}); setTimeout(()=>process.exit(0),300)\"",
        },
        {
          command:
            "node -e \"process.stdin.once('data',d=>{console.log('one:'+d.toString().trim());process.exit(0)}); setTimeout(()=>process.exit(0),300)\"",
        },
      ],
      {
        inputStream: publicIndexInput,
        outputStream: publicIndexSink,
        defaultInputTarget: 1,
        prefixColors: false,
        controllers: [
          {
            handle(commands) {
              return { commands: [commands[1], commands[0]] };
            },
          },
        ],
      }
    );
    publicIndexInput.end("hello\n");
    await publicIndexRun.result;
    if (!publicIndexOutput.includes("one:hello")) {
      throw new Error(
        `native JS API numeric default input target missed public index: ${JSON.stringify(publicIndexOutput)}`
      );
    }
    if (publicIndexOutput.includes("zero:hello")) {
      throw new Error(
        `native JS API numeric default input target used native position: ${JSON.stringify(publicIndexOutput)}`
      );
    }
    console.log("compat ok: native JS API numeric command name input target");
  }
}

module.exports = { runNativeApiTeardownSelectors };
