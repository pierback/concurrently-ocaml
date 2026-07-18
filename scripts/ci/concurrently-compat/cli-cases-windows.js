const {
  normalizeHelpStdout,
  normalizeLineOrderStdout,
  normalizeVersionStdout,
} = require("./cli-normalizers");

function createWindowsCases({
  commands,
  inputReadyDelayMs,
  sharedFailingTeardownCase,
  sharedPercentageMaxProcessesCase,
  sharedPrefixColorsRepeatCase,
  sharedRepeatedTeardownCase,
}) {
  const {
    firstInputEchoCommand,
    inputEchoCommand,
    nodeDelayPrintCommand,
    nodeEvalCommand,
    nodeExitCommand,
    nodeHangCommand,
    nodePrintCommand,
    nodeStderrCommand,
    quotedWindowsScriptCommand,
    secondInputEchoCommand,
  } = commands;

  return [
  {
    name: "version long option",
    upstream: "bin/concurrently.spec.ts --version",
    args: ["--version"],
    normalizeStdout: normalizeVersionStdout,
  },
  {
    name: "version short lowercase option",
    upstream: "bin/concurrently.spec.ts -v",
    args: ["-v"],
    normalizeStdout: normalizeVersionStdout,
  },
  {
    name: "version short uppercase option",
    upstream: "bin/concurrently.spec.ts -V",
    args: ["-V"],
    normalizeStdout: normalizeVersionStdout,
  },
  {
    name: "help long option",
    upstream: "bin/concurrently.spec.ts --help",
    args: ["--help"],
    normalizeStdout: normalizeHelpStdout,
  },
  {
    name: "help short option",
    upstream: "bin/concurrently.spec.ts -h",
    args: ["-h"],
    normalizeStdout: normalizeHelpStdout,
  },
  {
    name: "no commands prints help",
    upstream: "bin/concurrently.ts default command handling",
    args: ["--no-color"],
    normalizeStderr: normalizeHelpStdout,
  },
  {
    name: "single success close notification",
    upstream: "src/flow-control/log-exit.spec.ts",
    args: ["--no-color", nodePrintCommand("smoke")],
  },
  {
    name: "failed command close notification",
    upstream: "src/flow-control/log-exit.spec.ts",
    args: ["--no-color", nodeExitCommand(3)],
  },
  {
    name: "formatted stderr is emitted on stdout",
    upstream: "src/logger.spec.ts output stream routing",
    args: ["--no-color", nodeStderrCommand("err")],
  },
  {
    name: "raw suppresses close notification",
    upstream: "bin/concurrently.spec.ts does not log extra output with --raw",
    args: ["--no-color", "--raw", nodePrintCommand("one")],
  },
  {
    name: "hidden named command suppresses output",
    upstream: "bin/concurrently.spec.ts --hide by name",
    args: [
      "--no-color",
      "-g",
      "-n",
      "api,worker",
      "--hide",
      "api",
      nodePrintCommand("hidden"),
      nodePrintCommand("visible"),
    ],
  },
  {
    name: "grouped output is ordered by command index",
    upstream: "bin/concurrently.spec.ts --group",
    args: [
      "--no-color",
      "-g",
      nodeDelayPrintCommand("slow", 80),
      nodePrintCommand("fast"),
    ],
  },
  sharedPrefixColorsRepeatCase,
  {
    name: "pad prefix uses longest label",
    upstream: "bin/concurrently.spec.ts --pad-prefix",
    args: [
      "--no-color",
      "-g",
      "--pad-prefix",
      "-n",
      "api,worker",
      nodePrintCommand("api"),
      nodePrintCommand("worker"),
    ],
  },
  {
    name: "template prefix renders command metadata",
    upstream: "dist/src/logger.js template prefixes",
    args: [
      "--no-color",
      "-g",
      "-n",
      "api",
      "-p",
      "{index}:{name}:{command}",
      nodePrintCommand("ok"),
    ],
  },
  {
    name: "passthrough placeholders",
    upstream: "src/command-parser/expand-arguments.spec.ts",
    args: [
      "--no-color",
      "-g",
      "-P",
      [
        nodeEvalCommand("process.stdout.write(process.argv.slice(1).join('|'))"),
        "{1}",
        "{@}",
        "{*}",
      ].join(" "),
      "--",
      "alpha",
      "beta",
    ],
  },
  {
    name: "quoted cmd script path and spaced argument",
    upstream: "Windows cmd.exe shell quoting",
    args: ["--no-color", quotedWindowsScriptCommand],
  },
  {
    name: "cwd and env reach child command",
    upstream: "src/concurrently.spec.ts command cwd and env",
    args: [
      "--no-color",
      nodeEvalCommand(
        "process.stdout.write(process.cwd()+'\\n'+process.env.CONCURRENTLY_COMPAT_ENV)"
      ),
    ],
    env: { CONCURRENTLY_COMPAT_ENV: "env-ok" },
  },
  {
    name: "max processes serializes command start",
    upstream: "src/concurrently.spec.ts maxProcesses",
    args: [
      "--no-color",
      "-g",
      "-m",
      "1",
      nodePrintCommand("one"),
      nodePrintCommand("two"),
    ],
  },
  sharedPercentageMaxProcessesCase,
  {
    name: "teardown logs start and exit status",
    upstream: "bin/concurrently.spec.ts --teardown",
    args: [
      "--no-color",
      "--teardown",
      nodePrintCommand("bye"),
      nodePrintCommand("hey"),
    ],
  },
  sharedRepeatedTeardownCase,
  sharedFailingTeardownCase,
  {
    name: "kill others default success projection",
    upstream: "bin/concurrently.spec.ts --kill-others",
    args: ["--no-color", "-k", nodePrintCommand("ok"), nodeHangCommand()],
  },
  {
    name: "kill others on fail",
    upstream: "bin/concurrently.spec.ts --kill-others-on-fail",
    args: [
      "--no-color",
      "--kill-others-on-fail",
      nodeHangCommand(),
      nodeExitCommand(1),
    ],
  },
  {
    name: "handle input forwards to default command",
    upstream: "bin/concurrently.spec.ts --handle-input default target",
    args: ["--no-color", "-i", inputEchoCommand],
    input: "stop\n",
    inputDelayMs: inputReadyDelayMs,
  },
  {
    name: "handle input routes by command name",
    upstream: "bin/concurrently.spec.ts --handle-input specified process",
    args: [
      "--no-color",
      "-i",
      "-n",
      "api,worker",
      firstInputEchoCommand,
      secondInputEchoCommand,
    ],
    inputWrites: [
      { delayMs: inputReadyDelayMs, input: "worker:two\n" },
      { afterStdout: "second:two\n", input: "api:one\n" },
    ],
    normalizeStdout: normalizeLineOrderStdout,
  },
  ];
}

module.exports = { createWindowsCases };
