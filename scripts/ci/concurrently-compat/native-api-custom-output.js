const {
  mkdtempSync,
  rmSync,
} = require("node:fs");
const { tmpdir } = require("node:os");
const { resolve } = require("node:path");
const { spawn, spawnSync } = require("node:child_process");
const { PassThrough, Writable } = require("node:stream");
const {
  createOutputCapture,
  restoreEnvironmentValue,
  waitFor,
} = require("./native-api-support");

async function runNativeApiCustomOutput({
  api,
  assertEqual,
  commands,
  nativeApiCustomSpawnProgress,
  nativeApiExplicitShell,
}) {
  const { nodeEvalCommand } = commands;

  await runNativeApiCustomSpawnBasicOutputSmoke(api);
  await runNativeApiCustomSpawnDefaultOutputSmoke(api);
  await runNativeApiCustomSpawnPrefixFormatsSmoke(api);
  await runNativeApiCustomSpawnInputAndGlobalEventsSmoke(api);
  await runNativeApiCustomSpawnColorsSmoke(api);
  await runNativeApiCustomSpawnCommandPrefixesSmoke(api);
  await runNativeApiCustomSpawnGroupedOutputSmoke(api);
  await runNativeApiCustomSpawnTimingsAndRoutingSmoke(api);

  async function runNativeApiCustomSpawnBasicOutputSmoke(api) {
    nativeApiCustomSpawnProgress("basic output");
    const output = createOutputCapture();
    const calls = [];
    const run = api.concurrently(
      [
        {
          command:
            "node -e \"process.stdout.write(process.env.CONCURRENTLY_ML_SPAWN_SMOKE)\"",
          env: { CONCURRENTLY_ML_SPAWN_SMOKE: "spawn-ok" },
        },
      ],
      {
        outputStream: output.stream,
        env: { CONCURRENTLY_ML_PRIVATE_ENV: "spawn-secret-do-not-leak" },
        shell: nativeApiExplicitShell,
        spawn(command, options) {
          calls.push({ command, options });
          return spawn(command, [], options);
        },
      }
    );
    const events = await run.result;

    assertEqual(calls.length, 1, "native JS API custom spawn call count");
    assertEqual(
      calls[0].options.shell,
      nativeApiExplicitShell,
      "native JS API custom spawn shell"
    );
    assertEqual(
      calls[0].options.env.CONCURRENTLY_ML_SPAWN_SMOKE,
      "spawn-ok",
      "native JS API custom spawn env"
    );
    assertEqual(events.length, 1, "native JS API custom spawn event count");
    assertEqual(events[0].exitCode, 0, "native JS API custom spawn exit code");
    assertEqual(
      events[0].command.spawnOpts,
      undefined,
      "native JS API custom spawn public close event shape"
    );
    if (JSON.stringify(events).includes("spawn-secret-do-not-leak")) {
      throw new Error("native JS API custom spawn leaked spawn options in close event");
    }
    const capturedOutput = output.read();
    if (!capturedOutput.includes("spawn-ok")) {
      throw new Error(
        `native JS API custom spawn did not route output: ${JSON.stringify(capturedOutput)}`
      );
    }
    if (!capturedOutput.includes("[0] spawn-ok")) {
      throw new Error(
        `native JS API custom spawn did not format output: ${JSON.stringify(capturedOutput)}`
      );
    }
  }

  async function runNativeApiCustomSpawnDefaultOutputSmoke(api) {
    nativeApiCustomSpawnProgress("default output");
    let defaultOutput = "";
    const originalStdoutWrite = process.stdout.write;
    process.stdout.write = function writeStdout(chunk, encoding, callback) {
      defaultOutput += Buffer.isBuffer(chunk) ? chunk.toString() : String(chunk);
      const done = typeof encoding === "function" ? encoding : callback;
      if (done) {
        done();
      }
      return true;
    };
    try {
      await api.concurrently(["node -e \"process.stdout.write('default-output')\""], {
        spawn(command, options) {
          return spawn(command, [], options);
        },
      }).result;
    } finally {
      process.stdout.write = originalStdoutWrite;
    }
    if (!defaultOutput.includes("[0] default-output")) {
      throw new Error(
        `native JS API custom spawn dropped default output: ${JSON.stringify(defaultOutput)}`
      );
    }
  }

  async function runNativeApiCustomSpawnPrefixFormatsSmoke(api) {
    nativeApiCustomSpawnProgress("prefix formats");
    let indexPrefixOutput = "";
    const indexPrefixSink = new Writable({
      write(chunk, _encoding, callback) {
        indexPrefixOutput += chunk.toString();
        callback();
      },
    });
    await api.concurrently(
      [{ name: "named", command: "node -e \"process.stdout.write('index-prefix')\"" }],
      {
        outputStream: indexPrefixSink,
        prefix: "index",
        spawn(command, options) {
          return spawn(command, [], options);
        },
      }
    ).result;
    if (!indexPrefixOutput.includes("[0] index-prefix")) {
      throw new Error(
        `native JS API custom spawn ignored index prefix: ${JSON.stringify(indexPrefixOutput)}`
      );
    }

    let literalTemplatePrefixOutput = "";
    const literalTemplatePrefixSink = new Writable({
      write(chunk, _encoding, callback) {
        literalTemplatePrefixOutput += chunk.toString();
        callback();
      },
    });
    await api.concurrently(
      [
        {
          name: "foo$&bar",
          command: "node -e \"process.stdout.write('template-prefix')\"",
        },
      ],
      {
        outputStream: literalTemplatePrefixSink,
        prefix: "{name}",
        spawn(command, options) {
          return spawn(command, [], options);
        },
      }
    ).result;
    if (!literalTemplatePrefixOutput.includes("foo$&bar template-prefix")) {
      throw new Error(
        `native JS API custom spawn template prefix was not literal: ${JSON.stringify(literalTemplatePrefixOutput)}`
      );
    }

    let rawGroupedOutput = "";
    const rawGroupedSink = new Writable({
      write(chunk, _encoding, callback) {
        rawGroupedOutput += chunk.toString();
        callback();
      },
    });
    await api.concurrently(
      [
        "node -e \"process.stdout.write('a');setTimeout(()=>process.exit(0),100)\"",
        "node -e \"process.stdout.write('b')\"",
      ],
      {
        group: true,
        outputStream: rawGroupedSink,
        raw: true,
        spawn(command, options) {
          return spawn(command, [], options);
        },
      }
    ).result;
    assertEqual(
      rawGroupedOutput,
      "ab",
      "native JS API custom spawn raw grouped output"
    );

    let mixedRawOutput = "";
    const mixedRawSink = new Writable({
      write(chunk, _encoding, callback) {
        mixedRawOutput += chunk.toString();
        callback();
      },
    });
    await api.concurrently(
      [
        { command: "node -e \"process.stdout.write('a');setTimeout(()=>process.exit(0),200)\"", raw: true },
        { command: "node -e \"setTimeout(()=>{process.stdout.write('b');process.exit(0)},50)\"", raw: false },
      ],
      {
        outputStream: mixedRawSink,
        prefixColors: false,
        spawn(command, options) {
          return spawn(command, [], options);
        },
      }
    ).result;
    if (!mixedRawOutput.startsWith("a[1] b")) {
      throw new Error(
        `native JS API custom spawn command-level raw changed line state: ${JSON.stringify(mixedRawOutput)}`
      );
    }
  }

  async function runNativeApiCustomSpawnInputAndGlobalEventsSmoke(api) {
    nativeApiCustomSpawnProgress("input and global events");
    let globalPartialOutput = "";
    const globalPartialInput = new PassThrough();
    const globalPartialSink = new Writable({
      write(chunk, _encoding, callback) {
        globalPartialOutput += chunk.toString();
        callback();
      },
    });
    const globalPartialRun = api.concurrently(
      ["node -e \"process.stdout.write('partial');setTimeout(()=>process.exit(0),250)\""],
      {
        defaultInputTarget: "missing",
        inputStream: globalPartialInput,
        outputStream: globalPartialSink,
        prefixColors: false,
        spawn(command, options) {
          return spawn(command, [], options);
        },
      }
    );
    await waitFor(
      () => globalPartialOutput.includes("[0] partial"),
      1000,
      "native JS API custom spawn partial output did not arrive"
    );
    globalPartialInput.end("hello");
    await globalPartialRun.result;
    if (
      globalPartialOutput.includes("partial-->") ||
      !globalPartialOutput.includes(
        "[0] partial\n--> Unable to find command \"missing\", or it has no stdin open\n"
      )
    ) {
      throw new Error(
        `native JS API custom spawn global event reused partial line: ${JSON.stringify(globalPartialOutput)}`
      );
    }

    let colorPrefixOutput = "";
    const colorPrefixSink = new Writable({
      write(chunk, _encoding, callback) {
        colorPrefixOutput += chunk.toString();
        callback();
      },
    });
    const previousForceColor = process.env.FORCE_COLOR;
    const previousNoColor = process.env.NO_COLOR;
    process.env.FORCE_COLOR = "1";
    delete process.env.NO_COLOR;
    try {
      await api.concurrently(["node -e \"process.stdout.write('color-prefix')\""], {
        outputStream: colorPrefixSink,
        prefixColors: ["red"],
        spawn(command, options) {
          return spawn(command, [], options);
        },
      }).result;
    } finally {
      restoreEnvironmentValue("FORCE_COLOR", previousForceColor);
      restoreEnvironmentValue("NO_COLOR", previousNoColor);
    }
    if (!colorPrefixOutput.includes("\u001b[31m[0]\u001b[39m color-prefix")) {
      throw new Error(
        `native JS API custom spawn ignored prefix colors: ${JSON.stringify(colorPrefixOutput)}`
      );
    }

    let noColorGlobalOutput = "";
    const noColorGlobalInput = new PassThrough();
    const noColorGlobalSink = new Writable({
      write(chunk, _encoding, callback) {
        noColorGlobalOutput += chunk.toString();
        callback();
      },
    });
    process.env.FORCE_COLOR = "1";
    delete process.env.NO_COLOR;
    try {
      const noColorGlobalRun = api.concurrently(
        ["node -e \"setTimeout(()=>process.exit(0),50)\""],
        {
          defaultInputTarget: "missing",
          inputStream: noColorGlobalInput,
          outputStream: noColorGlobalSink,
          prefixColors: false,
          spawn(command, options) {
            return spawn(command, [], options);
          },
        }
      );
      noColorGlobalInput.end("hello");
      await noColorGlobalRun.result;
    } finally {
      restoreEnvironmentValue("FORCE_COLOR", previousForceColor);
      restoreEnvironmentValue("NO_COLOR", previousNoColor);
    }
    if (noColorGlobalOutput.includes("\u001b[")) {
      throw new Error(
        `native JS API custom spawn no-color global output contained ANSI: ${JSON.stringify(noColorGlobalOutput)}`
      );
    }
  }

  async function runNativeApiCustomSpawnColorsSmoke(api) {
    nativeApiCustomSpawnProgress("colors");
    const previousForceColor = process.env.FORCE_COLOR;
    const previousNoColor = process.env.NO_COLOR;
    let autoColorPrefixOutput = "";
    const autoColorPrefixSink = new Writable({
      write(chunk, _encoding, callback) {
        autoColorPrefixOutput += chunk.toString();
        callback();
      },
    });
    process.env.FORCE_COLOR = "1";
    delete process.env.NO_COLOR;
    try {
      await api.concurrently(["node -e \"process.stdout.write('auto-color-prefix')\""], {
        outputStream: autoColorPrefixSink,
        prefixColors: ["auto"],
        spawn(command, options) {
          return spawn(command, [], options);
        },
      }).result;
    } finally {
      restoreEnvironmentValue("FORCE_COLOR", previousForceColor);
      restoreEnvironmentValue("NO_COLOR", previousNoColor);
    }
    if (!autoColorPrefixOutput.includes("\u001b[36m[0]\u001b[39m auto-color-prefix")) {
      throw new Error(
        `native JS API custom spawn did not resolve auto prefix color: ${JSON.stringify(autoColorPrefixOutput)}`
      );
    }

    let autoColorControllerOutput = "";
    const autoColorControllerSink = new Writable({
      write(chunk, _encoding, callback) {
        autoColorControllerOutput += chunk.toString();
        callback();
      },
    });
    process.env.FORCE_COLOR = "1";
    delete process.env.NO_COLOR;
    try {
      await api.concurrently(
        [
          "node -e \"process.stdout.write('first')\"",
          "node -e \"process.stdout.write('second')\"",
        ],
        {
          controllers: [
            {
              handle(commands) {
                return { commands: [commands[1]] };
              },
            },
          ],
          outputStream: autoColorControllerSink,
          prefixColors: ["auto"],
          spawn(command, options) {
            return spawn(command, [], options);
          },
        }
      ).result;
    } finally {
      restoreEnvironmentValue("FORCE_COLOR", previousForceColor);
      restoreEnvironmentValue("NO_COLOR", previousNoColor);
    }
    if (!autoColorControllerOutput.includes("\u001b[36m[1]\u001b[39m second")) {
      throw new Error(
        `native JS API custom spawn did not remap auto colors after controllers: ${JSON.stringify(autoColorControllerOutput)}`
      );
    }

    let explicitColorControllerOutput = "";
    const explicitColorControllerSink = new Writable({
      write(chunk, _encoding, callback) {
        explicitColorControllerOutput += chunk.toString();
        callback();
      },
    });
    process.env.FORCE_COLOR = "1";
    delete process.env.NO_COLOR;
    try {
      await api.concurrently(
        [
          "node -e \"process.stdout.write('first')\"",
          "node -e \"process.stdout.write('second')\"",
        ],
        {
          controllers: [
            {
              handle(commands) {
                return { commands: [commands[1]] };
              },
            },
          ],
          outputStream: explicitColorControllerSink,
          prefixColors: ["red", "blue"],
          spawn(command, options) {
            return spawn(command, [], options);
          },
        }
      ).result;
    } finally {
      restoreEnvironmentValue("FORCE_COLOR", previousForceColor);
      restoreEnvironmentValue("NO_COLOR", previousNoColor);
    }
    if (!explicitColorControllerOutput.includes("\u001b[34m[1]\u001b[39m second")) {
      throw new Error(
        `native JS API custom spawn did not preserve explicit color after controllers: ${JSON.stringify(explicitColorControllerOutput)}`
      );
    }

    for (const [prefix, expectedLabel] of [
      ["", "empty-template-prefix"],
      ["{name}", "empty-name-template-prefix"],
    ]) {
      let emptyPrefixOutput = "";
      const emptyPrefixSink = new Writable({
        write(chunk, _encoding, callback) {
          emptyPrefixOutput += chunk.toString();
          callback();
        },
      });
      await api.concurrently(
        [`node -e "process.stdout.write('${expectedLabel}')" `],
        {
          outputStream: emptyPrefixSink,
          prefix,
          spawn(command, options) {
            return spawn(command, [], options);
          },
        }
      ).result;
      if (!emptyPrefixOutput.startsWith(expectedLabel)) {
        throw new Error(
          `native JS API custom spawn emitted an empty-prefix separator: ${JSON.stringify(emptyPrefixOutput)}`
        );
      }
    }

    for (const [prefixColors, expectedLabel] of [
      [undefined, "default-reset-prefix"],
      [["reset"], "explicit-reset-prefix"],
    ]) {
      let resetPrefixOutput = "";
      const resetPrefixSink = new Writable({
        write(chunk, _encoding, callback) {
          resetPrefixOutput += chunk.toString();
          callback();
        },
      });
      process.env.FORCE_COLOR = "1";
      delete process.env.NO_COLOR;
      try {
        await api.concurrently(
          [`node -e "process.stdout.write('${expectedLabel}')" `],
          {
            outputStream: resetPrefixSink,
            ...(prefixColors === undefined ? {} : { prefixColors }),
            spawn(command, options) {
              return spawn(command, [], options);
            },
          }
        ).result;
      } finally {
        restoreEnvironmentValue("FORCE_COLOR", previousForceColor);
        restoreEnvironmentValue("NO_COLOR", previousNoColor);
      }
      if (!resetPrefixOutput.includes(`\u001b[0m[0]\u001b[0m ${expectedLabel}`)) {
        throw new Error(
          `native JS API custom spawn reset prefix mismatch: ${JSON.stringify(resetPrefixOutput)}`
        );
      }
    }
    for (const [forceColor, expectedPrefix] of [
      ["1", "\u001b[92m[0]\u001b[39m hex-color-prefix"],
      ["2", "\u001b[38;5;77m[0]\u001b[39m hex-color-prefix"],
    ]) {
      let hexColorPrefixOutput = "";
      const hexColorPrefixSink = new Writable({
        write(chunk, _encoding, callback) {
          hexColorPrefixOutput += chunk.toString();
          callback();
        },
      });
      process.env.FORCE_COLOR = forceColor;
      delete process.env.NO_COLOR;
      try {
        await api.concurrently(["node -e \"process.stdout.write('hex-color-prefix')\""], {
          outputStream: hexColorPrefixSink,
          prefixColors: ["#23de43"],
          spawn(command, options) {
            return spawn(command, [], options);
          },
        }).result;
      } finally {
        restoreEnvironmentValue("FORCE_COLOR", previousForceColor);
        restoreEnvironmentValue("NO_COLOR", previousNoColor);
      }
      if (!hexColorPrefixOutput.includes(expectedPrefix)) {
        throw new Error(
          `native JS API custom spawn hex color level ${forceColor} mismatch: ${JSON.stringify(hexColorPrefixOutput)}`
        );
      }
    }

    let capturedColorOutput = "";
    const capturedColorSink = new Writable({
      write(chunk, _encoding, callback) {
        capturedColorOutput += chunk.toString();
        callback();
      },
    });
    const stdoutTtyDescriptor = Object.getOwnPropertyDescriptor(process.stdout, "isTTY");
    Object.defineProperty(process.stdout, "isTTY", {
      configurable: true,
      value: true,
    });
    delete process.env.FORCE_COLOR;
    delete process.env.NO_COLOR;
    try {
      await api.concurrently(["node -e \"process.stdout.write('captured-color')\""], {
        outputStream: capturedColorSink,
        prefixColors: ["red"],
        spawn(command, options) {
          return spawn(command, [], options);
        },
      }).result;
    } finally {
      if (stdoutTtyDescriptor) {
        Object.defineProperty(process.stdout, "isTTY", stdoutTtyDescriptor);
      } else {
        delete process.stdout.isTTY;
      }
      restoreEnvironmentValue("FORCE_COLOR", previousForceColor);
      restoreEnvironmentValue("NO_COLOR", previousNoColor);
    }
    if (capturedColorOutput.includes("\u001b[")) {
      throw new Error(
        `native JS API custom spawn colored captured output: ${JSON.stringify(capturedColorOutput)}`
      );
    }

    let templatePrefixOutput = "";
    const templatePrefixSink = new Writable({
      write(chunk, _encoding, callback) {
        templatePrefixOutput += chunk.toString();
        callback();
      },
    });
    await api.concurrently(
      [
        {
          name: "api",
          command: "node -e \"process.stdout.write('template-prefix')\"",
        },
      ],
      {
        outputStream: templatePrefixSink,
        prefix: "{name}:",
        spawn(command, options) {
          return spawn(command, [], options);
        },
      }
    ).result;
    if (!templatePrefixOutput.includes("api: template-prefix")) {
      throw new Error(
        `native JS API custom spawn bracketed template prefix: ${JSON.stringify(templatePrefixOutput)}`
      );
    }
    let unnamedTemplatePrefixOutput = "";
    const unnamedTemplatePrefixSink = new Writable({
      write(chunk, _encoding, callback) {
        unnamedTemplatePrefixOutput += chunk.toString();
        callback();
      },
    });
    await api.concurrently(["node -e \"process.stdout.write('unnamed-template')\""], {
      outputStream: unnamedTemplatePrefixSink,
      prefix: "{name}:",
      spawn(command, options) {
        return spawn(command, [], options);
      },
    }).result;
    if (
      !unnamedTemplatePrefixOutput.includes(": unnamed-template") ||
      unnamedTemplatePrefixOutput.includes("0: unnamed-template")
    ) {
      throw new Error(
        `native JS API custom spawn filled unnamed template prefix: ${JSON.stringify(unnamedTemplatePrefixOutput)}`
      );
    }

    let staticPrefixOutput = "";
    const staticPrefixSink = new Writable({
      write(chunk, _encoding, callback) {
        staticPrefixOutput += chunk.toString();
        callback();
      },
    });
    await api.concurrently(
      ["node -e \"process.stdout.write('static-prefix')\""],
      {
        outputStream: staticPrefixSink,
        prefix: "static",
        spawn(command, options) {
          return spawn(command, [], options);
        },
      }
    ).result;
    if (!staticPrefixOutput.includes("static static-prefix")) {
      throw new Error(
        `native JS API custom spawn ignored static prefix: ${JSON.stringify(staticPrefixOutput)}`
      );
    }
  }

  async function runNativeApiCustomSpawnCommandPrefixesSmoke(api) {
    nativeApiCustomSpawnProgress("command prefixes");
    let timePrefixOutput = "";
    const timePrefixSink = new Writable({
      write(chunk, _encoding, callback) {
        timePrefixOutput += chunk.toString();
        callback();
      },
    });
    await api.concurrently(
      ["node -e \"process.stdout.write('time-prefix')\""],
      {
        outputStream: timePrefixSink,
        prefix: "time",
        timestampFormat: "SSS",
        spawn(command, options) {
          return spawn(command, [], options);
        },
      }
    ).result;
    if (!/\[\d{3}\] time-prefix/.test(timePrefixOutput)) {
      throw new Error(
        `native JS API custom spawn ignored time prefix: ${JSON.stringify(timePrefixOutput)}`
      );
    }

    let commandPrefixOutput = "";
    const commandPrefixSink = new Writable({
      write(chunk, _encoding, callback) {
        commandPrefixOutput += chunk.toString();
        callback();
      },
    });
    await api.concurrently(["node -e \"process.stdout.write('command-prefix')\""], {
      outputStream: commandPrefixSink,
      prefix: "command",
      prefixLength: 6,
      spawn(command, options) {
        return spawn(command, [], options);
      },
    }).result;
    if (!commandPrefixOutput.includes('[no..)"')) {
      throw new Error(
        `native JS API custom spawn ignored command prefix length: ${JSON.stringify(commandPrefixOutput)}`
      );
    }

    let shortCommandPrefixOutput = "";
    const shortCommandPrefixSink = new Writable({
      write(chunk, _encoding, callback) {
        shortCommandPrefixOutput += chunk.toString();
        callback();
      },
    });
    await api.concurrently(["node -e \"process.stdout.write('short-command-prefix')\""], {
      outputStream: shortCommandPrefixSink,
      prefix: "command",
      prefixLength: 1,
      spawn(command, options) {
        return spawn(command, [], options);
      },
    }).result;
    if (!shortCommandPrefixOutput.includes("[..] short-command-prefix")) {
      throw new Error(
        `native JS API custom spawn command prefix length 1 differs: ${JSON.stringify(shortCommandPrefixOutput)}`
      );
    }

    let paddedPrefixOutput = "";
    const paddedPrefixSink = new Writable({
      write(chunk, _encoding, callback) {
        paddedPrefixOutput += chunk.toString();
        callback();
      },
    });
    await api.concurrently(
      [
        { name: "a", command: "node -e \"process.stdout.write('pad-a')\"" },
        { name: "long", command: "node -e \"process.stdout.write('pad-b')\"" },
      ],
      {
        outputStream: paddedPrefixSink,
        padPrefix: true,
        spawn(command, options) {
          return spawn(command, [], options);
        },
      }
    ).result;
    if (!paddedPrefixOutput.includes("[a   ] pad-a")) {
      throw new Error(
        `native JS API custom spawn ignored padded prefix: ${JSON.stringify(paddedPrefixOutput)}`
      );
    }
  }

  async function runNativeApiCustomSpawnGroupedOutputSmoke(api) {
    nativeApiCustomSpawnProgress("grouped output");
    let groupedOutput = "";
    const groupedSink = new Writable({
      write(chunk, _encoding, callback) {
        groupedOutput += chunk.toString();
        callback();
      },
    });
    const groupedRun = api.concurrently(
      [
        "node -e \"process.stdout.write('grouped-slow');setTimeout(()=>process.exit(0),500)\"",
        "node -e \"process.stdout.write('grouped-fast')\"",
      ],
      {
        group: true,
        outputStream: groupedSink,
        spawn(command, options) {
          return spawn(command, [], options);
        },
      }
    );
    await waitFor(
      () => groupedOutput.includes("[0] grouped-slow"),
      300,
      `native JS API custom spawn did not stream active grouped output: ${JSON.stringify(groupedOutput)}`
    );
    await groupedRun.result;
    const slowIndex = groupedOutput.indexOf("[0] grouped-slow");
    const fastIndex = groupedOutput.indexOf("[1] grouped-fast");
    if (slowIndex === -1 || fastIndex === -1 || slowIndex > fastIndex) {
      throw new Error(
        `native JS API custom spawn did not group by command index: ${JSON.stringify(groupedOutput)}`
      );
    }

    let groupedPartialOutput = "";
    const groupedPartialSink = new Writable({
      write(chunk, _encoding, callback) {
        groupedPartialOutput += chunk.toString();
        callback();
      },
    });
    await api.concurrently(
      [
        "node -e \"process.stdout.write('a');setTimeout(()=>{process.stdout.write('b');process.exit(0)},100)\"",
        "node -e \"setTimeout(()=>{process.stdout.write('x');process.exit(0)},10)\"",
      ],
      {
        group: true,
        outputStream: groupedPartialSink,
        spawn(command, options) {
          return spawn(command, [], options);
        },
      }
    ).result;
    if (
      !groupedPartialOutput.includes("[0] ab") ||
      groupedPartialOutput.includes("[0] a\n[0] b")
    ) {
      throw new Error(
        `native JS API custom spawn grouped buffering mutated line state: ${JSON.stringify(groupedPartialOutput)}`
      );
    }

    const groupedRestartRoot = mkdtempSync(
      resolve(tmpdir(), "concurrently-ml-spawn-group-restart-")
    );
    try {
      const groupedRestartMarker = resolve(groupedRestartRoot, "marker");
      let groupedRestartOutput = "";
      const groupedRestartSink = new Writable({
        write(chunk, _encoding, callback) {
          groupedRestartOutput += chunk.toString();
          callback();
        },
      });
      await api.concurrently(
        [
          "node -e \"setTimeout(()=>{process.stdout.write('group-a');process.exit(0)},50)\"",
          "node -e " +
            JSON.stringify(
              "const fs=require('node:fs');const f=process.env.CONCURRENTLY_ML_GROUP_RESTART_MARKER;if(!fs.existsSync(f)){fs.writeFileSync(f,'1');process.stdout.write('group-b1');process.exit(1)}process.stdout.write('group-b2');process.exit(0)"
            ),
          "node -e \"process.stdout.write('group-c');process.exit(0)\"",
        ],
        {
          env: { CONCURRENTLY_ML_GROUP_RESTART_MARKER: groupedRestartMarker },
          group: true,
          outputStream: groupedRestartSink,
          restartDelay: 100,
          restartTries: 1,
          spawn(command, options) {
            return spawn(command, [], options);
          },
        }
      ).result;
      const groupB2Index = groupedRestartOutput.indexOf("group-b2");
      const groupCIndex = groupedRestartOutput.indexOf("group-c");
      if (groupB2Index === -1 || groupCIndex === -1 || groupCIndex < groupB2Index) {
        throw new Error(
          `native JS API custom spawn grouped restart output reordered: ${JSON.stringify(groupedRestartOutput)}`
        );
      }
    } finally {
      rmSync(groupedRestartRoot, { recursive: true, force: true });
    }
  }

  async function runNativeApiCustomSpawnTimingsAndRoutingSmoke(api) {
    nativeApiCustomSpawnProgress("timings and stream routing");
    let timingsOutput = "";
    const timingsSink = new Writable({
      write(chunk, _encoding, callback) {
        timingsOutput += chunk.toString();
        callback();
      },
    });
    await api.concurrently(
      ["node -e \"process.stdout.write('timings-prefix')\""],
      {
        outputStream: timingsSink,
        timings: true,
        timestampFormat: "SSS",
        spawn(command, options) {
          return spawn(command, [], options);
        },
      }
    ).result;
    if (
      !timingsOutput.includes("started at ") ||
      !timingsOutput.includes("stopped at ") ||
      !timingsOutput.includes("--> Timings:")
    ) {
      throw new Error(
        `native JS API custom spawn omitted timings: ${JSON.stringify(timingsOutput)}`
      );
    }

    let rawTimingOutput = "";
    const rawTimingSink = new Writable({
      write(chunk, _encoding, callback) {
        rawTimingOutput += chunk.toString();
        callback();
      },
    });
    await api.concurrently(["node -e \"process.stdout.write('raw-timing')\""], {
      outputStream: rawTimingSink,
      raw: true,
      timings: true,
      spawn(command, options) {
        return spawn(command, [], options);
      },
    }).result;
    assertEqual(rawTimingOutput, "raw-timing", "native JS API custom spawn raw timings");

    let utf8Output = "";
    const utf8Sink = new Writable({
      write(chunk, _encoding, callback) {
        utf8Output += chunk.toString();
        callback();
      },
    });
    await api.concurrently(
      [
        "node -e \"const b=Buffer.from('é');process.stdout.write(b.subarray(0,1));process.stderr.write('X');process.stdout.write(b.subarray(1))\"",
      ],
      {
        outputStream: utf8Sink,
        spawn(command, options) {
          return spawn(command, [], options);
        },
      }
    ).result;
    if (!utf8Output.includes("é") || utf8Output.includes("�")) {
      throw new Error(
        `native JS API custom spawn corrupted split utf8 streams: ${JSON.stringify(utf8Output)}`
      );
    }

    const rawStderrCode = `
      const { spawn } = require("node:child_process");
      const api = require(${JSON.stringify(resolve("index.js"))});
      (async () => {
        await api.concurrently([${JSON.stringify(nodeEvalCommand("process.stderr.write('raw-err')"))}], {
          raw: true,
          spawn(command, options) {
            return spawn(command, [], options);
          },
        }).result.catch(() => {});
      })().catch((error) => {
        console.error(error && error.stack ? error.stack : error);
        process.exit(1);
      });
    `;
    const rawStderrRun = spawnSync(process.execPath, ["-e", rawStderrCode], {
      cwd: resolve("."),
      encoding: "utf8",
    });
    assertEqual(
      rawStderrRun.status,
      0,
      `native JS API custom spawn raw stderr child exited with ${rawStderrRun.status}: ${rawStderrRun.stderr}`
    );
    assertEqual(rawStderrRun.stdout, "", "native JS API custom spawn raw stderr stdout");
    assertEqual(rawStderrRun.stderr, "raw-err", "native JS API custom spawn raw stderr");

    let partialLineOutput = "";
    const partialLineSink = new Writable({
      write(chunk, _encoding, callback) {
        partialLineOutput += chunk.toString();
        callback();
      },
    });
    await api.concurrently(
      [
        "node -e \"process.stdout.write('partial-a');setTimeout(()=>process.exit(0),100)\"",
        "node -e \"setTimeout(()=>{process.stdout.write('partial-b');process.exit(0)},10)\"",
      ],
      {
        outputStream: partialLineSink,
        spawn(command, options) {
          return spawn(command, [], options);
        },
      }
    ).result;
    if (!partialLineOutput.includes("[0] partial-a\n[1] partial-b")) {
      throw new Error(
        `native JS API custom spawn did not separate partial lines: ${JSON.stringify(partialLineOutput)}`
      );
    }

    let pendingWrites = 0;
    let flushedOutput = "";
    const flushingSink = new Writable({
      write(chunk, _encoding, callback) {
        pendingWrites += 1;
        setTimeout(() => {
          flushedOutput += chunk.toString();
          pendingWrites -= 1;
          callback();
        }, 10);
      },
    });
    await api.concurrently(["node -e \"process.stdout.write('flush-ok')\""], {
      outputStream: flushingSink,
      spawn(command, options) {
        return spawn(command, [], options);
      },
    }).result;
    assertEqual(pendingWrites, 0, "native JS API custom spawn pending output writes");
    if (!flushedOutput.includes("flush-ok")) {
      throw new Error(
        `native JS API custom spawn did not flush output: ${JSON.stringify(flushedOutput)}`
      );
    }
  }

}

module.exports = { runNativeApiCustomOutput };
