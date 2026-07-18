const {
  normalizeFractionalMaxProcessesStdout,
  normalizeLineOrderStdout,
  normalizePartialInputTargetStdout,
} = require("./cli-normalizers");

function createSchedulingInputCases({
  commands,
  fixtures,
  inputReadyDelayMs,
  sharedPercentageMaxProcessesCase,
}) {
  const {
    firstChunkInputCommand,
    firstInputEchoCommand,
    inputEchoCommand,
    secondChunkInputCommand,
    secondInputEchoCommand,
    signalReadyCommand,
  } = commands;
  const { restartFixture } = fixtures;

  return [
  {
    name: "max processes serializes command start",
    upstream: "src/concurrently.spec.ts maxProcesses",
    args: ["--no-color", "-g", "-m", "1", "printf one", "printf two"],
  },
  sharedPercentageMaxProcessesCase,
  {
    name: "compact short max processes numeric value",
    upstream: "yargs compact numeric short option value",
    args: [
      "--no-color",
      "-m1",
      "sh -c \"sleep 0.05; printf slow\"",
      "printf fast",
    ],
  },
  {
    name: "compact max processes overrides env alias",
    upstream: "dist/bin/concurrently.js yargs env aliases and CLI precedence",
    args: [
      "--no-color",
      "-m2",
      "sh -c \"sleep 0.05; printf slow\"",
      "printf fast",
    ],
    env: { CONCURRENTLY_M: "1" },
    normalizeStdout: normalizeLineOrderStdout,
  },
  {
    name: "env max processes full name serializes command start",
    upstream: "dist/bin/concurrently.js yargs .env('CONCURRENTLY') full option name",
    args: [
      "--no-color",
      "sh -c \"sleep 0.05; printf slow\"",
      "printf fast",
    ],
    env: { CONCURRENTLY_MAX_PROCESSES: "1" },
  },
  {
    name: "env full name max processes overrides alias",
    upstream: "dist/bin/concurrently.js yargs .env('CONCURRENTLY') env key precedence",
    args: [
      "--no-color",
      "sh -c \"sleep 0.05; printf slow\"",
      "printf fast",
    ],
    env: { CONCURRENTLY_MAX_PROCESSES: "1", CONCURRENTLY_M: "2" },
  },
  {
    name: "max processes zero uses command count",
    upstream: "dist/src/concurrently.js maxProcesses numeric coercion",
    args: [
      "--no-color",
      "-m",
      "0",
      "sh -c 'sleep 0.2; printf slow'",
      "printf fast",
    ],
  },
  {
    name: "max processes invalid uses command count",
    upstream: "dist/src/concurrently.js maxProcesses numeric coercion",
    args: [
      "--no-color",
      "-m",
      "nope",
      "sh -c 'sleep 0.2; printf slow'",
      "printf fast",
    ],
  },
  {
    name: "max processes fractional rounds up through scheduler",
    upstream: "dist/src/concurrently.js maxProcesses for-loop bound",
    args: [
      "--no-color",
      "-m",
      "1.5",
      "sh -c 'sleep 0.3; printf one'",
      "sh -c 'sleep 0.1; printf two'",
      "printf three",
    ],
    normalizeStdout: normalizeFractionalMaxProcessesStdout,
  },
  {
    name: "max processes negative serializes to one",
    upstream: "dist/src/concurrently.js maxProcesses numeric coercion",
    args: [
      "--no-color",
      "-m",
      "-1",
      "sh -c 'sleep 0.1; printf slow'",
      "printf fast",
    ],
  },
  {
    name: "max processes waits for restart exhaustion",
    upstream: "concurrently --help max-processes restart note",
    cwd: restartFixture.cwd,
    args: [
      "--no-color",
      "-m",
      "1",
      "--restart-tries",
      "1",
      "--restart-after",
      "0",
      restartFixture.command,
      "printf second",
    ],
    env: { CONCURRENTLY_RESTART_MARKER: restartFixture.marker },
    prepare: restartFixture.reset,
  },
  {
    name: "handle input forwards to default command",
    upstream: "bin/concurrently.spec.ts --handle-input default target",
    args: ["--no-color", "-i", inputEchoCommand],
    input: "stop\n",
    inputDelayMs: inputReadyDelayMs,
  },
  {
    name: "handle input routes by command index",
    upstream: "bin/concurrently.spec.ts --handle-input specified process",
    args: ["--no-color", "-i", firstInputEchoCommand, secondInputEchoCommand],
    inputWrites: [
      { delayMs: inputReadyDelayMs, input: "1:two\n" },
      { afterStdout: "second:two\n", input: "0:one\n" },
    ],
    normalizeStdout: normalizeLineOrderStdout,
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
  {
    name: "default input target routes unprefixed input",
    upstream: "bin/concurrently.spec.ts --default-input-target",
    args: [
      "--no-color",
      "-i",
      "--default-input-target",
      "1",
      firstInputEchoCommand,
      secondInputEchoCommand,
    ],
    inputWrites: [
      { delayMs: inputReadyDelayMs, input: "two\n" },
      { afterStdout: "second:two\n", input: "0:one\n" },
    ],
    normalizeStdout: normalizeLineOrderStdout,
  },
  {
    name: "handle input routes whole stdin chunk",
    upstream: "src/flow-control/input-handler.js data chunk routing",
    args: [
      "--no-color",
      "-g",
      "-i",
      "-n",
      "first,second",
      firstChunkInputCommand,
      secondChunkInputCommand,
    ],
    input: "1:two\n0:one\n",
  },
  {
    name: "empty default input target routes to first command",
    upstream: "dist/bin/concurrently.js defaultInputTarget Number coercion",
    args: ["--no-color", "-i", "--default-input-target", "", inputEchoCommand],
    input: "hello\n",
    inputDelayMs: inputReadyDelayMs,
  },
  {
    name: "env handle input and default target route input",
    upstream: "dist/bin/concurrently.js yargs .env('CONCURRENTLY') input defaults",
    args: ["--no-color", firstInputEchoCommand, secondInputEchoCommand],
    env: {
      CONCURRENTLY_HANDLE_INPUT: "true",
      CONCURRENTLY_DEFAULT_INPUT_TARGET: "1",
    },
    inputWrites: [
      { delayMs: inputReadyDelayMs, input: "two\n" },
      { afterStdout: "second:two\n", input: "0:one\n" },
    ],
    normalizeStdout: normalizeLineOrderStdout,
  },
  {
    name: "unknown default input target is allowed when unused",
    upstream: "src/flow-control/input-handler.js runtime target resolution",
    args: [
      "--no-color",
      "-i",
      "--default-input-target",
      "missing",
      "printf one",
    ],
  },
  {
    name: "unknown default input target logs when used",
    upstream: "src/flow-control/input-handler.js runtime target resolution",
    args: [
      "--no-color",
      "-i",
      "--default-input-target",
      "missing",
      signalReadyCommand,
    ],
    inputWrites: [{ afterStdout: "[0] ready\n", input: "hello\n" }],
  },
  {
    name: "unknown default input target logs after partial output",
    upstream: "src/logger.js logGlobalEvent lastWrite handling",
    args: [
      "--no-color",
      "-i",
      "--default-input-target",
      "missing",
      "node -e \"process.stdout.write('partial'); setTimeout(()=>process.exit(0),2500)\"",
    ],
    input: "hello\n",
    inputDelayMs: 1500,
    normalizeStdout: normalizePartialInputTargetStdout,
  },
  ];
}

module.exports = { createSchedulingInputCases };
