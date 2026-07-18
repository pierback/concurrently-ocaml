const { resolve } = require("node:path");
const { spawn, spawnSync } = require("node:child_process");
const { PassThrough, Writable } = require("node:stream");
const { stripAnsiColors } = require("./native-api-support");

async function runNativeApiCustomInput({
  api,
  assertEqual,
  nativeApiCustomSpawnProgress,
}) {
  await runNativeApiCustomSpawnStdinForwardingSmoke(api);
  runNativeApiCustomSpawnClosedStdinSmoke();

  async function runNativeApiCustomSpawnStdinForwardingSmoke(api) {
    nativeApiCustomSpawnProgress("stdin forwarding");
    let stdinEofOutput = "";
    const stdinEofSink = new Writable({
      write(chunk, _encoding, callback) {
        stdinEofOutput += chunk.toString();
        callback();
      },
    });
    await api.concurrently(
      [
        "node -e \"process.stdin.on('end',()=>{process.stdout.write('eof');process.exit(0)});process.stdin.resume();setTimeout(()=>process.exit(7),500)\"",
      ],
      {
        outputStream: stdinEofSink,
        spawn(command, options) {
          return spawn(command, [], options);
        },
      }
    ).result;
    if (!stdinEofOutput.includes("eof")) {
      throw new Error(
        `native JS API custom spawn left stdin open without input forwarding: ${JSON.stringify(stdinEofOutput)}`
      );
    }

    let inputOutput = "";
    const input = new PassThrough();
    const inputSink = new Writable({
      write(chunk, _encoding, callback) {
        inputOutput += chunk.toString();
        callback();
      },
    });
    const inputRun = api.concurrently(
      [
        {
          name: "target",
          command:
            "node -e \"process.stdin.once('data',d=>{process.stdout.write('input:'+d);process.exit(0)});setTimeout(()=>process.exit(3),1000)\"",
        },
      ],
      {
        defaultInputTarget: "target",
        inputStream: input,
        outputStream: inputSink,
        spawn(command, options) {
          return spawn(command, [], options);
        },
      }
    );
    input.end("hello");
    await inputRun.result;
    if (!inputOutput.includes("input:hello")) {
      throw new Error(
        `native JS API custom spawn did not route input: ${JSON.stringify(inputOutput)}`
      );
    }

    let inputChunkOutput = "";
    const inputChunk = new PassThrough();
    const inputChunkSink = new Writable({
      write(chunk, _encoding, callback) {
        inputChunkOutput += chunk.toString();
        callback();
      },
    });
    const inputChunkRun = api.concurrently(
      [
        {
          name: "target",
          command:
            "node -e \"process.stdin.once('data',d=>{process.stdout.write('chunk:'+d);process.exit(0)});setTimeout(()=>process.exit(3),1000)\"",
        },
      ],
      {
        defaultInputTarget: "target",
        inputStream: inputChunk,
        outputStream: inputChunkSink,
        spawn(command, options) {
          return spawn(command, [], options);
        },
      }
    );
    inputChunk.write("hello");
    await inputChunkRun.result;
    if (!inputChunkOutput.includes("chunk:hello")) {
      throw new Error(
        `native JS API custom spawn buffered plain input chunk: ${JSON.stringify(inputChunkOutput)}`
      );
    }

    let numericNameInputOutput = "";
    const numericNameInput = new PassThrough();
    const numericNameInputSink = new Writable({
      write(chunk, _encoding, callback) {
        numericNameInputOutput += chunk.toString();
        callback();
      },
    });
    const numericNameInputRun = api.concurrently(
      [
        {
          name: "1",
          command:
            "node -e \"process.stdin.once('data',d=>{process.stdout.write('named:'+d);process.exit(0)});setTimeout(()=>process.exit(0),300)\"",
        },
        "node -e \"process.stdin.once('data',d=>{process.stdout.write('indexed:'+d);process.exit(0)});setTimeout(()=>process.exit(0),300)\"",
      ],
      {
        defaultInputTarget: "1",
        inputStream: numericNameInput,
        outputStream: numericNameInputSink,
        spawn(command, options) {
          return spawn(command, [], options);
        },
      }
    );
    numericNameInput.end("1:hello");
    await numericNameInputRun.result;
    if (
      !numericNameInputOutput.includes("indexed:hello") ||
      numericNameInputOutput.includes("named:hello")
    ) {
      throw new Error(
        `native JS API custom spawn routed numeric target to name: ${JSON.stringify(numericNameInputOutput)}`
      );
    }

    let multilineInputOutput = "";
    const multilineInput = new PassThrough();
    const multilineInputSink = new Writable({
      write(chunk, _encoding, callback) {
        multilineInputOutput += chunk.toString();
        callback();
      },
    });
    const multilineInputRun = api.concurrently(
      [
        "node -e \"let s='';process.stdin.on('data',d=>s+=d);process.stdin.on('end',()=>{process.stdout.write('zero:'+s);process.exit(0)});setTimeout(()=>process.exit(9),1000)\"",
        "node -e \"let s='';process.stdin.on('data',d=>s+=d);process.stdin.on('end',()=>{process.stdout.write('one:'+s);process.exit(0)});setTimeout(()=>process.exit(9),1000)\"",
      ],
      {
        inputStream: multilineInput,
        outputStream: multilineInputSink,
        spawn(command, options) {
          return spawn(command, [], options);
        },
      }
    );
    multilineInput.end("1:hello\n0:world\n");
    await multilineInputRun.result;
    if (
      !multilineInputOutput.includes("one:hello") ||
      !multilineInputOutput.includes("zero:world")
    ) {
      throw new Error(
        `native JS API custom spawn did not route multiline input records: ${JSON.stringify(multilineInputOutput)}`
      );
    }

    let splitInputOutput = "";
    const splitInput = new PassThrough();
    const splitInputSink = new Writable({
      write(chunk, _encoding, callback) {
        splitInputOutput += chunk.toString();
        callback();
      },
    });
    const splitInputRun = api.concurrently(
      [
        "node -e \"let s='';process.stdin.on('data',d=>s+=d);process.stdin.on('end',()=>{process.stdout.write('zero:'+s);process.exit(0)});setTimeout(()=>process.exit(9),1000)\"",
        "node -e \"let s='';process.stdin.on('data',d=>s+=d);process.stdin.on('end',()=>{process.stdout.write('one:'+s);process.exit(0)});setTimeout(()=>process.exit(9),1000)\"",
      ],
      {
        inputStream: splitInput,
        outputStream: splitInputSink,
        spawn(command, options) {
          return spawn(command, [], options);
        },
      }
    );
    splitInput.write("1:hel");
    splitInput.end("lo\n0:world\n");
    await splitInputRun.result;
    if (
      !splitInputOutput.includes("one:hello") ||
      !splitInputOutput.includes("zero:world")
    ) {
      throw new Error(
        `native JS API custom spawn routed partial input record early: ${JSON.stringify(splitInputOutput)}`
      );
    }

    let inputEofOutput = "";
    const inputEof = new PassThrough();
    const inputEofSink = new Writable({
      write(chunk, _encoding, callback) {
        inputEofOutput += chunk.toString();
        callback();
      },
    });
    const inputEofRun = api.concurrently(
      [
        "node -e \"let s='';process.stdin.on('data',d=>s+=d);process.stdin.on('end',()=>{process.stdout.write('eof:'+s);process.exit(0)});setTimeout(()=>process.exit(7),1000)\"",
      ],
      {
        inputStream: inputEof,
        outputStream: inputEofSink,
        spawn(command, options) {
          return spawn(command, [], options);
        },
      }
    );
    inputEof.end("hello");
    await inputEofRun.result;
    if (!inputEofOutput.includes("eof:hello")) {
      throw new Error(
        `native JS API custom spawn did not close input: ${JSON.stringify(inputEofOutput)}`
      );
    }

    let blankTargetInputOutput = "";
    const blankTargetInput = new PassThrough();
    const blankTargetInputSink = new Writable({
      write(chunk, _encoding, callback) {
        blankTargetInputOutput += chunk.toString();
        callback();
      },
    });
    const blankTargetInputRun = api.concurrently(
      [
        "node -e \"process.stdin.once('data',d=>{process.stdout.write('blank:'+d);process.exit(0)});setTimeout(()=>process.exit(3),1000)\"",
      ],
      {
        defaultInputTarget: "",
        inputStream: blankTargetInput,
        outputStream: blankTargetInputSink,
        spawn(command, options) {
          return spawn(command, [], options);
        },
      }
    );
    setTimeout(() => blankTargetInput.end("target"), 25);
    await blankTargetInputRun.result;
    if (!blankTargetInputOutput.includes("blank:target")) {
      throw new Error(
        `native JS API custom spawn did not coerce blank input target: ${JSON.stringify(blankTargetInputOutput)}`
      );
    }

    let missingInputTargetOutput = "";
    const missingInputTarget = new PassThrough();
    const missingInputTargetSink = new Writable({
      write(chunk, _encoding, callback) {
        missingInputTargetOutput += chunk.toString();
        callback();
      },
    });
    const missingInputTargetRun = api.concurrently(
      ["node -e \"setTimeout(()=>process.exit(0),50)\""],
      {
        defaultInputTarget: "missing",
        inputStream: missingInputTarget,
        outputStream: missingInputTargetSink,
        spawn(command, options) {
          return spawn(command, [], options);
        },
      }
    );
    missingInputTarget.end("hello");
    await missingInputTargetRun.result;
    const plainMissingInputTargetOutput = stripAnsiColors(missingInputTargetOutput);
    if (
      !plainMissingInputTargetOutput.includes(
        '--> Unable to find command "missing", or it has no stdin open'
      )
    ) {
      throw new Error(
        `native JS API custom spawn missing input target was silent: ${JSON.stringify(missingInputTargetOutput)}`
      );
    }

    let numericInputOutput = "";
    const numericInput = new PassThrough();
    const numericInputSink = new Writable({
      write(chunk, _encoding, callback) {
        numericInputOutput += chunk.toString();
        callback();
      },
    });
    const numericInputRun = api.concurrently(
      [
        "node -e \"setTimeout(()=>process.exit(0),300)\"",
        "node -e \"process.stdin.once('data',d=>{process.stdout.write('indexed:'+d);process.exit(0)});setTimeout(()=>process.exit(0),1000)\"",
        {
          name: "1",
          command:
            "node -e \"process.stdin.once('data',d=>{process.stdout.write('named:'+d);process.exit(0)});setTimeout(()=>process.exit(0),1000)\"",
        },
      ],
      {
        controllers: [
          {
            handle(commands) {
              return { commands: [commands[1], commands[2], commands[0]] };
            },
          },
        ],
        inputStream: numericInput,
        outputStream: numericInputSink,
        spawn(command, options) {
          return spawn(command, [], options);
        },
      }
    );
    numericInput.end("1:hello");
    await numericInputRun.result;
    if (!numericInputOutput.includes("indexed:hello")) {
      throw new Error(
        `native JS API custom spawn numeric input prefix missed public index: ${JSON.stringify(numericInputOutput)}`
      );
    }
    if (numericInputOutput.includes("named:hello")) {
      throw new Error(
        `native JS API custom spawn numeric input prefix used name: ${JSON.stringify(numericInputOutput)}`
      );
    }

    let numericDefaultInputOutput = "";
    const numericDefaultInput = new PassThrough();
    const numericDefaultInputSink = new Writable({
      write(chunk, _encoding, callback) {
        numericDefaultInputOutput += chunk.toString();
        callback();
      },
    });
    const numericDefaultInputRun = api.concurrently(
      [
        "node -e \"setTimeout(()=>process.exit(0),300)\"",
        "node -e \"process.stdin.once('data',d=>{process.stdout.write('indexed:'+d);process.exit(0)});setTimeout(()=>process.exit(0),1000)\"",
        {
          name: "1",
          command:
            "node -e \"process.stdin.once('data',d=>{process.stdout.write('named:'+d);process.exit(0)});setTimeout(()=>process.exit(0),1000)\"",
        },
      ],
      {
        controllers: [
          {
            handle(commands) {
              return { commands: [commands[1], commands[2], commands[0]] };
            },
          },
        ],
        defaultInputTarget: "1",
        inputStream: numericDefaultInput,
        outputStream: numericDefaultInputSink,
        spawn(command, options) {
          return spawn(command, [], options);
        },
      }
    );
    numericDefaultInput.end("hello");
    await numericDefaultInputRun.result;
    if (!numericDefaultInputOutput.includes("named:hello")) {
      throw new Error(
        `native JS API custom spawn numeric default target missed name: ${JSON.stringify(numericDefaultInputOutput)}`
      );
    }
    if (numericDefaultInputOutput.includes("indexed:hello")) {
      throw new Error(
        `native JS API custom spawn numeric default target used public index: ${JSON.stringify(numericDefaultInputOutput)}`
      );
    }
  }

  function runNativeApiCustomSpawnClosedStdinSmoke() {
    nativeApiCustomSpawnProgress("closed stdin");
    const closedStdinCode = `
      const { spawn } = require("node:child_process");
      const { PassThrough, Writable } = require("node:stream");
      const api = require(${JSON.stringify(resolve("index.js"))});
      const input = new PassThrough();
      const sink = new Writable({ write(_chunk, _encoding, callback) { callback(); } });
      const run = api.concurrently([
        { name: "fast", command: ${JSON.stringify("node -e \"process.exit(0)\"")} },
        { name: "slow", command: ${JSON.stringify("node -e \"setTimeout(()=>process.exit(0),800)\"")} },
      ], {
        inputStream: input,
        outputStream: sink,
        spawn(command, options) {
          return spawn(command, [], options);
        },
      });
      run.result.then(
        () => process.stdout.write("done"),
        (error) => {
          process.stderr.write(String(error && error.stack ? error.stack : error));
          process.exit(1);
        }
      );
      let writes = 0;
      const timer = setInterval(() => {
        writes += 1;
        input.write("fast:" + "x".repeat(100000) + "\\n");
        if (writes === 20) {
          clearInterval(timer);
          input.end();
        }
      }, 25);
    `;
    const closedStdinRun = spawnSync(process.execPath, ["-e", closedStdinCode], {
      cwd: resolve("."),
      encoding: "utf8",
      killSignal: "SIGKILL",
      timeout: 2500,
    });
    assertEqual(
      closedStdinRun.status,
      0,
      `native JS API custom spawn closed stdin crashed: ${closedStdinRun.stderr || closedStdinRun.error}`
    );
    assertEqual(
      closedStdinRun.stdout,
      "done",
      "native JS API custom spawn closed stdin completion"
    );
  }

}

module.exports = { runNativeApiCustomInput };
