#!/usr/bin/env node

const {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} = require("node:fs");
const { tmpdir } = require("node:os");
const { delimiter, dirname, resolve, sep } = require("node:path");
const { spawn, spawnSync } = require("node:child_process");
const { EventEmitter } = require("node:events");
const { PassThrough, Writable } = require("node:stream");

const npmConcurrentlyVersion = "9.2.1";
const localBinary = resolve("_build", "default", "bin", "main.exe");
const npmConcurrentlyCommand = resolveNpmConcurrentlyCommand();
const inputEchoCommand =
  "node -e \"process.stdin.once('data',d=>{process.stdout.write(d);process.exit(0)})\"";
const firstInputEchoCommand =
  "node -e \"process.stdin.once('data',d=>{process.stdout.write('first:'+d);process.exit(0)})\"";
const secondInputEchoCommand =
  "node -e \"process.stdin.once('data',d=>{process.stdout.write('second:'+d);process.exit(0)})\"";
const firstChunkInputCommand =
  "node -e \"process.stdin.on('data',d=>process.stdout.write('first:'+d)); setTimeout(()=>process.exit(0),500)\"";
const secondChunkInputCommand =
  "node -e \"process.stdin.on('data',d=>process.stdout.write('second:'+d)); setTimeout(()=>process.exit(0),500)\"";
const signalReadyCommand =
  "node -e \"process.stdout.write('ready\\n'); setTimeout(()=>process.exit(0),5000)\"";
const signalTrappedSuccessCommand =
  "node -e \"process.on('SIGTERM',()=>process.exit(0)); process.stdout.write('ready\\n'); setTimeout(()=>process.exit(99),5000)\"";
const delayedOkCommand = "sh -c 'sleep 0.05; printf ok'";
const delayedOneCommand =
  "node -e \"setTimeout(()=>process.stdout.write('one'),1200)\"";
const forceNoColorEnv = { COLORTERM: null, NO_COLOR: null, TERM: "dumb", FORCE_COLOR: "0" };
const forceFalseColorEnv = { COLORTERM: null, NO_COLOR: null, TERM: "dumb", FORCE_COLOR: "false" };
const forceBasicColorEnv = { COLORTERM: null, NO_COLOR: null, TERM: "dumb", FORCE_COLOR: "1" };
const forceAnsi256ColorEnv = { COLORTERM: null, NO_COLOR: null, TERM: "xterm-256color", FORCE_COLOR: "2" };
const forceAnsi256SuffixColorEnv = { COLORTERM: null, NO_COLOR: null, TERM: "xterm-256color", FORCE_COLOR: "2foo" };
const forceTruecolorEnv = { COLORTERM: "truecolor", NO_COLOR: null, TERM: "xterm-256color", FORCE_COLOR: "3" };
const forceSpacedZeroColorEnv = { COLORTERM: null, NO_COLOR: null, TERM: "dumb", FORCE_COLOR: " 0" };
const forceNanColorEnv = { COLORTERM: null, NO_COLOR: null, TERM: "dumb", FORCE_COLOR: "NaN" };
const shortcutFixture = createShortcutFixture();
const escapedScriptFixture = createEscapedScriptFixture();
const literalWildcardFixture = createLiteralWildcardFixture();
const invalidPackageFixture = createInvalidPackageFixture();
const invalidDenoFixture = createInvalidDenoFixture();
const killTimeoutFixture = createKillTimeoutFixture();
const restartFixture = createRestartFixture();
const inputReadyDelayMs = 2500;

if (!existsSync(localBinary)) {
  throw new Error(`missing local binary: ${localBinary}; run npm run compile first`);
}

const posixCases = [
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
  },
  {
    name: "help short option wins over separate prefix value",
    upstream: "yargs builtin alias parsing before option value binding",
    args: ["--prefix", "-h"],
  },
  {
    name: "help inline false does not request help",
    upstream: "yargs boolean inline value coercion",
    args: ["--no-color", "--help=false", "printf one"],
  },
  {
    name: "no commands prints help",
    upstream: "bin/concurrently.ts default command handling",
    args: ["--no-color"],
  },
  {
    name: "unknown option leaves no commands and prints help",
    upstream: "yargs unknown option parsing before default help",
    args: ["--no-color", "--unknown", "printf one"],
  },
  {
    name: "unknown long option consumes following value",
    upstream: "yargs unknown option parsing",
    args: ["--no-color", "--unknown", "printf one", "printf two"],
  },
  {
    name: "unknown inline option does not consume command",
    upstream: "yargs unknown option parsing",
    args: ["--no-color", "-g", "--unknown=value", "printf one", "printf two"],
  },
  {
    name: "unknown short option consumes following value",
    upstream: "yargs unknown option parsing",
    args: ["--no-color", "-x", "printf one", "printf two"],
  },
  {
    name: "missing prefix value before raw still runs raw command",
    upstream: "yargs option value binding before boolean normalization",
    args: ["--no-color", "--prefix", "--raw", "printf one"],
  },
  {
    name: "missing prefix value before group keeps group flag",
    upstream: "yargs option value binding before boolean normalization",
    args: ["--no-color", "--prefix", "--group", "printf one"],
  },
  {
    name: "missing success value before raw still runs raw command",
    upstream: "yargs option value binding before boolean normalization",
    args: ["--no-color", "--success", "--raw", "printf one"],
  },
  {
    name: "single success close notification",
    upstream: "src/flow-control/log-exit.spec.ts",
    args: ["--no-color", "printf smoke"],
  },
  {
    name: "unmatched success value falls back to all",
    upstream: "dist/src/completion-listener.js fallback success condition",
    args: ["--no-color", "--success", "nope", "printf ok"],
  },
  {
    name: "empty command success selector falls back to all",
    upstream: "dist/src/completion-listener.js command selector regex",
    args: ["--no-color", "--success", "command-", "printf ok"],
  },
  {
    name: "unmatched success fallback still fails failed command",
    upstream: "dist/src/completion-listener.js fallback success condition",
    args: ["--no-color", "--success", "nope", "sh -c 'exit 1'"],
  },
  {
    name: "success first accepts first command success",
    upstream: "dist/src/completion-listener.js first success condition",
    args: ["--no-color", "-m", "1", "--success", "first", "printf ok", "exit 1"],
  },
  {
    name: "success last accepts last command success",
    upstream: "dist/src/completion-listener.js last success condition",
    args: ["--no-color", "-m", "1", "--success", "last", "exit 1", "printf ok"],
  },
  {
    name: "success command index accepts selected command success",
    upstream: "dist/src/completion-listener.js command-index success condition",
    args: [
      "--no-color",
      "-m",
      "1",
      "--success",
      "command-0",
      "printf ok",
      "exit 1",
    ],
  },
  {
    name: "success command name accepts selected command success",
    upstream: "dist/src/completion-listener.js command-name success condition",
    args: [
      "--no-color",
      "-m",
      "1",
      "-n",
      "api,web",
      "--success",
      "command-api",
      "printf ok",
      "exit 1",
    ],
  },
  {
    name: "success negated command ignores selected command failure",
    upstream: "dist/src/completion-listener.js negated command success condition",
    args: [
      "--no-color",
      "-m",
      "1",
      "-n",
      "api,web",
      "--success",
      "!command-web",
      "printf ok",
      "exit 1",
    ],
  },
  {
    name: "failed command close notification",
    upstream: "src/flow-control/log-exit.spec.ts",
    args: ["--no-color", "sh -c 'exit 3'"],
  },
  {
    name: "empty double quoted command is not stripped",
    upstream: "dist/src/command-parser/strip-quotes.js requires quoted content",
    args: ["--no-color", "\"\""],
  },
  {
    name: "empty single quoted command is not stripped",
    upstream: "dist/src/command-parser/strip-quotes.js requires quoted content",
    args: ["--no-color", "''"],
  },
  {
    name: "whitespace command runs as shell no-op",
    upstream: "dist/src/concurrently.js command assertion only rejects empty strings",
    args: ["--no-color", " "],
  },
  {
    name: "quoted whitespace command strips then runs as shell no-op",
    upstream: "dist/src/command-parser/strip-quotes.js strips non-empty quoted content",
    args: ["--no-color", "\" \""],
  },
  {
    name: "formatted stderr is emitted on stdout",
    upstream: "src/logger.spec.ts output stream routing",
    args: ["--no-color", "definitely-not-a-command-xyz"],
  },
  {
    name: "partial stdout without newline",
    upstream: "dist/src/logger.js lastWrite partial-line behavior",
    args: ["--no-color", "node -e \"process.stdout.write('partial')\""],
  },
  {
    name: "crlf stdout preserves carriage returns",
    upstream: "dist/src/logger.js lastWrite line-ending behavior",
    args: ["--no-color", "node -e \"process.stdout.write('a\\r\\nb\\r\\n')\""],
  },
  {
    name: "mixed partial stdout stderr stays on one line",
    upstream: "dist/src/logger.js lastWrite partial-line behavior",
    args: [
      "--no-color",
      "node -e \"process.stdout.write('out');process.stderr.write('err')\"",
    ],
  },
  {
    name: "raw suppresses close notification",
    upstream: "bin/concurrently.spec.ts does not log extra output with --raw",
    args: ["--no-color", "--raw", "printf one"],
  },
  {
    name: "combined short raw and group flags",
    upstream: "yargs short-option-groups for boolean aliases",
    args: ["--no-color", "-rg", "-m", "1", "printf one", "printf two"],
  },
  {
    name: "mixed unknown short prefix still keeps later group flag",
    upstream: "yargs short-option-groups with unknown prefix",
    args: [
      "--no-color",
      "-xg",
      "sh -c \"sleep 0.05; printf slow\"",
      "printf fast",
    ],
  },
  {
    name: "mixed unknown short prefix still keeps later raw flag",
    upstream: "yargs short-option-groups with unknown prefix",
    args: ["--no-color", "-xr", "-m", "1", "printf raw", "printf second"],
  },
  {
    name: "mixed unknown short suffix consumes following command",
    upstream: "yargs short-option-groups with unknown suffix",
    args: ["--no-color", "-rx", "printf raw", "printf second"],
  },
  {
    name: "compact string prefix option is not a value",
    upstream: "yargs short-option-groups do not bind compact string values",
    args: ["--no-color", "-pcommand", "printf one"],
  },
  {
    name: "compact string names option is not a value",
    upstream: "yargs short-option-groups do not bind compact string values",
    args: ["--no-color", "-napi,web", "printf one"],
  },
  {
    name: "env raw suppresses close notification",
    upstream: "dist/bin/concurrently.js yargs .env('CONCURRENTLY')",
    args: ["--no-color", "printf one"],
    env: { CONCURRENTLY_RAW: "true" },
  },
  {
    name: "cli boolean false overrides env true",
    upstream: "dist/bin/concurrently.js yargs boolean coercion and env precedence",
    args: ["--no-color", "--raw=false", "printf one"],
    env: { CONCURRENTLY_RAW: "true" },
  },
  {
    name: "negated raw overrides earlier raw",
    upstream: "yargs boolean negation last value wins",
    args: ["--no-color", "--raw", "--no-raw", "printf one"],
  },
  {
    name: "raw overrides earlier negated raw",
    upstream: "yargs boolean negation last value wins",
    args: ["--no-color", "--no-raw", "--raw", "printf one"],
  },
  {
    name: "inline negated raw value does not clear prior raw",
    upstream: "yargs inline negated boolean value parsing",
    args: ["--no-color", "--raw", "--no-raw=false", "printf one"],
  },
  {
    name: "inline negated raw value does not clear env raw",
    upstream: "dist/bin/concurrently.js yargs env and inline negated booleans",
    args: ["--no-color", "--no-raw=false", "printf one"],
    env: { CONCURRENTLY_RAW: "true" },
  },
  {
    name: "raw non-true inline value coerces false",
    upstream: "yargs boolean inline value coercion",
    args: ["--no-color", "--raw=yes", "printf one"],
  },
  {
    name: "separate false raw value disables raw",
    upstream: "yargs boolean separate value coercion",
    args: ["--no-color", "--raw", "false", "printf one"],
  },
  {
    name: "separate true raw value enables raw",
    upstream: "yargs boolean separate value coercion",
    args: ["--no-color", "--raw", "true", "printf one"],
  },
  {
    name: "separate false help value does not request help",
    upstream: "yargs boolean separate value coercion for built-in aliases",
    args: ["--no-color", "--help", "false", "printf one"],
  },
  {
    name: "separate false after no color remains command",
    upstream: "yargs no-color separate value parsing",
    args: ["--no-color", "false"],
  },
  {
    name: "separate false passthrough value disables passthrough",
    upstream: "yargs boolean separate value coercion before passthrough extraction",
    args: [
      "--no-color",
      "-m",
      "1",
      "-P",
      "false",
      "printf '{1}'",
      "--",
      "printf arg",
    ],
  },
  {
    name: "hidden command suppresses close notification",
    upstream: "bin/concurrently.spec.ts --hide by index",
    args: ["--no-color", "--hide", "0", "printf hidden"],
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
      "printf hidden",
      "printf visible",
    ],
  },
  {
    name: "multiple hidden named commands suppress all output",
    upstream: "bin/concurrently.spec.ts --hide by comma-separated names",
    args: [
      "--no-color",
      "-g",
      "-n",
      "api,worker",
      "--hide",
      "worker,api",
      "printf hidden",
      "printf visible",
    ],
  },
  {
    name: "names select default prefix",
    upstream: "bin/concurrently.spec.ts --names prefixes with names",
    args: ["--no-color", "-g", "-n", "api,worker", "printf api", "printf worker"],
  },
  {
    name: "env names and prefix select name prefix",
    upstream: "docs/cli/configuration.md CONCURRENTLY_ flag defaults",
    args: ["--no-color", "printf api"],
    env: { CONCURRENTLY_NAMES: "api", CONCURRENTLY_PREFIX: "name" },
  },
  {
    name: "env full name prefix overrides alias prefix",
    upstream: "dist/bin/concurrently.js yargs .env('CONCURRENTLY') env key precedence",
    args: ["--no-color", "printf api"],
    env: {
      CONCURRENTLY_NAMES: "api",
      CONCURRENTLY_PREFIX: "index",
      CONCURRENTLY_P: "name",
    },
  },
  {
    name: "deprecated name separator warning",
    upstream: "bin/concurrently.spec.ts --name-separator deprecation warning",
    args: [
      "--no-color",
      "-g",
      "--names",
      "foo|bar",
      "--name-separator",
      "|",
      "printf foo",
      "printf bar",
    ],
  },
  {
    name: "empty name separator splits names into characters",
    upstream: "published concurrently@9.2.1 yargs string split semantics",
    args: [
      "--no-color",
      "-g",
      "--names",
      "a,b",
      "--name-separator",
      "",
      "printf one",
      "printf two",
    ],
  },
  {
    name: "timings lifecycle and summary table",
    upstream: "lib/flow-control/log-timings.ts",
    args: ["--no-color", "--timings", "printf one"],
    normalizeStdout: normalizeTimingsStdout,
  },
  {
    name: "timings named command summary table",
    upstream: "lib/flow-control/log-timings.spec.ts mapCloseEventToTimingInfo",
    args: ["--no-color", "--timings", "-n", "api", "printf one"],
    normalizeStdout: normalizeTimingsStdout,
  },
  {
    name: "timings hidden command summary table",
    upstream: "lib/flow-control/log-timings.ts with logger hide rules",
    args: ["--no-color", "--timings", "--hide", "0", "printf one"],
    normalizeStdout: normalizeTimingsStdout,
  },
  {
    name: "timings raw mode suppresses lifecycle and summary",
    upstream: "lib/logger.ts raw command/global event suppression",
    args: ["--no-color", "--timings", "--raw", "printf one"],
  },
  {
    name: "timings grouped output and sorted table",
    upstream: "lib/flow-control/log-timings.spec.ts sorted timings summary",
    args: [
      "--no-color",
      "--timings",
      "-g",
      "-n",
      "slow,fast",
      "node -e \"setTimeout(()=>process.stdout.write('slow'),80)\"",
      "printf fast",
    ],
    normalizeStdout: normalizeTimingsStdout,
  },
  {
    name: "grouped stderr is emitted on stdout",
    upstream: "src/logger.spec.ts group stream routing",
    args: ["--no-color", "-g", "node -e 'process.stderr.write(\"err\")'"],
  },
  {
    name: "negated group overrides earlier group",
    upstream: "yargs boolean negation last value wins",
    args: [
      "--no-color",
      "--group",
      "--no-group",
      "node -e \"setTimeout(()=>process.stdout.write('slow'),50)\"",
      "printf fast",
    ],
  },
  {
    name: "inline negated group value does not clear prior group",
    upstream: "yargs inline negated boolean value parsing",
    args: [
      "--no-color",
      "--group",
      "--no-group=false",
      "node -e \"setTimeout(()=>process.stdout.write('slow'),50)\"",
      "printf fast",
    ],
  },
  {
    name: "timings failed command lifecycle and table",
    upstream: "lib/flow-control/log-timings.ts complete or error event timing",
    args: ["--no-color", "--timings", "sh -c 'exit 2'"],
    normalizeStdout: normalizeTimingsStdout,
  },
  {
    name: "timings restart attempts final table",
    upstream: "lib/flow-control/log-timings.ts retry close timing",
    args: ["--no-color", "--timings", "--restart-tries", "1", "exit 1"],
    normalizeStdout: normalizeTimingsStdout,
  },
  {
    name: "timings custom timestamp format",
    upstream: "lib/flow-control/log-timings.ts timestampFormat",
    args: ["--no-color", "--timings", "--timestamp-format", "SSS", "printf one"],
    normalizeStdout: normalizeTimingsStdout,
  },
  {
    name: "timings kill-on-fail signal table",
    upstream: "lib/flow-control/log-timings.ts killed close timing",
    args: ["--no-color", "--timings", "--kill-others-on-fail", "sleep 1", "exit 1"],
    normalizeStdout: normalizeSignalKilledTimingsStdout,
  },
  {
    name: "timings kill-on-success signal table",
    upstream: "lib/flow-control/log-timings.ts duration-sorted killed timing",
    args: [
      "--no-color",
      "--timings",
      "--kill-others",
      "--success",
      "first",
      "printf ok",
      "sleep 1",
    ],
    normalizeStdout: normalizeSignalKilledDurationSortedTimingsStdout,
  },
  {
    name: "colored default reset prefix",
    upstream: "dist/src/defaults.js prefixColors reset",
    args: ["printf one"],
    env: forceBasicColorEnv,
  },
  {
    name: "colored red bold prefix",
    upstream: "dist/src/logger.js getChalkPath red.bold",
    args: ["-c", "red.bold", "printf one"],
    env: forceBasicColorEnv,
  },
  {
    name: "env prefix colors full name configures color",
    upstream: "dist/bin/concurrently.js yargs .env('CONCURRENTLY') full option name",
    args: ["printf one"],
    env: { ...forceBasicColorEnv, CONCURRENTLY_PREFIX_COLORS: "red.bold" },
  },
  {
    name: "colored hex prefix truecolor",
    upstream: "dist/src/logger.js chalk.hex",
    args: ["-c", "#336699", "printf one"],
    env: forceTruecolorEnv,
  },
  {
    name: "colored hex prefix basic color level",
    upstream: "chalk.hex with supports-color level 1",
    args: ["-c", "#23de43", "printf one"],
    env: forceBasicColorEnv,
  },
  {
    name: "colored hex prefix ansi256 color level",
    upstream: "chalk.hex with supports-color level 2",
    args: ["-c", "#23de43", "printf one"],
    env: forceAnsi256ColorEnv,
  },
  {
    name: "colored hex prefix parse-int ansi256 color level",
    upstream: "supports-color FORCE_COLOR parseInt coercion",
    args: ["-c", "#23de43", "printf one"],
    env: forceAnsi256SuffixColorEnv,
  },
  {
    name: "colored hex prefix force color zero disables color",
    upstream: "chalk FORCE_COLOR=0 disables color",
    args: ["-c", "#23de43", "printf one"],
    env: forceNoColorEnv,
  },
  {
    name: "colored hex prefix spaced zero disables color",
    upstream: "supports-color FORCE_COLOR parseInt whitespace coercion",
    args: ["-c", "#23de43", "printf one"],
    env: forceSpacedZeroColorEnv,
  },
  {
    name: "colored hex prefix nan disables color",
    upstream: "chalk with invalid FORCE_COLOR value",
    args: ["-c", "#23de43", "printf one"],
    env: forceNanColorEnv,
  },
  {
    name: "colored hex prefix force color false disables color",
    upstream: "supports-color FORCE_COLOR=false disables color",
    args: ["-c", "#23de43", "printf one"],
    env: forceFalseColorEnv,
  },
  {
    name: "force color overrides no color flag",
    upstream: "supports-color FORCE_COLOR env overrides --no-color flag",
    args: ["--no-color", "-c", "red", "printf one"],
    env: forceBasicColorEnv,
  },
  {
    name: "force color overrides no color env default",
    upstream: "supports-color FORCE_COLOR env overrides yargs no-color default",
    args: ["-c", "red", "printf one"],
    env: { ...forceBasicColorEnv, CONCURRENTLY_NO_COLOR: "true" },
  },
  {
    name: "colored short hex prefix truecolor",
    upstream: "dist/src/logger.js chalk.hex short form",
    args: ["-c", "#f00", "printf one"],
    env: forceTruecolorEnv,
  },
  {
    name: "colored invalid prefix falls back to reset",
    upstream: "dist/src/logger.js getChalkPath fallback",
    args: ["-c", "bogus", "printf one"],
    env: forceBasicColorEnv,
  },
  {
    name: "colored grey alias prefix",
    upstream: "chalk gray/grey alias",
    args: ["-c", "grey", "printf one"],
    env: forceBasicColorEnv,
  },
  {
    name: "colored modifier chain prefix",
    upstream: "dist/src/logger.js getChalkPath italic.inverse.strikethrough",
    args: ["-c", "italic.inverse.strikethrough", "printf one"],
    env: forceTruecolorEnv,
  },
  {
    name: "colored background foreground modifier prefix",
    upstream: "dist/src/logger.js getChalkPath bgRed.white.bold",
    args: ["-c", "bgRed.white.bold", "printf one"],
    env: forceTruecolorEnv,
  },
  {
    name: "colored bright foreground modifier prefix",
    upstream: "dist/src/logger.js getChalkPath gray.dim",
    args: ["-c", "gray.dim", "printf one"],
    env: forceTruecolorEnv,
  },
  {
    name: "colored auto prefix palette",
    upstream: "dist/src/defaults.js autoColors",
    args: ["-c", "auto", "-m", "1", "printf one", "printf two"],
    env: forceBasicColorEnv,
  },
  {
    name: "colored bright background prefix",
    upstream: "dist/src/logger.js getChalkPath bgBlueBright.white",
    args: ["-c", "bgBlueBright.white", "printf one"],
    env: forceTruecolorEnv,
  },
  {
    name: "colored function-style prefix falls back to reset",
    upstream: "published concurrently@9.2.1 chalk path fallback",
    args: ["-c", "rgb(1,2,3)", "printf one"],
    env: forceTruecolorEnv,
  },
  {
    name: "colored ansi256-style prefix falls back to reset",
    upstream: "published concurrently@9.2.1 chalk path fallback",
    args: ["-c", "ansi256(123)", "printf one"],
    env: forceTruecolorEnv,
  },
  {
    name: "colored hidden modifier prefix",
    upstream: "dist/src/logger.js getChalkPath hidden",
    args: ["-c", "hidden", "printf one"],
    env: forceTruecolorEnv,
  },
  {
    name: "command prefix length truncates command",
    upstream: "bin/concurrently.spec.ts specifies custom prefix length",
    args: [
      "--no-color",
      "-g",
      "-p",
      "command",
      "-l",
      "6",
      "printf alpha",
      "printf beta",
    ],
  },
  {
    name: "dash-prefixed string prefix value is preserved",
    upstream: "yargs string option value binding",
    args: ["--no-color", "--prefix", "-1", "-m", "1", "printf one", "printf two"],
  },
  {
    name: "unknown dash-prefixed string option value consumes following command",
    upstream: "yargs unknown short option parsing after missing option value",
    args: ["--no-color", "--prefix", "-x", "printf one", "printf two"],
  },
  {
    name: "short inline string prefix value strips equals",
    upstream: "yargs short option inline value parsing",
    args: ["--no-color", "-p=raw", "printf one"],
  },
  {
    name: "short inline string names value strips equals",
    upstream: "yargs short option inline value parsing",
    args: ["--no-color", "-n=api", "printf one"],
  },
  {
    name: "compact short prefix length numeric value",
    upstream: "yargs compact numeric short option value",
    args: ["--no-color", "-p", "command", "-l2", "printf abcdef"],
  },
  {
    name: "env aliases configure prefix length and colors",
    upstream: "dist/bin/concurrently.js yargs env aliases",
    args: ["--no-color", "-p", "command", "printf one"],
    env: { CONCURRENTLY_L: "2", CONCURRENTLY_C: "red.bold" },
  },
  {
    name: "compact prefix length overrides env alias",
    upstream: "dist/bin/concurrently.js yargs env aliases and CLI precedence",
    args: ["--no-color", "-p", "command", "-l4", "printf abcdef"],
    env: { CONCURRENTLY_L: "2" },
  },
  {
    name: "prefix length zero falls back to default",
    upstream: "dist/src/logger.js commandLength default coercion",
    args: [
      "--no-color",
      "--prefix",
      "command",
      "--prefix-length",
      "0",
      "printf abcdef",
    ],
  },
  {
    name: "prefix length negative uses JavaScript slicing",
    upstream: "dist/src/logger.js shortenText slice semantics",
    args: [
      "--no-color",
      "--prefix",
      "command",
      "--prefix-length",
      "-1",
      "printf abcdef",
    ],
  },
  {
    name: "prefix length fractional uses JavaScript slicing",
    upstream: "dist/src/logger.js shortenText slice semantics",
    args: [
      "--no-color",
      "--prefix",
      "command",
      "--prefix-length",
      "1.5",
      "printf abcdef",
    ],
  },
  {
    name: "prefix length subunit fractional uses JavaScript slicing",
    upstream: "dist/src/logger.js shortenText slice semantics",
    args: [
      "--no-color",
      "--prefix",
      "command",
      "--prefix-length",
      "0.5",
      "printf abcdef",
    ],
  },
  {
    name: "prefix length negative fractional uses JavaScript slicing",
    upstream: "dist/src/logger.js shortenText slice semantics",
    args: [
      "--no-color",
      "--prefix",
      "command",
      "--prefix-length",
      "-2.5",
      "printf abcdef",
    ],
  },
  {
    name: "prefix length infinity preserves command",
    upstream: "dist/src/logger.js commandLength Number coercion",
    args: [
      "--no-color",
      "--prefix",
      "command",
      "--prefix-length",
      "Infinity",
      "printf abcdef",
    ],
  },
  {
    name: "prefix length invalid falls back to default",
    upstream: "dist/src/logger.js commandLength default coercion",
    args: [
      "--no-color",
      "--prefix",
      "command",
      "--prefix-length",
      "bogus",
      "printf abcdef",
    ],
  },
  {
    name: "template prefix is not bracketed",
    upstream: "src/logger.spec.ts logs with templated prefixFormat",
    args: ["--no-color", "-g", "-p", "{index}:{name}", "-n", "api", "printf templated"],
  },
  {
    name: "none prefix removes prefix markers",
    upstream: "src/logger.spec.ts logs with no prefix",
    args: ["--no-color", "-g", "-p", "none", "printf bare"],
  },
  {
    name: "pid prefix uses process id",
    upstream: "src/logger.spec.ts logs with pid prefix",
    args: ["--no-color", "-p", "pid", "printf pid"],
    normalizeStdout: normalizePidStdout,
  },
  {
    name: "template prefix interpolates process id",
    upstream: "src/logger.spec.ts logs with pid template",
    args: ["--no-color", "-p", "{pid}:{index}:{name}", "-n", "api", "printf templated"],
    normalizeStdout: normalizePidStdout,
  },
  {
    name: "npm shortcut default name",
    upstream: "dist/src/command-parser/expand-shortcut.js npm:<script>",
    cwd: shortcutFixture.cwd,
    args: ["--no-color", "-g", "npm:print"],
  },
  {
    name: "npm shortcut preserves explicit name",
    upstream: "dist/src/command-parser/expand-shortcut.js commandInfo.name",
    cwd: shortcutFixture.cwd,
    args: ["--no-color", "-g", "-n", "custom", "npm:print"],
  },
  {
    name: "mixed shortcut and literal default prefixes",
    upstream: "dist/src/command-parser/expand-shortcut.js default name only for shortcut",
    cwd: shortcutFixture.cwd,
    args: ["--no-color", "-g", "npm:print", "printf normal"],
  },
  {
    name: "shortcut accepts passthrough script name with spaces",
    upstream: "dist/src/command-parser/expand-shortcut.js before expand-arguments.js",
    cwd: shortcutFixture.cwd,
    args: ["--no-color", "-P", "npm:{1}", "--", "client build"],
  },
  {
    name: "shortcut with whitespace after colon is not expanded",
    upstream: "dist/src/command-parser/expand-shortcut.js requires non-whitespace script",
    cwd: shortcutFixture.cwd,
    args: ["--no-color", "npm: print"],
  },
  {
    name: "node shortcut default name",
    upstream: "dist/src/command-parser/expand-shortcut.js node:<script>",
    cwd: shortcutFixture.cwd,
    args: ["--no-color", "-g", "node:print"],
  },
  {
    name: "yarn shortcut default name",
    upstream: "dist/src/command-parser/expand-shortcut.js yarn:<script>",
    cwd: shortcutFixture.cwd,
    args: ["--no-color", "-g", "yarn:print"],
    env: shortcutFixture.fakeRunnerEnv,
  },
  {
    name: "pnpm shortcut default name",
    upstream: "dist/src/command-parser/expand-shortcut.js pnpm:<script>",
    cwd: shortcutFixture.cwd,
    args: ["--no-color", "-g", "pnpm:print"],
    env: shortcutFixture.fakeRunnerEnv,
  },
  {
    name: "bun shortcut default name",
    upstream: "dist/src/command-parser/expand-shortcut.js bun:<script>",
    cwd: shortcutFixture.cwd,
    args: ["--no-color", "-g", "bun:print"],
    env: shortcutFixture.fakeRunnerEnv,
  },
  {
    name: "deno shortcut default name",
    upstream: "dist/src/command-parser/expand-shortcut.js deno:<script>",
    cwd: shortcutFixture.cwd,
    args: ["--no-color", "-g", "deno:print"],
    env: shortcutFixture.fakeRunnerEnv,
  },
  {
    name: "npm wildcard shortcut expands package scripts",
    upstream: "dist/src/command-parser/expand-wildcard.js npm run <script*>",
    cwd: shortcutFixture.cwd,
    args: ["--no-color", "-g", "npm:build-*"],
  },
  {
    name: "node wildcard shortcut expands package scripts",
    upstream: "dist/src/command-parser/expand-wildcard.js node --run <script*>",
    cwd: shortcutFixture.cwd,
    args: ["--no-color", "-g", "node:build-*"],
  },
  {
    name: "yarn wildcard shortcut expands package scripts",
    upstream: "dist/src/command-parser/expand-wildcard.js yarn run <script*>",
    cwd: shortcutFixture.cwd,
    args: ["--no-color", "-g", "yarn:build-*"],
    env: shortcutFixture.fakeRunnerEnv,
  },
  {
    name: "pnpm wildcard shortcut expands package scripts",
    upstream: "dist/src/command-parser/expand-wildcard.js pnpm run <script*>",
    cwd: shortcutFixture.cwd,
    args: ["--no-color", "-g", "pnpm:build-*"],
    env: shortcutFixture.fakeRunnerEnv,
  },
  {
    name: "bun wildcard shortcut expands package scripts",
    upstream: "dist/src/command-parser/expand-wildcard.js bun run <script*>",
    cwd: shortcutFixture.cwd,
    args: ["--no-color", "-g", "bun:build-*"],
    env: shortcutFixture.fakeRunnerEnv,
  },
  {
    name: "deno wildcard shortcut expands deno tasks",
    upstream: "dist/src/command-parser/expand-wildcard.js deno task <script*>",
    cwd: shortcutFixture.cwd,
    args: ["--no-color", "-g", "deno:task-*"],
    env: shortcutFixture.fakeRunnerEnv,
  },
  {
    name: "npm wildcard shortcut prefixes explicit name",
    upstream: "dist/src/command-parser/expand-wildcard.js commandInfo.name prefix",
    cwd: shortcutFixture.cwd,
    args: ["--no-color", "-g", "-n", "pre", "npm:build-*"],
  },
  {
    name: "npm wildcard shortcut omission filter",
    upstream: "dist/src/command-parser/expand-wildcard.js omission filter",
    cwd: shortcutFixture.cwd,
    args: ["--no-color", "-g", "npm:build-*(!css)"],
  },
  {
    name: "npm wildcard shortcut keeps spaced script unquoted",
    upstream: "dist/src/command-parser/expand-wildcard.js command text construction",
    cwd: shortcutFixture.cwd,
    args: ["--no-color", "-g", "npm:*"],
    normalizeStdout: normalizeNpmLogPaths,
  },
  {
    name: "npm wildcard shortcut drops shell conjunction suffix",
    upstream: "dist/src/command-parser/expand-wildcard.js args capture stops at &",
    cwd: shortcutFixture.cwd,
    args: ["--no-color", "-g", "npm:build-* && printf after"],
  },
  {
    name: "npm wildcard literal command finds embedded runner",
    upstream: "dist/src/command-parser/expand-wildcard.js unanchored runner regex",
    cwd: shortcutFixture.cwd,
    args: ["--no-color", "-g", "printf pre && npm run build-*"],
  },
  {
    name: "npm wildcard shortcut decodes escaped package script keys",
    upstream: "dist/src/command-parser/expand-wildcard.js JSON.parse package scripts",
    cwd: escapedScriptFixture.cwd,
    args: ["--no-color", "-g", "npm:build-*"],
  },
  {
    name: "npm wildcard treats regexp special chars literally",
    upstream: "dist/src/command-parser/expand-wildcard.js escapeRegExp wildcard pattern",
    cwd: literalWildcardFixture.cwd,
    args: ["--no-color", "-g", "npm:build.*"],
    normalizeStdout: normalizeNpmLogPaths,
  },
  {
    name: "npm wildcard ignores invalid package json",
    upstream: "dist/src/command-parser/expand-wildcard.js JSON.parse failure fallback",
    cwd: invalidPackageFixture.cwd,
    bypassVoltaNodeShim: true,
    args: ["--no-color", "-g", "npm:build-*"],
  },
  {
    name: "deno wildcard accepts jsonc trailing commas",
    upstream: "dist/src/jsonc.js trailing comma parser",
    cwd: invalidDenoFixture.validCwd,
    args: ["--no-color", "-g", "deno:task-*"],
    env: invalidDenoFixture.fakeRunnerEnv,
  },
  {
    name: "deno wildcard accepts carriage return line comment",
    upstream: "dist/src/jsonc.js JavaScript line comment regex",
    cwd: invalidDenoFixture.carriageReturnCwd,
    args: ["--no-color", "-g", "deno:task-*"],
    env: invalidDenoFixture.fakeRunnerEnv,
  },
  {
    name: "deno wildcard ignores invalid jsonc",
    upstream: "dist/src/command-parser/expand-wildcard.js JSONC parse failure fallback",
    cwd: invalidDenoFixture.invalidCwd,
    args: ["--no-color", "-g", "deno:task-*"],
    env: invalidDenoFixture.fakeRunnerEnv,
  },
  {
    name: "deno wildcard ignores unterminated jsonc block comment",
    upstream: "dist/src/jsonc.js requires closed block comments",
    cwd: invalidDenoFixture.unterminatedCommentCwd,
    args: ["--no-color", "-g", "deno:task-*"],
    env: invalidDenoFixture.fakeRunnerEnv,
  },
  {
    name: "deno wildcard uses last duplicate tasks field",
    upstream: "JSON.parse duplicate object field semantics",
    cwd: invalidDenoFixture.duplicateCwd,
    args: ["--no-color", "-g", "deno:task-*"],
    env: invalidDenoFixture.fakeRunnerEnv,
  },
  {
    name: "deno wildcard uses Object.keys object key order",
    upstream: "dist/src/command-parser/expand-wildcard.js Object.keys(readDeno().tasks || {})",
    cwd: invalidDenoFixture.objectKeyOrderCwd,
    args: ["--no-color", "-g", "deno:*"],
    env: invalidDenoFixture.fakeRunnerEnv,
  },
  {
    name: "deno wildcard uses Object.keys array task indices",
    upstream: "dist/src/command-parser/expand-wildcard.js Object.keys(readDeno().tasks || {})",
    cwd: invalidDenoFixture.arrayTasksCwd,
    args: ["--no-color", "-g", "deno:*"],
    env: invalidDenoFixture.fakeRunnerEnv,
  },
  {
    name: "deno wildcard uses Object.keys string task indices",
    upstream: "dist/src/command-parser/expand-wildcard.js Object.keys(readDeno().tasks || {})",
    cwd: invalidDenoFixture.stringTasksCwd,
    args: ["--no-color", "-g", "deno:*"],
    env: invalidDenoFixture.fakeRunnerEnv,
  },
  {
    name: "deno wildcard uses Object.keys package script fallback",
    upstream: "dist/src/command-parser/expand-wildcard.js Object.keys(readPackage().scripts || {})",
    cwd: invalidDenoFixture.stringPackageScriptsCwd,
    args: ["--no-color", "-g", "deno:*"],
    env: invalidDenoFixture.fakeRunnerEnv,
  },
  {
    name: "npm wildcard omission matches full script name",
    upstream: "dist/src/command-parser/expand-wildcard.js omission filter",
    cwd: shortcutFixture.cwd,
    args: ["--no-color", "-g", "npm:build-*(!build)"],
  },
  {
    name: "npm wildcard invalid omission exits nonzero",
    upstream: "dist/src/command-parser/expand-wildcard.js omission filter",
    cwd: shortcutFixture.cwd,
    args: ["--no-color", "-g", "npm:build-*(![)"],
    normalizeStderr: normalizeInvalidWildcardOmissionStderr,
  },
  {
    name: "npm wildcard shortcut no matches exits cleanly",
    upstream: "dist/src/command-parser/expand-wildcard.js empty expansion",
    cwd: shortcutFixture.cwd,
    args: ["--no-color", "-g", "npm:no-match-*"],
  },
  {
    name: "no-match wildcard still runs teardown",
    upstream: "bin/concurrently.spec.ts --teardown with empty expansion",
    cwd: shortcutFixture.cwd,
    args: ["--no-color", "--teardown", "printf bye", "npm:no-match-*"],
  },
  {
    name: "pad prefix uses longest label",
    upstream: "bin/concurrently.spec.ts --pad-prefix",
    args: [
      "--no-color",
      "-g",
      "--pad-prefix",
      "-n",
      "foo,barbaz",
      "printf foo",
      "printf bar",
    ],
  },
  {
    name: "grouped passthrough placeholders",
    upstream: "src/command-parser/expand-arguments.spec.ts",
    args: [
      "--no-color",
      "-g",
      "-P",
      "printf '%s\\n' {1}",
      "printf '%s\\n' {@}",
      "printf '%s\\n' {*}",
      "--",
      "hello world",
      "--flag",
    ],
  },
  {
    name: "env passthrough placeholders",
    upstream: "dist/bin/concurrently.js yargs .env('CONCURRENTLY')",
    args: ["--no-color", "-g", "printf '%s\\n' {1}", "--", "hello world"],
    env: { CONCURRENTLY_PASSTHROUGH_ARGUMENTS: "true" },
  },
  {
    name: "passthrough separator before commands prints help",
    upstream: "bin/concurrently.spec.ts --passthrough-arguments command binding",
    args: ["--no-color", "-P", "--", "--watch"],
  },
  {
    name: "passthrough disabled treats arguments as commands",
    upstream: "bin/concurrently.spec.ts --passthrough-arguments disabled",
    args: ["--no-color", "-g", "printf '{1}'", "--", "printf arg"],
  },
  {
    name: "command separator without passthrough preserves dash command",
    upstream: "bin/concurrently.spec.ts command separator handling",
    args: ["--no-color", "--", "--watch"],
  },
  {
    name: "finite restart logs restart notification",
    upstream: "bin/concurrently.spec.ts --restart-tries",
    args: ["--no-color", "--restart-tries", "1", "exit 1"],
  },
  {
    name: "fractional restart tries drops failed completion status",
    upstream: "dist/src/flow-control/restart-process.js take/filter numeric coercion",
    args: ["--no-color", "--restart-tries", "1.5", "exit 1"],
  },
  {
    name: "invalid restart tries drops failed completion status",
    upstream: "dist/src/flow-control/restart-process.js NaN tries coercion",
    args: ["--no-color", "--restart-tries", "bogus", "exit 1"],
  },
  {
    name: "restart after invalid is accepted when unused",
    upstream: "dist/bin/concurrently.js restartAfter Number coercion",
    args: ["--no-color", "--restart-after", "bogus", "printf one"],
  },
  {
    name: "restart after invalid warning is emitted once when used",
    upstream: "dist/src/flow-control/restart-process.js Rx timer NaN warning",
    args: [
      "--no-color",
      "--restart-tries",
      "2",
      "--restart-after",
      "bogus",
      "exit 1",
    ],
    normalizeStderr: normalizeNodeTimerWarningAndShellDiagnosticStderr,
  },
  {
    name: "restart after invalid warning is emitted in raw mode",
    upstream: "dist/src/flow-control/restart-process.js Node warning bypasses logger raw mode",
    args: [
      "--no-color",
      "--raw",
      "--restart-tries",
      "1",
      "--restart-after",
      "bogus",
      "exit 1",
    ],
    normalizeStderr: normalizeNodeTimerWarningPid,
  },
  {
    name: "restart after negative retries immediately",
    upstream: "dist/src/flow-control/restart-process.js Rx timer coercion",
    args: ["--no-color", "--restart-tries", "1", "--restart-after", "-1", "exit 1"],
  },
  {
    name: "restart after fractional retries deterministically",
    upstream: "dist/bin/concurrently.js restartAfter Number coercion",
    args: ["--no-color", "--restart-tries", "1", "--restart-after", "1.5", "exit 1"],
  },
  {
    name: "restart after blank coerces to zero",
    upstream: "dist/src/flow-control/restart-process.js Number('') delay coercion",
    args: ["--no-color", "--restart-tries", "1", "--restart-after", "", "exit 1"],
  },
  {
    name: "restart after exponential retries once",
    upstream: "dist/src/flow-control/restart-process.js exponentialDelay",
    args: [
      "--no-color",
      "--restart-tries",
      "1",
      "--restart-after",
      "exponential",
      "exit 1",
    ],
    timeoutMs: 7000,
  },
  {
    name: "infinite restart tries retry until success",
    upstream: "dist/src/flow-control/restart-process.js infinite tries coercion",
    cwd: restartFixture.cwd,
    args: [
      "--no-color",
      "--restart-tries",
      "Infinity",
      "--restart-after",
      "0",
      restartFixture.command,
    ],
    env: { CONCURRENTLY_RESTART_MARKER: restartFixture.marker },
    prepare: restartFixture.reset,
  },
  {
    name: "negative restart tries retry until success",
    upstream: "bin/concurrently.spec.ts --restart-tries negative retry forever",
    cwd: restartFixture.cwd,
    args: [
      "--no-color",
      "--restart-tries",
      "-1",
      "--restart-after",
      "0",
      restartFixture.command,
    ],
    env: { CONCURRENTLY_RESTART_MARKER: restartFixture.marker },
    prepare: restartFixture.reset,
  },
  {
    name: "teardown logs start and exit status",
    upstream: "bin/concurrently.spec.ts --teardown",
    args: ["--no-color", "--teardown", "printf bye", "printf hey"],
  },
  {
    name: "env teardown logs start and exit status",
    upstream: "dist/bin/concurrently.js yargs .env('CONCURRENTLY') teardown default",
    args: ["--no-color", "printf hey"],
    env: { CONCURRENTLY_TEARDOWN: "printf bye" },
  },
  {
    name: "cli teardown overrides env teardown",
    upstream: "dist/bin/concurrently.js yargs CLI option precedence over env",
    args: ["--no-color", "--teardown", "printf cli", "printf hey"],
    env: { CONCURRENTLY_TEARDOWN: "printf env" },
  },
  {
    name: "empty teardown command exits cleanly",
    upstream: "bin/concurrently.spec.ts --teardown accepts shell-empty command",
    args: ["--no-color", "--teardown", "", "printf hey"],
  },
  {
    name: "teardown raw suppresses status lines",
    upstream: "src/logger.spec.ts logGlobalEvent raw mode",
    args: ["--no-color", "--raw", "--teardown", "printf bye", "printf hey"],
  },
  {
    name: "kill others default success projection",
    upstream: "bin/concurrently.spec.ts --kill-others",
    args: ["--no-color", "-k", "printf ok", "sleep 5"],
  },
  {
    name: "combined short kill and group flags",
    upstream: "yargs short-option-groups for boolean aliases",
    args: ["--no-color", "-kg", "printf ok", "sleep 5"],
  },
  {
    name: "env kill others default success projection",
    upstream: "docs/cli/configuration.md CONCURRENTLY_KILL_OTHERS",
    args: ["--no-color", "printf ok", "sleep 5"],
    env: { CONCURRENTLY_KILL_OTHERS: "true" },
  },
  {
    name: "kill others success first projection",
    upstream: "bin/concurrently.spec.ts exiting conditions --success first",
    args: ["--no-color", "-k", "-s", "first", "printf ok", "sleep 5"],
  },
  {
    name: "parent sigint forwards signal and exits zero",
    upstream: "dist/src/flow-control/kill-on-signal.js SIGINT exit projection",
    args: ["--no-color", signalReadyCommand],
    parentSignal: {
      signal: "SIGINT",
      afterStdout: "ready\n",
      delayMs: 100,
    },
  },
  {
    name: "parent sigterm forwards signal and exits one",
    upstream: "dist/src/flow-control/kill-on-signal.js SIGTERM forwarding",
    args: ["--no-color", signalReadyCommand],
    parentSignal: {
      signal: "SIGTERM",
      afterStdout: "ready\n",
      delayMs: 100,
    },
  },
  {
    name: "parent sigterm preserves trapped success",
    upstream: "dist/src/flow-control/kill-on-signal.js non-SIGINT exit projection",
    args: ["--no-color", "--timings", signalTrappedSuccessCommand],
    normalizeStdout: normalizeTimingsStdout,
    parentSignal: {
      signal: "SIGTERM",
      afterStdout: "ready\n",
      delayMs: 100,
    },
  },
  {
    name: "parent sigterm skips queued commands",
    upstream: "dist/src/flow-control/kill-on-signal.js aborts unstarted commands",
    args: ["--no-color", "-m", "1", signalTrappedSuccessCommand, signalReadyCommand],
    parentSignal: {
      signal: "SIGTERM",
      afterStdout: "ready\n",
      delayMs: 0,
    },
  },
  {
    name: "parent sigterm preserves restart policy",
    upstream: "dist/src/flow-control/kill-on-signal.js non-SIGINT restart projection",
    cwd: restartFixture.cwd,
    args: [
      "--no-color",
      "--restart-tries",
      "1",
      "--restart-after",
      "0",
      restartFixture.signalCommand,
    ],
    env: { CONCURRENTLY_RESTART_MARKER: restartFixture.marker },
    prepare: restartFixture.reset,
    parentSignal: {
      signal: "SIGTERM",
      afterStdout: "ready\n",
      delayMs: 100,
    },
  },
  {
    name: "parent sigint suppresses restart policy",
    upstream: "dist/src/flow-control/kill-on-signal.js SIGINT abort projection",
    cwd: restartFixture.cwd,
    args: [
      "--no-color",
      "--restart-tries",
      "1",
      "--restart-after",
      "0",
      restartFixture.signalCommand,
    ],
    env: { CONCURRENTLY_RESTART_MARKER: restartFixture.marker },
    prepare: restartFixture.reset,
    parentSignal: {
      signal: "SIGINT",
      afterStdout: "ready\n",
      delayMs: 100,
    },
  },
  {
    name: "parent sighup forwards signal and exits one",
    upstream: "dist/src/flow-control/kill-on-signal.js SIGHUP forwarding",
    args: ["--no-color", signalReadyCommand],
    parentSignal: {
      signal: "SIGHUP",
      afterStdout: "ready\n",
      delayMs: 100,
    },
  },
  {
    name: "kill signal sigint reaches sibling",
    upstream: "dist/src/flow-control/kill-others.js configured killSignal",
    args: [
      "--no-color",
      "-k",
      "--kill-signal",
      "SIGINT",
      "trap 'exit 130' INT; sleep 1",
      "printf ok",
    ],
    normalizeStatus: normalizeSignalTrapStatus,
    normalizeStdout: normalizeSignalTrapCloseStatus,
  },
  {
    name: "kill signal alias sigint reaches sibling",
    upstream: "dist/bin/concurrently.js --ks alias",
    args: [
      "--no-color",
      "-k",
      "--ks",
      "SIGINT",
      "trap 'exit 130' INT; sleep 1",
      "printf ok",
    ],
    normalizeStatus: normalizeSignalTrapStatus,
    normalizeStdout: normalizeSignalTrapCloseStatus,
  },
  {
    name: "kill signal sigusr1 reaches sibling",
    upstream: "dist/src/flow-control/kill-others.js configured killSignal",
    args: [
      "--no-color",
      "-k",
      "--kill-signal",
      "SIGUSR1",
      "trap 'exit 138' USR1; while :; do :; done",
      "printf ok",
    ],
    normalizeStatus: normalizeSignalTrapStatus,
    normalizeStdout: normalizeSignalTrapCloseStatus,
  },
  {
    name: "kill signal sigterm trapped shell child preserves close status",
    upstream: "tree-kill shell diagnostic ordering is runtime-dependent",
    args: [
      "--no-color",
      "-k",
      "--kill-signal",
      "SIGTERM",
      "trap 'exit 0' TERM; sleep 1",
      "printf ok",
    ],
    normalizeStatus: normalizeShellTrapStatus,
    normalizeStdout: normalizeShellSignalDiagnosticStdout,
  },
  {
    name: "kill signal sigterm trapped shell cleanup is not interrupted",
    upstream: "tree-kill shell cleanup output is runtime-dependent",
    args: [
      "--no-color",
      "-k",
      "--kill-signal",
      "SIGTERM",
      "trap 'printf \"term\\n\"; sleep 0.05; exit 0' TERM; sleep 1",
      "printf ok",
    ],
    normalizeStatus: normalizeShellTrapStatus,
    normalizeStdout: normalizeShellSignalDiagnosticAndTrapCleanupStdout,
  },
  {
    name: "kill signal sighup trapped shell child preserves close status",
    upstream: "tree-kill shell diagnostic ordering is runtime-dependent",
    args: [
      "--no-color",
      "-k",
      "--kill-signal",
      "SIGHUP",
      "trap 'exit 129' HUP; sleep 1",
      "printf ok",
    ],
    normalizeStatus: normalizeShellTrapStatus,
    normalizeStdout: normalizeShellSignalDiagnosticStdout,
  },
  {
    name: "env kill signal full name reaches sibling",
    upstream: "dist/bin/concurrently.js yargs .env('CONCURRENTLY') full option name",
    args: [
      "--no-color",
      "-k",
      "trap 'exit 130' INT; sleep 1",
      "printf ok",
    ],
    env: { CONCURRENTLY_KILL_SIGNAL: "SIGINT" },
    normalizeStatus: normalizeSignalTrapStatus,
    normalizeStdout: normalizeSignalTrapCloseStatus,
  },
  {
    name: "env kill signal alias reaches sibling",
    upstream: "dist/bin/concurrently.js yargs .env('CONCURRENTLY') alias name",
    args: [
      "--no-color",
      "-k",
      "trap 'exit 138' USR1; while :; do :; done",
      "printf ok",
    ],
    env: { CONCURRENTLY_KS: "SIGUSR1" },
    normalizeStatus: normalizeSignalTrapStatus,
    normalizeStdout: normalizeSignalTrapCloseStatus,
  },
  {
    name: "unsupported kill signal is ignored when unused",
    upstream: "dist/src/flow-control/kill-others.js lazy signal use",
    args: ["--no-color", "-k", "--kill-signal", "SIGFOO", "printf ok"],
  },
  {
    name: "bare term kill signal fails when used",
    upstream: "dist/src/flow-control/kill-others.js configured killSignal",
    args: ["--no-color", "-k", "--kill-signal", "TERM", "sleep 5", delayedOkCommand],
    normalizeStderr: normalizeUnknownSignalStderr,
  },
  {
    name: "lowercase bare term kill signal fails when used",
    upstream: "dist/src/flow-control/kill-others.js configured killSignal",
    args: ["--no-color", "-k", "--kill-signal", "term", "sleep 5", delayedOkCommand],
    normalizeStderr: normalizeUnknownSignalStderr,
  },
  {
    name: "bare hup kill signal fails when used",
    upstream: "dist/src/flow-control/kill-others.js configured killSignal",
    args: ["--no-color", "-k", "--kill-signal", "HUP", "sleep 5", delayedOkCommand],
    normalizeStderr: normalizeUnknownSignalStderr,
  },
  {
    name: "unsupported sig-prefixed kill signal fails when used",
    upstream: "dist/src/flow-control/kill-others.js configured killSignal",
    args: ["--no-color", "-k", "--kill-signal", "SIGFOO", "sleep 5", delayedOkCommand],
    normalizeStderr: normalizeUnknownSignalStderr,
  },
  {
    name: "lowercase sig-prefixed kill signal fails when used",
    upstream: "dist/src/flow-control/kill-others.js configured killSignal",
    args: ["--no-color", "-k", "--kill-signal", "sigusr1", "sleep 5", delayedOkCommand],
    normalizeStderr: normalizeUnknownSignalStderr,
  },
  {
    name: "numeric kill signal fails when used",
    upstream: "dist/src/flow-control/kill-others.js configured killSignal",
    args: ["--no-color", "-k", "--kill-signal", "0", "sleep 5", delayedOkCommand],
    normalizeStderr: normalizeUnknownSignalStderr,
  },
  {
    name: "empty kill signal defaults to sigterm when unused",
    upstream: "dist/bin/concurrently.js yargs string coercion",
    args: ["--no-color", "--kill-signal", "", "printf ok"],
  },
  {
    name: "empty kill signal defaults to sigterm when used",
    upstream: "dist/bin/concurrently.js yargs string coercion",
    args: ["--no-color", "-k", "--kill-signal", "", "sleep 5", "printf ok"],
  },
  {
    name: "kill others skips queued commands after success",
    upstream: "src/concurrently.spec.ts maxProcesses with killOthers",
    args: ["--no-color", "-k", "-m", "1", "printf ok", "printf queued"],
  },
  {
    name: "kill others on fail",
    upstream: "bin/concurrently.spec.ts --kill-others-on-fail",
    args: ["--no-color", "--kill-others-on-fail", "sleep 5", "exit 1"],
    timeoutMs: 60000,
  },
  {
    name: "kill others skips queued commands after failure",
    upstream: "src/concurrently.spec.ts maxProcesses with killOthersOn failure",
    args: [
      "--no-color",
      "--kill-others-on-fail",
      "-m",
      "1",
      "exit 1",
      "printf queued",
    ],
  },
  {
    name: "kill others raw output",
    upstream: "src/logger.spec.ts logGlobalEvent raw mode",
    args: ["--no-color", "--raw", "-k", "printf ok", "sleep 5"],
  },
  {
    name: "kill timeout fractional emits force kill status",
    upstream: "dist/src/flow-control/kill-others.js setTimeout numeric coercion",
    args: [
      "--no-color",
      "--kill-timeout",
      "1.5",
      "-k",
      killTimeoutFixture.trapCommand("fractional"),
      killTimeoutFixture.successCommand("fractional"),
    ],
    normalizeStdout: normalizeShellSignalDiagnosticStdout,
  },
  {
    name: "kill timeout sub-millisecond fractional still force kills",
    upstream: "dist/src/flow-control/kill-others.js setTimeout numeric coercion",
    args: [
      "--no-color",
      "--kill-timeout",
      "0.5",
      "-k",
      killTimeoutFixture.trapCommand("submillisecond"),
      killTimeoutFixture.successCommand("submillisecond"),
    ],
    normalizeStdout: normalizeShellSignalDiagnosticStdout,
  },
  {
    name: "kill timeout negative warning is emitted when used",
    upstream: "dist/src/flow-control/kill-others.js setTimeout negative warning",
    args: [
      "--no-color",
      "--kill-timeout",
      "-1.5",
      "-k",
      killTimeoutFixture.trapCommand("negative"),
      killTimeoutFixture.successCommand("negative"),
    ],
    normalizeStdout: normalizeShellSignalDiagnosticStdout,
    normalizeStderr: normalizeNodeTimerWarningPid,
  },
  {
    name: "kill timeout negative warning is emitted in raw mode",
    upstream: "dist/src/flow-control/kill-others.js Node warning bypasses logger raw mode",
    args: [
      "--no-color",
      "--raw",
      "--kill-timeout",
      "-1",
      "-k",
      killTimeoutFixture.trapCommand("negative-raw"),
      killTimeoutFixture.successCommand("negative-raw"),
    ],
    normalizeStderr: normalizeNodeTimerWarningPid,
  },
  {
    name: "kill timeout invalid is accepted when unused",
    upstream: "dist/bin/concurrently.js killTimeout Number coercion",
    args: ["--no-color", "--kill-timeout", "bogus", "printf one"],
  },
  {
    name: "kill timeout invalid disables force kill when used",
    upstream:
      "dist/src/flow-control/kill-others.js invalid killTimeout disables force kill",
    args: [
      "--no-color",
      "--kill-timeout",
      "bogus",
      "-k",
      killTimeoutFixture.finiteTrapCommand("invalid"),
      killTimeoutFixture.successCommand("invalid"),
    ],
    timeoutMs: 60000,
  },
  {
    name: "max processes serializes command start",
    upstream: "src/concurrently.spec.ts maxProcesses",
    args: ["--no-color", "-g", "-m", "1", "printf one", "printf two"],
  },
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

const windowsCases = [
  {
    name: "version long option",
    upstream: "bin/concurrently.spec.ts --version",
    args: ["--version"],
    normalizeStdout: normalizeVersionStdout,
  },
  {
    name: "help long option",
    upstream: "bin/concurrently.spec.ts --help",
    args: ["--help"],
    normalizeStdout: normalizeHelpStdout,
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
    name: "grouped output is ordered by command index",
    upstream: "bin/concurrently.spec.ts --group",
    args: [
      "--no-color",
      "-g",
      nodeDelayPrintCommand("slow", 80),
      nodePrintCommand("fast"),
    ],
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

const cases = process.platform === "win32" ? windowsCases : posixCases;

(async () => {
  try {
    for (const testCase of cases) {
      const local = await runLocal(testCase);
      const npm = await runNpm(testCase);

      assertEqual(
        normalizeStatus(testCase, local.status),
        normalizeStatus(testCase, npm.status),
        `${testCase.name} exit status`
      );
      assertEqual(
        normalizeSignal(testCase, local.signal),
        normalizeSignal(testCase, npm.signal),
        `${testCase.name} signal`
      );
      assertEqual(
        normalizeStdout(testCase, local.stdout),
        normalizeStdout(testCase, npm.stdout),
        `${testCase.name} stdout`
      );
      assertEqual(
        normalizeStderr(testCase, local.stderr),
        normalizeStderr(testCase, npm.stderr),
        `${testCase.name} stderr`
      );
      console.log(`compat ok: ${testCase.name} (${testCase.upstream})`);
    }
    await runNativeApiSmoke();
    reportLeakedHandlesIfProcessStaysAlive();
  } finally {
    shortcutFixture.cleanup();
    escapedScriptFixture.cleanup();
    literalWildcardFixture.cleanup();
    invalidPackageFixture.cleanup();
    invalidDenoFixture.cleanup();
    killTimeoutFixture.cleanup();
    restartFixture.cleanup();
  }
})().catch((error) => {
  console.error(error);
  process.exit(1);
});

function reportLeakedHandlesIfProcessStaysAlive() {
  const timer = setTimeout(() => {
    const handles =
      typeof process._getActiveHandles === "function"
        ? process._getActiveHandles().map((handle) => handle.constructor?.name ?? typeof handle)
        : ["active handle introspection unavailable"];
    console.error(`compat completed but process stayed alive: ${JSON.stringify(handles)}`);
    process.exit(1);
  }, 1000);
  timer.unref();
}

function runLocal(testCase) {
  return run(localBinary, testCase.args, { ...testCase, side: "local" });
}

async function runNativeApiSmoke() {
  await runNativeApiPerCommandKillSmoke();
  await runNativeApiImmediateKillSmoke();
  await runNativeApiNativeKillPolicyManualKillSmoke();
  await runNativeApiExitedCommandKillSmoke();
  await runNativeApiClosedIpcSendSmoke();
  await runNativeApiControllerIndexLabelSmoke();
  await runNativeApiControllerTemplateIndexAndStringColorSmoke();
  await runNativeApiControllerIpcRejectSmoke();
  await runNativeApiGlobalRawCommandFalseSmoke();
  await runNativeApiCustomSpawnWithTimeout();
  await runNativeApiNumericNameSuccessSelectorSmoke();
  await runNativeApiNumericNameDefaultInputTargetSmoke();
}

let nativeApiCustomSpawnPhase = "not started";

async function runNativeApiCustomSpawnWithTimeout() {
  const timeoutMs = process.platform === "win32" ? 120000 : 30000;
  let timer;
  try {
    await Promise.race([
      runNativeApiCustomSpawnSmoke(),
      new Promise((_, reject) => {
        timer = setTimeout(() => {
          reject(
            new Error(
              `native JS API custom spawn timed out after ${timeoutMs}ms at ${nativeApiCustomSpawnPhase}`
            )
          );
        }, timeoutMs);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

function nativeApiCustomSpawnProgress(phase) {
  nativeApiCustomSpawnPhase = phase;
  console.log(`compat progress: native JS API custom spawn ${phase}`);
}

async function runNativeApiPerCommandKillSmoke() {
  const api = require(resolve("index.js"));
  const sink = new Writable({
    write(_chunk, _encoding, callback) {
      callback();
    },
  });
  const run = api.concurrently([nodeHangCommand(), nodeHangCommand()], {
    outputStream: sink,
    prefixColors: false,
  });

  await waitFor(
    () => run.commands.every((command) => api.Command.canKill(command)),
    10000,
    "native JS API commands did not become killable"
  );
  run.commands.forEach((command, index) => {
    if (!command.process || !Number.isInteger(command.process.pid)) {
      throw new Error(`native JS API command ${index} canKill without process`);
    }
    command.kill("SIGTERM");
    assertEqual(command.killed, true, `native JS API command ${index} kill flag`);
    assertEqual(
      command.killSignal,
      "SIGTERM",
      `native JS API command ${index} kill signal`
    );
  });

  const events = await run.result.then(
    (value) => value,
    (error) => error
  );
  if (!Array.isArray(events)) {
    throw new Error(`native JS API kill returned non-event rejection: ${events}`);
  }
  assertEqual(events.length, 2, "native JS API close event count");
  events.forEach((event, index) => {
    assertEqual(event.killed, true, `native JS API command ${index} killed`);
  });
  console.log("compat ok: native JS API per-command kill");
}

async function runNativeApiImmediateKillSmoke() {
  const api = require(resolve("index.js"));
  const sink = new Writable({
    write(_chunk, _encoding, callback) {
      callback();
    },
  });
  const run = api.concurrently([nodeHangCommand()], {
    outputStream: sink,
    prefixColors: false,
  });
  const command = run.commands[0];

  if (api.Command.canKill(command)) {
    throw new Error("native JS API immediate Command.canKill was true before pid discovery");
  }
  if (command.pid !== undefined) {
    throw new Error(`native JS API immediate kill already had pid: ${command.pid}`);
  }
  command.kill("SIGTERM");

  const events = await run.result.then(
    (value) => value,
    (error) => error
  );
  if (!Array.isArray(events)) {
    throw new Error(`native JS API immediate kill returned non-events: ${events}`);
  }
  assertEqual(events.length, 1, "native JS API immediate kill event count");
  assertEqual(events[0].killed, true, "native JS API immediate kill flag");
  assertEqual(command.killed, true, "native JS API immediate command kill flag");
  console.log("compat ok: native JS API immediate kill before pid discovery");
}

async function runNativeApiNativeKillPolicyManualKillSmoke() {
  if (process.platform === "win32") {
    return;
  }

  const api = require(resolve("index.js"));
  const fixture = mkdtempSync(resolve(tmpdir(), "concurrently-ml-api-kill-policy-"));
  const pidFile = resolve(fixture, "grandchild.pid");
  const sink = new Writable({
    write(_chunk, _encoding, callback) {
      callback();
    },
  });
  const command = nodeEvalCommand(
    "const cp=require('node:child_process');" +
      "const fs=require('node:fs');" +
      `const child=cp.spawn('sleep',['30'],{stdio:'ignore'});` +
      `fs.writeFileSync('${jsSingleQuoted(pidFile)}',String(child.pid));` +
      "setInterval(function(){},1000)"
  );
  const run = api.concurrently([command, nodeHangCommand()], {
    killOthersOn: ["failure"],
    outputStream: sink,
    prefixColors: false,
  });
  const result = run.result.catch((events) => events);

  try {
    await waitFor(
      () => existsSync(pidFile) && api.Command.canKill(run.commands[0]),
      10000,
      "native JS API kill-policy command did not become killable"
    );
    const grandchildPid = Number(readFileSync(pidFile, "utf8"));
    run.commands[0].kill("SIGTERM");
    await waitFor(
      () => !processRunning(grandchildPid),
      10000,
      "native JS API kill-policy manual kill left descendant running"
    );
    run.commands[1].kill("SIGTERM");
    await result;
  } finally {
    rmSync(fixture, { recursive: true, force: true });
  }

  console.log("compat ok: native JS API kill policy manual kill cleans descendants");
}

async function runNativeApiExitedCommandKillSmoke() {
  const api = require(resolve("index.js"));
  const sink = new Writable({
    write(_chunk, _encoding, callback) {
      callback();
    },
  });
  const run = api.concurrently([nodeExitCommand(0), nodeHangCommand()], {
    outputStream: sink,
    prefixColors: false,
  });

  await waitFor(
    () => api.Command.canKill(run.commands[1]),
    10000,
    "native JS API hanging command did not become killable"
  );
  await new Promise((resolvePromise) => setTimeout(resolvePromise, 5000));
  run.commands[0].kill("SIGTERM");
  run.commands[1].kill("SIGTERM");

  const events = await run.result.then(
    (value) => value,
    (error) => error
  );
  if (!Array.isArray(events)) {
    throw new Error(`native JS API exited-command kill returned non-event rejection: ${events}`);
  }
  const first = events.find((event) => event.index === 0);
  const second = events.find((event) => event.index === 1);
  assertEqual(first?.killed, false, "native JS API exited command stays un-killed");
  assertEqual(second?.killed, true, "native JS API hanging command is killed");
  console.log("compat ok: native JS API exited-command kill no-op");
}

async function runNativeApiClosedIpcSendSmoke() {
  const api = require(resolve("index.js"));
  class FakeChild extends EventEmitter {
    constructor() {
      super();
      this.pid = 12345;
      this.stdin = undefined;
      this.stdout = new EventEmitter();
      this.stderr = new EventEmitter();
    }

    send(_message, _handle, _options, callback) {
      callback();
    }
  }

  const child = new FakeChild();
  const command = new api.Command(
    { index: 0, name: "ipc", command: "ipc", ipc: 1 },
    {},
    () => child,
    () => true
  );
  command.start();
  child.emit("close", 0, null);

  await command.send({ closed: true }).then(
    () => {
      throw new Error("native JS API closed IPC send resolved");
    },
    (error) => {
      assertEqual(
        error.message,
        "Command IPC channel is closed",
        "native JS API closed IPC send rejection"
      );
    }
  );
  console.log("compat ok: native JS API closed IPC send rejects");
}

async function runNativeApiControllerIndexLabelSmoke() {
  const api = require(resolve("index.js"));
  let output = "";
  const sink = new Writable({
    write(chunk, _encoding, callback) {
      output += chunk.toString();
      callback();
    },
  });
  const run = api.concurrently([
    nodePrintCommand("removed"),
    { command: nodePrintCommand("kept"), name: "two" },
  ], {
    outputStream: sink,
    prefix: "index",
    prefixColors: false,
    controllers: [
      {
        handle(commands) {
          return { commands: [commands[1]] };
        },
      },
    ],
  });
  const events = await run.result;

  assertEqual(events.length, 1, "native JS API filtered controller event count");
  assertEqual(events[0].index, 1, "native JS API filtered controller event index");
  if (!output.includes("[1] kept")) {
    throw new Error(
      `native JS API filtered controller lost original output label: ${JSON.stringify(output)}`
    );
  }
  if (output.includes("[0] kept")) {
    throw new Error(
      `native JS API filtered controller reused positional output label: ${JSON.stringify(output)}`
    );
  }
  if (output.includes("[two] kept")) {
    throw new Error(
      `native JS API filtered controller used command name for index prefix: ${JSON.stringify(output)}`
    );
  }
  console.log("compat ok: native JS API filtered controller output label");
}

async function runNativeApiControllerTemplateIndexAndStringColorSmoke() {
  const api = require(resolve("index.js"));
  let output = "";
  const sink = new Writable({
    write(chunk, _encoding, callback) {
      output += chunk.toString();
      callback();
    },
  });
  const previousForceColor = process.env.FORCE_COLOR;
  process.env.FORCE_COLOR = "1";
  const run = api.concurrently([
    nodePrintCommand("removed"),
    nodePrintCommand("kept"),
  ], {
    outputStream: sink,
    prefix: "cmd-{index}",
    prefixColors: "red,blue",
    controllers: [
      {
        handle(commands) {
          return { commands: [commands[1]] };
        },
      },
    ],
  });
  if (previousForceColor === undefined) {
    delete process.env.FORCE_COLOR;
  } else {
    process.env.FORCE_COLOR = previousForceColor;
  }
  const events = await run.result;
  const plainOutput = output.replace(/\u001b\[[0-9;]*m/g, "");

  assertEqual(events.length, 1, "native JS API filtered template event count");
  assertEqual(events[0].index, 1, "native JS API filtered template event index");
  if (!plainOutput.includes("cmd-1 kept")) {
    throw new Error(
      `native JS API template prefix lost original index: ${JSON.stringify(output)}`
    );
  }
  if (plainOutput.includes("cmd-0 kept")) {
    throw new Error(
      `native JS API template prefix reused positional index: ${JSON.stringify(output)}`
    );
  }
  if (!output.includes("\u001b[34mcmd-1")) {
    throw new Error(
      `native JS API string prefix colors did not remap to public index: ${JSON.stringify(output)}`
    );
  }
  if (output.includes("\u001b[31mcmd-1")) {
    throw new Error(
      `native JS API string prefix colors used positional color: ${JSON.stringify(output)}`
    );
  }
  console.log("compat ok: native JS API template index and string prefix colors");
}

async function runNativeApiControllerIpcRejectSmoke() {
  const api = require(resolve("index.js"));
  const sink = new Writable({
    write(_chunk, _encoding, callback) {
      callback();
    },
  });
  const ipcCommand = new api.Command({
    index: 0,
    name: "ipc",
    command: nodeExitCommand(0),
    ipc: 3,
  });

  try {
    api.concurrently([nodeExitCommand(0)], {
      raw: true,
      outputStream: sink,
      controllers: [
        {
          handle() {
            return { commands: [ipcCommand] };
          },
        },
      ],
    });
  } catch (error) {
    assertEqual(error.name, "NativeApiUnsupportedError", "native JS API controller IPC error name");
    if (!error.message.includes("command.ipc")) {
      throw new Error(`native JS API controller IPC error message: ${error.message}`);
    }
    console.log("compat ok: native JS API controller IPC is rejected");
    return;
  }

  throw new Error("native JS API controller IPC command was accepted");
}

async function runNativeApiGlobalRawCommandFalseSmoke() {
  const api = require(resolve("index.js"));
  let output = "";
  const sink = new Writable({
    write(chunk, _encoding, callback) {
      output += chunk.toString();
      callback();
    },
  });
  await api
    .concurrently([{ command: nodePrintCommand("raw-only"), raw: false }], {
      raw: true,
      timings: true,
      outputStream: sink,
      prefixColors: false,
    })
    .result;

  if (!output.includes("[0] raw-only")) {
    throw new Error(
      `native JS API global raw command override stayed raw: ${JSON.stringify(output)}`
    );
  }
  console.log("compat ok: native JS API global raw command false formats output");
}

async function runNativeApiCustomSpawnSmoke() {
  const api = require(resolve("index.js"));
  nativeApiCustomSpawnProgress("basic output");
  let output = "";
  const calls = [];
  const sink = new Writable({
    write(chunk, _encoding, callback) {
      output += chunk.toString();
      callback();
    },
  });
  const run = api.concurrently(
    [
      {
        command:
          "node -e \"process.stdout.write(process.env.CONCURRENTLY_ML_SPAWN_SMOKE)\"",
        env: { CONCURRENTLY_ML_SPAWN_SMOKE: "spawn-ok" },
      },
    ],
    {
      outputStream: sink,
      env: { CONCURRENTLY_ML_PRIVATE_ENV: "spawn-secret-do-not-leak" },
      spawn(command, options) {
        calls.push({ command, options });
        return spawn(command, [], options);
      },
    }
  );
  const events = await run.result;

  assertEqual(calls.length, 1, "native JS API custom spawn call count");
  assertEqual(calls[0].options.shell, true, "native JS API custom spawn shell");
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
  if (!output.includes("spawn-ok")) {
    throw new Error(
      `native JS API custom spawn did not route output: ${JSON.stringify(output)}`
    );
  }
  if (!output.includes("[0] spawn-ok")) {
    throw new Error(
      `native JS API custom spawn did not format output: ${JSON.stringify(output)}`
    );
  }

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
    if (previousForceColor === undefined) {
      delete process.env.FORCE_COLOR;
    } else {
      process.env.FORCE_COLOR = previousForceColor;
    }
    if (previousNoColor === undefined) {
      delete process.env.NO_COLOR;
    } else {
      process.env.NO_COLOR = previousNoColor;
    }
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
    if (previousForceColor === undefined) {
      delete process.env.FORCE_COLOR;
    } else {
      process.env.FORCE_COLOR = previousForceColor;
    }
    if (previousNoColor === undefined) {
      delete process.env.NO_COLOR;
    } else {
      process.env.NO_COLOR = previousNoColor;
    }
  }
  if (noColorGlobalOutput.includes("\u001b[")) {
    throw new Error(
      `native JS API custom spawn no-color global output contained ANSI: ${JSON.stringify(noColorGlobalOutput)}`
    );
  }

  nativeApiCustomSpawnProgress("colors");
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
    if (previousForceColor === undefined) {
      delete process.env.FORCE_COLOR;
    } else {
      process.env.FORCE_COLOR = previousForceColor;
    }
    if (previousNoColor === undefined) {
      delete process.env.NO_COLOR;
    } else {
      process.env.NO_COLOR = previousNoColor;
    }
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
    if (previousForceColor === undefined) {
      delete process.env.FORCE_COLOR;
    } else {
      process.env.FORCE_COLOR = previousForceColor;
    }
    if (previousNoColor === undefined) {
      delete process.env.NO_COLOR;
    } else {
      process.env.NO_COLOR = previousNoColor;
    }
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
    if (previousForceColor === undefined) {
      delete process.env.FORCE_COLOR;
    } else {
      process.env.FORCE_COLOR = previousForceColor;
    }
    if (previousNoColor === undefined) {
      delete process.env.NO_COLOR;
    } else {
      process.env.NO_COLOR = previousNoColor;
    }
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
      if (previousForceColor === undefined) {
        delete process.env.FORCE_COLOR;
      } else {
        process.env.FORCE_COLOR = previousForceColor;
      }
      if (previousNoColor === undefined) {
        delete process.env.NO_COLOR;
      } else {
        process.env.NO_COLOR = previousNoColor;
      }
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
      if (previousForceColor === undefined) {
        delete process.env.FORCE_COLOR;
      } else {
        process.env.FORCE_COLOR = previousForceColor;
      }
      if (previousNoColor === undefined) {
        delete process.env.NO_COLOR;
      } else {
        process.env.NO_COLOR = previousNoColor;
      }
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
    if (previousForceColor === undefined) {
      delete process.env.FORCE_COLOR;
    } else {
      process.env.FORCE_COLOR = previousForceColor;
    }
    if (previousNoColor === undefined) {
      delete process.env.NO_COLOR;
    } else {
      process.env.NO_COLOR = previousNoColor;
    }
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

  nativeApiCustomSpawnProgress("restart policy");
  nativeApiCustomSpawnProgress("restart policy marker restart");
  const restartRoot = mkdtempSync(resolve(tmpdir(), "concurrently-ml-spawn-restart-"));
  try {
    const restartMarker = resolve(restartRoot, "marker");
    let restartOutput = "";
    const restartSink = new Writable({
      write(chunk, _encoding, callback) {
        restartOutput += chunk.toString();
        callback();
      },
    });
    let restartCalls = 0;
    const restartRun = api.concurrently(
      [
        "node -e " +
          JSON.stringify(
            "const fs=require('node:fs');const f=process.env.CONCURRENTLY_ML_RESTART_MARKER;if(!fs.existsSync(f)){fs.writeFileSync(f,'1');process.exit(1)}process.exit(0)"
          ),
      ],
      {
        env: { CONCURRENTLY_ML_RESTART_MARKER: restartMarker },
        outputStream: restartSink,
        restartTries: 1,
        spawn(command, options) {
          restartCalls += 1;
          return spawn(command, [], options);
        },
      }
    );
    const restartPublicCloses = [];
    restartRun.commands[0].close.subscribe((event) => {
      restartPublicCloses.push(event.exitCode);
    });
    const restartEvents = await restartRun.result;
    assertEqual(restartCalls, 2, "native JS API custom spawn restart call count");
    assertEqual(
      JSON.stringify(restartPublicCloses),
      JSON.stringify([0]),
      "native JS API custom spawn restart public close stream"
    );
    assertEqual(
      restartEvents[0].exitCode,
      0,
      "native JS API custom spawn restart final exit code"
    );
    if (!restartOutput.includes("restarted")) {
      throw new Error(
        `native JS API custom spawn did not log restart: ${JSON.stringify(restartOutput)}`
      );
    }
  } finally {
    rmSync(restartRoot, { recursive: true, force: true });
  }
  nativeApiCustomSpawnProgress("restart policy exponential delay");
  const exponentialStartedAt = Date.now();
  let exponentialCalls = 0;
  const exponentialEvents = await api.concurrently(
    ["node -e \"process.exit(1)\""],
    {
      outputStream: sink,
      restartTries: 1,
      restartDelay: "exponential",
      spawn(command, options) {
        exponentialCalls += 1;
        return spawn(command, [], options);
      },
    }
  ).result.catch((events) => events);
  assertEqual(
    exponentialCalls,
    2,
    "native JS API custom spawn exponential restart call count"
  );
  assertEqual(
    exponentialEvents[0].exitCode,
    1,
    "native JS API custom spawn exponential restart final exit code"
  );
  if (Date.now() - exponentialStartedAt < 900) {
    throw new Error("native JS API custom spawn exponential restart did not delay");
  }

  nativeApiCustomSpawnProgress("restart policy restart throw");
  let restartThrowPid;
  let restartThrowCalls = 0;
  const restartThrowRun = api.concurrently(
    [
      "node -e \"process.exit(1)\"",
      "node -e \"setInterval(()=>{},1000)\"",
    ],
    {
      maxProcesses: 2,
      outputStream: sink,
      restartTries: 1,
      spawn(command, options) {
        restartThrowCalls += 1;
        if (restartThrowCalls === 3) {
          throw new Error("restart-spawn-boom");
        }
        const child = spawn(command, [], options);
        if (command.includes("setInterval")) {
          restartThrowPid = child.pid;
        }
        return child;
      },
    }
  );
  try {
    const restartThrowError = await restartThrowRun.result.catch((error) => error);
    assertEqual(
      restartThrowError.message,
      "restart-spawn-boom",
      "native JS API custom spawn restart throw error"
    );
    await waitFor(
      () => !processRunning(restartThrowPid),
      5000,
      "native JS API custom spawn restart throw left sibling process running"
    );
  } finally {
    if (processRunning(restartThrowPid)) {
      process.kill(restartThrowPid, "SIGKILL");
    }
  }

  nativeApiCustomSpawnProgress("restart policy startup throw");
  const startupThrowRoot = mkdtempSync(
    resolve(tmpdir(), "concurrently-ml-spawn-startup-throw-")
  );
  let startupThrowPid;
  try {
    const startupThrowReady = resolve(startupThrowRoot, "ready");
    const startupThrowRun = api.concurrently(
      [
        "node -e " +
          JSON.stringify(
            `process.on('SIGTERM',()=>{}); require('node:fs').writeFileSync(${JSON.stringify(
              startupThrowReady
            )}, '1'); setInterval(()=>{},1000)`
          ),
        "throw-on-start",
      ],
      {
        killTimeout: 100,
        maxProcesses: 2,
        outputStream: sink,
        spawn(command, options) {
          if (command === "throw-on-start") {
            throw new Error("startup-spawn-boom");
          }
          const child = spawn(command, [], options);
          startupThrowPid = child.pid;
          const startedAt = Date.now();
          while (!existsSync(startupThrowReady) && Date.now() - startedAt < 1000) {
          }
          return child;
        },
      }
    );
    const startupThrowError = await startupThrowRun.result.catch((error) => error);
    assertEqual(
      startupThrowError.message,
      "startup-spawn-boom",
      "native JS API custom spawn startup throw error"
    );
    await waitFor(
      () => !processRunning(startupThrowPid),
      5000,
      "native JS API custom spawn startup throw cleared killTimeout before SIGKILL"
    );
  } finally {
    if (processRunning(startupThrowPid)) {
      process.kill(startupThrowPid, "SIGKILL");
    }
    rmSync(startupThrowRoot, { recursive: true, force: true });
  }

  nativeApiCustomSpawnProgress("kill policy");
  const killCalls = [];
  const killRun = api.concurrently(
    ["node -e \"setTimeout(()=>{}, 1000)\""],
    {
      outputStream: sink,
      spawn(command, options) {
        return spawn(command, [], options);
      },
      kill(pid, signal) {
        killCalls.push({ pid, signal });
        process.kill(pid, signal);
      },
    }
  );
  setTimeout(() => killRun.commands[0].kill("SIGTERM"), 25);
  await killRun.result.catch((events) => events);
  assertEqual(killCalls.length, 1, "native JS API custom spawn kill call count");
  assertEqual(
    Number.isInteger(killCalls[0].pid),
    true,
    "native JS API custom spawn kill pid"
  );
  assertEqual(killCalls[0].signal, "SIGTERM", "native JS API custom spawn kill signal");

  const killedRestartRun = api.concurrently(
    ["node -e \"setTimeout(()=>{}, 1000)\""],
    {
      outputStream: sink,
      restartTries: 1,
      spawn(command, options) {
        return spawn(command, [], options);
      },
    }
  );
  await waitFor(
    () => api.Command.canKill(killedRestartRun.commands[0]),
    1000,
    "native JS API custom spawn restart kill command did not become killable"
  );
  killedRestartRun.commands[0].kill("SIGTERM");
  const killedRestartEvents = await killedRestartRun.result.catch((events) => events);
  assertEqual(
    killedRestartEvents.length,
    1,
    "native JS API custom spawn killed restart event count"
  );
  assertEqual(
    killedRestartEvents[0].killed,
    true,
    "native JS API custom spawn killed restart event flag"
  );

  let invalidKillSignalPid;
  const invalidKillSignalRun = api.concurrently(
    [
      "node -e \"process.exit(1)\"",
      "node -e \"setInterval(()=>{}, 1000)\"",
    ],
    {
      killOthersOn: ["failure"],
      killSignal: "TERM",
      outputStream: sink,
      spawn(command, options) {
        const child = spawn(command, [], options);
        if (command.includes("setInterval")) {
          invalidKillSignalPid = child.pid;
        }
        return child;
      },
    }
  );
  try {
    const invalidKillSignalResult = await Promise.race([
      invalidKillSignalRun.result.catch((error) => error),
      new Promise((resolveTimeout) => {
        setTimeout(() => resolveTimeout("timeout"), 1000);
      }),
    ]);
    if (invalidKillSignalResult === "timeout") {
      throw new Error("native JS API custom spawn invalid kill signal hung");
    }
    assertEqual(
      invalidKillSignalResult.code,
      "ERR_UNKNOWN_SIGNAL",
      "native JS API custom spawn invalid kill signal error"
    );
  } finally {
    if (processRunning(invalidKillSignalPid)) {
      process.kill(invalidKillSignalPid, "SIGKILL");
    }
  }

  nativeApiCustomSpawnProgress("spawn errors");
  const spawnErrorEvents = await api.concurrently(["ignored"], {
    raw: true,
    outputStream: sink,
    spawn() {
      return spawn("definitely-not-a-real-binary-concurrently-ml", [], {
        stdio: ["pipe", "pipe", "pipe"],
      });
    },
  }).result.catch((events) => events);
  await new Promise((resolveDelay) => setTimeout(resolveDelay, 50));
  assertEqual(
    spawnErrorEvents.length,
    1,
    "native JS API custom spawn error event count"
  );

  let staleCloseCalls = 0;
  let staleCloseOutput = "";
  const staleCloseSink = new Writable({
    write(chunk, _encoding, callback) {
      staleCloseOutput += chunk.toString();
      callback();
    },
  });
  const staleCloseEvents = await api.concurrently(["stale-close"], {
    outputStream: staleCloseSink,
    restartDelay: 0,
    restartTries: 1,
    spawn() {
      staleCloseCalls += 1;
      const child = new EventEmitter();
      child.pid = 80000 + staleCloseCalls;
      child.stdout = new PassThrough();
      child.stderr = new PassThrough();
      child.stdin = new PassThrough();
      child.kill = () => true;
      if (staleCloseCalls === 1) {
        setTimeout(() => child.emit("error", new Error("stale-close-boom")), 0);
        setTimeout(() => child.emit("close", 1, null), 30);
      } else {
        setTimeout(() => {
          child.stdout.write("ok");
          child.emit("close", 0, null);
        }, 80);
      }
      return child;
    },
  }).result;
  assertEqual(
    staleCloseCalls,
    2,
    "native JS API custom spawn stale close restart call count"
  );
  assertEqual(
    staleCloseEvents[0].exitCode,
    0,
    "native JS API custom spawn stale close final exit code"
  );
  if (!staleCloseOutput.includes("ok")) {
    throw new Error(
      `native JS API custom spawn stale close lost replacement output: ${JSON.stringify(staleCloseOutput)}`
    );
  }

  let staleErrorCalls = 0;
  let staleErrorOutput = "";
  const staleErrorSink = new Writable({
    write(chunk, _encoding, callback) {
      staleErrorOutput += chunk.toString();
      callback();
    },
  });
  const staleErrorEvents = await api.concurrently(["stale-error"], {
    outputStream: staleErrorSink,
    restartDelay: 0,
    restartTries: 1,
    spawn() {
      staleErrorCalls += 1;
      const child = new EventEmitter();
      child.pid = 81000 + staleErrorCalls;
      child.stdout = new PassThrough();
      child.stderr = new PassThrough();
      child.stdin = new PassThrough();
      child.kill = () => true;
      if (staleErrorCalls === 1) {
        setTimeout(() => child.emit("close", 1, null), 0);
        setTimeout(() => child.emit("error", new Error("stale-error-boom")), 30);
      } else {
        setTimeout(() => {
          child.stdout.write("ok");
          child.emit("close", 0, null);
        }, 80);
      }
      return child;
    },
  }).result;
  assertEqual(
    staleErrorCalls,
    2,
    "native JS API custom spawn stale error restart call count"
  );
  assertEqual(
    staleErrorEvents[0].exitCode,
    0,
    "native JS API custom spawn stale error final exit code"
  );
  if (!staleErrorOutput.includes("ok")) {
    throw new Error(
      `native JS API custom spawn stale error lost replacement output: ${JSON.stringify(staleErrorOutput)}`
    );
  }

  let throwingSpawnPid;
  let throwingSpawnCalls = 0;
  const throwingSpawnRun = api.concurrently(
    [
      "node -e \"setInterval(()=>{}, 1000)\"",
      "node -e \"process.exit(0)\"",
    ],
    {
      maxProcesses: 2,
      outputStream: sink,
      spawn(command, options) {
        throwingSpawnCalls += 1;
        if (throwingSpawnCalls === 2) {
          throw new Error("spawn-boom");
        }
        const child = spawn(command, [], options);
        throwingSpawnPid = child.pid;
        return child;
      },
    }
  );
  try {
    const spawnError = await throwingSpawnRun.result.catch((error) => error);
    assertEqual(
      spawnError.message,
      "spawn-boom",
      "native JS API custom spawn throw error"
    );
    await waitFor(
      () => !processRunning(throwingSpawnPid),
      5000,
      "native JS API custom spawn throw left previous process running"
    );
  } finally {
    if (processRunning(throwingSpawnPid)) {
      process.kill(throwingSpawnPid, "SIGKILL");
    }
  }

  if (process.platform !== "win32") {
    const killTreeRoot = mkdtempSync(resolve(tmpdir(), "concurrently-ml-spawn-kill-tree-"));
    const killTreePidFile = resolve(killTreeRoot, "grandchild.pid");
    const killTreeCommand = nodeEvalCommand(
      "const cp=require('node:child_process');" +
        "const fs=require('node:fs');" +
        "const child=cp.spawn('sleep',['30'],{stdio:'ignore'});" +
        `fs.writeFileSync('${jsSingleQuoted(killTreePidFile)}',String(child.pid));` +
        "setInterval(function(){},1000)"
    );
    const killTreeRun = api.concurrently(
      [killTreeCommand],
      {
        outputStream: sink,
        spawn(command, options) {
          return spawn(command, [], options);
        },
      }
    );
    try {
      await waitFor(
        () => existsSync(killTreePidFile) && api.Command.canKill(killTreeRun.commands[0]),
        10000,
        "native JS API custom spawn kill-tree command did not become killable"
      );
      const grandchildPid = Number(readFileSync(killTreePidFile, "utf8"));
      killTreeRun.commands[0].kill("SIGTERM");
      await killTreeRun.result.catch((events) => events);
      await waitFor(
        () => !processRunning(grandchildPid),
        10000,
        "native JS API custom spawn default kill left descendant running"
      );
    } finally {
      const grandchildPid = existsSync(killTreePidFile)
        ? Number(readFileSync(killTreePidFile, "utf8"))
        : undefined;
      if (processRunning(grandchildPid)) {
        process.kill(grandchildPid, "SIGKILL");
      }
      rmSync(killTreeRoot, { recursive: true, force: true });
    }

    const killTreeNoPathRoot = mkdtempSync(
      resolve(tmpdir(), "concurrently-ml-spawn-kill-tree-no-path-")
    );
    const killTreeNoPathPidFile = resolve(killTreeNoPathRoot, "grandchild.pid");
    const absoluteNodeCommand =
      JSON.stringify(process.execPath) +
      " -e " +
      JSON.stringify(
        "const cp=require('node:child_process');" +
          "const fs=require('node:fs');" +
          "const child=cp.spawn('/bin/sleep',['30'],{stdio:'ignore'});" +
          `fs.writeFileSync('${jsSingleQuoted(killTreeNoPathPidFile)}',String(child.pid));` +
          "setInterval(function(){},1000)"
      );
    const killTreeNoPathRun = api.concurrently([absoluteNodeCommand], {
      outputStream: sink,
      spawn(command, options) {
        return spawn(command, [], options);
      },
    });
    const originalPath = process.env.PATH;
    try {
      await waitFor(
        () =>
          existsSync(killTreeNoPathPidFile) &&
          api.Command.canKill(killTreeNoPathRun.commands[0]),
        10000,
        "native JS API custom spawn kill-tree no-PATH command did not become killable"
      );
      const grandchildPid = Number(readFileSync(killTreeNoPathPidFile, "utf8"));
      process.env.PATH = "";
      killTreeNoPathRun.commands[0].kill("SIGTERM");
      process.env.PATH = originalPath;
      await killTreeNoPathRun.result.catch((events) => events);
      await waitFor(
        () => !processRunning(grandchildPid),
        10000,
        "native JS API custom spawn default kill depended on pgrep PATH lookup"
      );
    } finally {
      process.env.PATH = originalPath;
      const grandchildPid = existsSync(killTreeNoPathPidFile)
        ? Number(readFileSync(killTreeNoPathPidFile, "utf8"))
        : undefined;
      if (processRunning(grandchildPid)) {
        process.kill(grandchildPid, "SIGKILL");
      }
      rmSync(killTreeNoPathRoot, { recursive: true, force: true });
    }
  }

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
  const plainMissingInputTargetOutput = missingInputTargetOutput.replace(
    /\u001b\[[0-9;]*m/g,
    ""
  );
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

  const numericSuccessEvents = await api.concurrently(
    [
      { name: "1", command: "node -e \"process.exit(0)\"" },
      "node -e \"process.exit(7)\"",
    ],
    {
      outputStream: sink,
      successCondition: "command-1",
      spawn(command, options) {
        return spawn(command, [], options);
      },
    }
  ).result.then(
    () => {
      throw new Error("native JS API custom spawn numeric success selector resolved");
    },
    (events) => events
  );
  assertEqual(
    numericSuccessEvents.length,
    2,
    "native JS API custom spawn numeric success event count"
  );

  let fractionalRestartRuns = 0;
  const fractionalRestartEvents = await api.concurrently(
    ["node -e \"process.exit(1)\""],
    {
      outputStream: sink,
      restartTries: 1.5,
      spawn(command, options) {
        fractionalRestartRuns += 1;
        return spawn(command, [], options);
      },
    }
  ).result;
  assertEqual(
    fractionalRestartRuns,
    2,
    "native JS API custom spawn fractional restart run count"
  );
  assertEqual(
    fractionalRestartEvents.length,
    0,
    "native JS API custom spawn fractional restart event count"
  );

  nativeApiCustomSpawnProgress("input edge cases");
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

  const percentCalls = [];
  const percentRun = api.concurrently(
    [
      "node -e \"setTimeout(()=>process.exit(0), 150)\"",
      "node -e \"setTimeout(()=>process.exit(0), 150)\"",
    ],
    {
      maxProcesses: "1%",
      outputStream: sink,
      spawn(command, options) {
        percentCalls.push(command);
        return spawn(command, [], options);
      },
    }
  );
  await new Promise((resolveDelay) => setTimeout(resolveDelay, 50));
  assertEqual(
    percentCalls.length,
    1,
    "native JS API custom spawn percent maxProcesses initial call count"
  );
  await percentRun.result;

  const queuedCalls = [];
  const queuedRun = api.concurrently(
    [
      "node -e \"setTimeout(()=>process.exit(1), 10)\"",
      "node -e \"setTimeout(()=>{}, 1000)\"",
      "node -e \"process.stdout.write('should-not-start')\"",
    ],
    {
      maxProcesses: 2,
      killOthersOn: ["failure"],
      outputStream: sink,
      spawn(command, options) {
        queuedCalls.push(command);
        return spawn(command, [], options);
      },
    }
  );
  const queuedEvents = await queuedRun.result.catch((events) => events);
  assertEqual(queuedCalls.length, 2, "native JS API custom spawn queued call count");
  assertEqual(queuedEvents.length, 2, "native JS API custom spawn queued event count");

  const killOthersRestartRoot = mkdtempSync(
    resolve(tmpdir(), "concurrently-ml-spawn-kill-others-restart-")
  );
  try {
    const killOthersRestartMarker = resolve(killOthersRestartRoot, "marker");
    let killOthersRestartOutput = "";
    const killOthersRestartSink = new Writable({
      write(chunk, _encoding, callback) {
        killOthersRestartOutput += chunk.toString();
        callback();
      },
    });
    let killOthersRestartCalls = 0;
    const killOthersRestartRun = api.concurrently(
      [
        "node -e " +
          JSON.stringify(
            "const fs=require('node:fs');const f=process.env.CONCURRENTLY_ML_KILL_OTHERS_RESTART_MARKER;if(!fs.existsSync(f)){fs.writeFileSync(f,'1');setTimeout(()=>process.exit(1),5)}else{process.exit(0)}"
          ),
        "node -e \"setTimeout(()=>process.exit(0),20)\"",
      ],
      {
        env: { CONCURRENTLY_ML_KILL_OTHERS_RESTART_MARKER: killOthersRestartMarker },
        killOthersOn: ["success"],
        maxProcesses: 2,
        outputStream: killOthersRestartSink,
        restartDelay: 100,
        restartTries: 1,
        spawn(command, options) {
          if (command.includes("KILL_OTHERS_RESTART")) {
            killOthersRestartCalls += 1;
          }
          return spawn(command, [], options);
        },
      }
    );
    const killOthersRestartEvents = await killOthersRestartRun.result;
    assertEqual(
      killOthersRestartCalls,
      2,
      "native JS API custom spawn kill-others pending restart call count"
    );
    assertEqual(
      killOthersRestartEvents.length,
      2,
      "native JS API custom spawn kill-others pending restart event count"
    );
    if (killOthersRestartEvents.some((event) => event.exitCode !== 0)) {
      throw new Error(
        `native JS API custom spawn skipped pending restart after kill-others: ${JSON.stringify(killOthersRestartEvents)}`
      );
    }
    const plainKillOthersRestartOutput = killOthersRestartOutput.replace(
      /\u001b\[[0-9;]*m/g,
      ""
    );
    if (!plainKillOthersRestartOutput.includes("--> Sending SIGTERM to other processes..")) {
      throw new Error(
        `native JS API custom spawn did not log kill-others cancellation: ${JSON.stringify(killOthersRestartOutput)}`
      );
    }
  } finally {
    rmSync(killOthersRestartRoot, { recursive: true, force: true });
  }

  nativeApiCustomSpawnProgress("kill timeout");
  const killTimeoutRun = api.concurrently(
    [
      "node -e \"process.on('SIGTERM',()=>{});setInterval(()=>{},1000)\"",
      "node -e \"setTimeout(()=>process.exit(1),20)\"",
    ],
    {
      killOthersOn: ["failure"],
      killTimeout: 25,
      maxProcesses: 2,
      outputStream: sink,
      spawn(command, options) {
        return spawn(command, [], options);
      },
    }
  );
  const killTimeoutEvents = await killTimeoutRun.result.catch((events) => events);
  if (!killTimeoutEvents.some((event) => event.exitCode === "SIGKILL")) {
    throw new Error(
      `native JS API custom spawn did not force kill after timeout: ${JSON.stringify(killTimeoutEvents)}`
    );
  }

  const killTimeoutBackstopCode = `
    const { Writable } = require("node:stream");
    const { spawn } = require("node:child_process");
    const api = require(${JSON.stringify(resolve("index.js"))});
    const sink = new Writable({ write(_chunk, _encoding, callback) { callback(); } });
    api.concurrently([
      ${JSON.stringify("node -e \"setInterval(()=>{},1000)\"")},
      ${JSON.stringify("node -e \"setTimeout(()=>process.exit(1),20)\"")},
    ], {
      killOthersOn: ["failure"],
      killTimeout: 2000,
      maxProcesses: 2,
      outputStream: sink,
      spawn(command, options) {
        return spawn(command, [], options);
      },
    }).result.catch(() => {}).then(() => process.stdout.write("done"));
  `;
  const killTimeoutBackstopRun = spawnSync(
    process.execPath,
    ["-e", killTimeoutBackstopCode],
    { cwd: resolve("."), encoding: "utf8", timeout: 1200 }
  );
  assertEqual(
    killTimeoutBackstopRun.status,
    0,
    `native JS API custom spawn killTimeout timer kept process alive: ${killTimeoutBackstopRun.stderr || killTimeoutBackstopRun.error}`
  );

  const signalKillTimeoutCode = `
    const { Writable } = require("node:stream");
    const { spawn } = require("node:child_process");
    const api = require(${JSON.stringify(resolve("index.js"))});
    const sink = new Writable({ write(_chunk, _encoding, callback) { callback(); } });
    api.concurrently([${JSON.stringify("node -e \"process.on('SIGTERM',()=>{});setInterval(()=>{},1000)\"")}], {
      killTimeout: 100,
      outputStream: sink,
      spawn(command, options) {
        return spawn(command, [], options);
      },
    }).result.catch(() => {}).then(() => process.stdout.write("done"));
    const sendSelfSigterm = () => {
      if (process.platform === "win32") {
        process.emit("SIGTERM", "SIGTERM");
        return;
      }
      process.kill(process.pid, "SIGTERM");
    };
    setTimeout(sendSelfSigterm, 100);
  `;
  const signalKillTimeout = spawnSync(
    process.execPath,
    ["-e", signalKillTimeoutCode],
    { cwd: resolve("."), encoding: "utf8", timeout: 1200 }
  );
  assertEqual(
    signalKillTimeout.status,
    0,
    `native JS API custom spawn signal killTimeout hung: ${signalKillTimeout.stderr || signalKillTimeout.error}`
  );
  assertEqual(
    signalKillTimeout.stdout,
    "done",
    "native JS API custom spawn signal killTimeout completion"
  );

  nativeApiCustomSpawnProgress("signal restart");
  const signalRestartRoot = mkdtempSync(
    resolve(tmpdir(), "concurrently-ml-spawn-signal-restart-")
  );
  try {
    const signalRestartMarker = resolve(signalRestartRoot, "marker");
    const signalRestartCode = `
      const { Writable } = require("node:stream");
      const { spawn } = require("node:child_process");
      const api = require(${JSON.stringify(resolve("index.js"))});
      const marker = ${JSON.stringify(signalRestartMarker)};
      const command = "node -e " + ${JSON.stringify(
        JSON.stringify(
          "const fs=require('node:fs');const f=process.env.CONCURRENTLY_ML_SIGNAL_RESTART_MARKER;if(!fs.existsSync(f)){fs.writeFileSync(f,'1');process.once('SIGTERM',()=>process.exit(1));setInterval(()=>{},1000)}else{process.exit(0)}"
        )
      )};
      const sink = new Writable({ write(_chunk, _encoding, callback) { callback(); } });
      let calls = 0;
      api.concurrently([command], {
        env: { CONCURRENTLY_ML_SIGNAL_RESTART_MARKER: marker },
        outputStream: sink,
        restartDelay: 0,
        restartTries: 1,
        spawn(commandText, options) {
          calls += 1;
          return spawn(commandText, [], options);
        },
      }).result.then(
        () => process.stdout.write("done:" + calls),
        (error) => {
          process.stderr.write(JSON.stringify(error));
          process.exit(1);
        }
      );
      const sendSelfSigterm = () => {
        if (process.platform === "win32") {
          process.emit("SIGTERM", "SIGTERM");
          return;
        }
        process.kill(process.pid, "SIGTERM");
      };
      setTimeout(sendSelfSigterm, 100);
    `;
    const signalRestart = spawnSync(process.execPath, ["-e", signalRestartCode], {
      cwd: resolve("."),
      encoding: "utf8",
      timeout: 5000,
    });
    assertEqual(
      signalRestart.status,
      0,
      `native JS API custom spawn non-SIGINT restart failed: ${signalRestart.stderr || signalRestart.error}`
    );
    assertEqual(
      signalRestart.stdout,
      "done:2",
      "native JS API custom spawn non-SIGINT restart call count"
    );
  } finally {
    rmSync(signalRestartRoot, { recursive: true, force: true });
  }

  const signalKillTimeoutRoot = mkdtempSync(
    resolve(tmpdir(), "concurrently-ml-spawn-signal-kill-timeout-")
  );
  try {
    const signalKillTimeoutMarker = resolve(signalKillTimeoutRoot, "marker");
    const signalKillTimeoutCommand =
      "node -e " +
      JSON.stringify(
        `const fs=require('node:fs'); const marker=${JSON.stringify(
          signalKillTimeoutMarker
        )}; if(!fs.existsSync(marker)){fs.writeFileSync(marker,'1'); process.once('SIGTERM',()=>process.exit(1)); setInterval(()=>{},1000)} else {process.stdout.write('restarted'); setTimeout(()=>process.exit(0),300)}`
      );
    const signalKillTimeoutCode = `
      const api = require(${JSON.stringify(resolve("index.js"))});
      const { spawn } = require("node:child_process");
      const { Writable } = require("node:stream");
      const sink = new Writable({ write(_chunk, _encoding, callback) { callback(); } });
      let calls = 0;
      api.concurrently([${JSON.stringify(signalKillTimeoutCommand)}], {
        killTimeout: 100,
        outputStream: sink,
        restartDelay: 0,
        restartTries: 1,
        spawn(command, options) {
          calls += 1;
          return spawn(command, [], options);
        },
      }).result.then(
        () => process.stdout.write("done:" + calls),
        (error) => {
          process.stderr.write(JSON.stringify(error));
          process.exit(1);
        }
      );
      const signalWhenReady = () => {
        if (require("node:fs").existsSync(${JSON.stringify(signalKillTimeoutMarker)})) {
          if (process.platform === "win32") {
            process.emit("SIGTERM", "SIGTERM");
          } else {
            process.kill(process.pid, "SIGTERM");
          }
          return;
        }
        setTimeout(signalWhenReady, 25);
      };
      signalWhenReady();
    `;
    const signalKillTimeout = spawnSync(
      process.execPath,
      ["-e", signalKillTimeoutCode],
      { cwd: resolve("."), encoding: "utf8", timeout: 2500 }
    );
    assertEqual(
      signalKillTimeout.status,
      0,
      `native JS API custom spawn signal killTimeout restart failed: ${signalKillTimeout.stderr || signalKillTimeout.error}`
    );
    assertEqual(
      signalKillTimeout.stdout,
      "done:2",
      "native JS API custom spawn signal killTimeout restart call count"
    );
  } finally {
    rmSync(signalKillTimeoutRoot, { recursive: true, force: true });
  }

  const signalChildRoot = mkdtempSync(
    resolve(tmpdir(), "concurrently-ml-spawn-signal-")
  );
  try {
    const signalChildPidFile = resolve(signalChildRoot, "child.pid");
    const signalChildCommand =
      "node -e " +
      JSON.stringify(
        `require('node:fs').writeFileSync(${JSON.stringify(
          signalChildPidFile
        )}, String(process.pid)); setInterval(()=>{},1000)`
      );
    const signalChildCode = `
      const api = require(${JSON.stringify(resolve("index.js"))});
      const { spawn } = require("node:child_process");
      const { existsSync, readFileSync } = require("node:fs");
      const { Writable } = require("node:stream");
      const pidFile = ${JSON.stringify(signalChildPidFile)};
      const sink = new Writable({ write(_chunk, _encoding, callback) { callback(); } });
      const run = api.concurrently([${JSON.stringify(signalChildCommand)}], {
        outputStream: sink,
        spawn(command, options) {
          return spawn(command, [], options);
        },
      });
      run.result.catch(() => {});
      const isRunning = (pid) => {
        try {
          process.kill(pid, 0);
          return true;
        } catch (_error) {
          return false;
        }
      };
      const signalWhenReady = () => {
        if (existsSync(pidFile)) {
          if (process.platform === "win32") {
            process.emit("SIGTERM", "SIGTERM");
          } else {
            process.kill(process.pid, "SIGTERM");
          }
          return;
        }
        setTimeout(signalWhenReady, 25);
      };
      signalWhenReady();
      setTimeout(() => {
        if (!existsSync(pidFile)) {
          process.exit(2);
        }
        const childPid = Number(readFileSync(pidFile, "utf8"));
        const childRunning = isRunning(childPid);
        if (childRunning) {
          try {
            process.kill(childPid, "SIGKILL");
          } catch (_error) {
          }
        }
        process.exit(childRunning ? 1 : 0);
      }, 1200);
    `;
    const signalChild = spawnSync(process.execPath, ["-e", signalChildCode], {
      cwd: resolve("."),
      encoding: "utf8",
      timeout: 2500,
    });
    assertEqual(
      signalChild.status,
      0,
      `native JS API custom spawn signal cleanup failed: ${signalChild.stderr || signalChild.stdout || signalChild.error}`
    );
  } finally {
    rmSync(signalChildRoot, { recursive: true, force: true });
  }

  const signalPendingRestartCode = `
    const { Writable } = require("node:stream");
    const { spawn } = require("node:child_process");
    const api = require(${JSON.stringify(resolve("index.js"))});
    const sink = new Writable({ write(_chunk, _encoding, callback) { callback(); } });
    api.concurrently([${JSON.stringify("node -e \"process.exit(1)\"")}], {
      outputStream: sink,
      restartDelay: 5000,
      restartTries: 1,
      spawn(command, options) {
        return spawn(command, [], options);
      },
    }).result.catch(() => {}).then(() => process.stdout.write("done"));
    const sendSelfSigterm = () => {
      if (process.platform === "win32") {
        process.emit("SIGTERM", "SIGTERM");
        return;
      }
      process.kill(process.pid, "SIGTERM");
    };
    setTimeout(sendSelfSigterm, 100);
  `;
  const signalPendingRestart = spawnSync(
    process.execPath,
    ["-e", signalPendingRestartCode],
    { cwd: resolve("."), encoding: "utf8", timeout: 1200 }
  );
  assertEqual(
    signalPendingRestart.status,
    0,
    `native JS API custom spawn signal left pending restart timer: ${signalPendingRestart.stderr || signalPendingRestart.error}`
  );
  assertEqual(
    signalPendingRestart.stdout,
    "done",
    "native JS API custom spawn signal pending restart completion"
  );

  const restartTimerBackstopCode = `
    const { Writable } = require("node:stream");
    const { spawn } = require("node:child_process");
    const api = require(${JSON.stringify(resolve("index.js"))});
    const sink = new Writable({ write(_chunk, _encoding, callback) { callback(); } });
    let calls = 0;
    api.concurrently([
      ${JSON.stringify("node -e \"process.exit(1)\"")},
      ${JSON.stringify("node -e \"setTimeout(()=>process.exit(0),50)\"")},
      "throw-on-start",
    ], {
      maxProcesses: 2,
      outputStream: sink,
      restartDelay: 2000,
      restartTries: 1,
      spawn(command, options) {
        calls += 1;
        if (command === "throw-on-start") {
          throw new Error("queued-spawn-boom");
        }
        return spawn(command, [], options);
      },
    }).result.catch(() => process.stdout.write("done"));
  `;
  const restartTimerBackstopRun = spawnSync(
    process.execPath,
    ["-e", restartTimerBackstopCode],
    { cwd: resolve("."), encoding: "utf8", timeout: 1200 }
  );
  assertEqual(
    restartTimerBackstopRun.status,
    0,
    `native JS API custom spawn restart timer kept process alive: ${restartTimerBackstopRun.stderr || restartTimerBackstopRun.error}`
  );
  assertEqual(
    restartTimerBackstopRun.stdout,
    "done",
    "native JS API custom spawn restart timer completion"
  );

  nativeApiCustomSpawnProgress("hidden commands");
  let hiddenOutput = "";
  const hiddenSink = new Writable({
    write(chunk, _encoding, callback) {
      hiddenOutput += chunk.toString();
      callback();
    },
  });
  await api.concurrently(
    [{ command: "node -e \"process.stdout.write('hidden-secret')\"", hidden: true }],
    {
      outputStream: hiddenSink,
      spawn(command, options) {
        return spawn(command, [], options);
      },
    }
  ).result;
  assertEqual(hiddenOutput, "", "native JS API custom spawn hidden output");

  const hiddenRawChildCode = `
    const { spawn } = require("node:child_process");
    const api = require(${JSON.stringify(resolve("index.js"))});
    api.concurrently(
      [{ command: ${JSON.stringify("node -e \"process.stdout.write('hidden-raw-secret')\"")}, hidden: true }],
      {
        raw: true,
        spawn(command, options) {
          return spawn(command, [], options);
        },
      }
    ).result.then(() => {});
  `;
  const hiddenRawChild = spawnSync(process.execPath, ["-e", hiddenRawChildCode], {
    cwd: resolve("."),
    encoding: "utf8",
  });
  assertEqual(
    hiddenRawChild.status,
    0,
    `native JS API custom spawn hidden raw child exited with ${hiddenRawChild.status}: ${hiddenRawChild.stderr}`
  );
  assertEqual(
    hiddenRawChild.stdout,
    "",
    "native JS API custom spawn hidden raw stdout"
  );
  console.log("compat ok: native JS API custom spawn");
}

async function runNativeApiNumericNameSuccessSelectorSmoke() {
  const api = require(resolve("index.js"));
  const sink = new Writable({
    write(_chunk, _encoding, callback) {
      callback();
    },
  });
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

function waitFor(predicate, timeoutMs, label) {
  const startMs = Date.now();
  return new Promise((resolvePromise, rejectPromise) => {
    const poll = () => {
      if (predicate()) {
        resolvePromise();
        return;
      }
      if (Date.now() - startMs >= timeoutMs) {
        rejectPromise(new Error(label));
        return;
      }
      setTimeout(poll, 20);
    };
    poll();
  });
}

function processRunning(pid) {
  if (!Number.isInteger(pid)) {
    return false;
  }
  const result = spawnSync("ps", ["-p", String(pid), "-o", "stat="], {
    encoding: "utf8",
  });
  if (result.status !== 0) {
    return false;
  }
  return !result.stdout.trim().startsWith("Z");
}

function runNpm(testCase) {
  return run(npmConcurrentlyCommand, testCase.args, { ...testCase, side: "npm" });
}

function resolveNpmConcurrentlyCommand() {
  const local = resolveLocalPinnedConcurrentlyBinary();
  if (local) {
    return commandForConcurrentlyBinary(local);
  }

  const result = spawnFileSync(npmCommand(), [
    "exec",
    "--yes",
    "--package",
    `concurrently@${npmConcurrentlyVersion}`,
    "--",
    commandLocator(),
    "concurrently",
  ], {
    cwd: resolve("."),
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });

  if (result.error) {
    throw result.error;
  }
  if (result.status !== 0) {
    throw new Error(
      `failed to resolve concurrently@${npmConcurrentlyVersion}\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`
    );
  }

  const binary = commandLocatorResult(result.stdout);
  if (!binary) {
    throw new Error(`${commandLocator()} concurrently returned no binary path`);
  }
  return commandForConcurrentlyBinary(binary);
}

function resolveLocalPinnedConcurrentlyBinary() {
  const configured = process.env.CONCURRENTLY_BIN;
  if (configured) {
    const configuredBinary = resolveVoltaShim(configured);
    assertPinnedConcurrentlyVersion(configuredBinary);
    return configuredBinary;
  }

  const which = spawnFileSync(commandLocator(), ["concurrently"], {
    cwd: resolve("."),
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  });
  const binary = resolveVoltaShim(commandLocatorResult(which.stdout));
  if (!binary) {
    return null;
  }

  return assertPinnedConcurrentlyVersion(binary) ? binary : null;
}

function npmCommand() {
  return process.platform === "win32" ? "npm.cmd" : "npm";
}

function commandLocator() {
  return process.platform === "win32" ? "where" : "which";
}

function commandLocatorResult(stdout) {
  const binaries = stdout.trim().split(/\r?\n/).filter(Boolean);
  if (process.platform !== "win32") {
    return binaries.pop() ?? "";
  }
  return (
    binaries.find((binary) => binary.toLowerCase().endsWith(".cmd")) ??
    binaries.pop() ??
    ""
  );
}

function spawnFileSync(command, args, options) {
  return spawnSync(command, args, {
    ...options,
    shell: windowsCommandScript(command),
  });
}

function spawnFile(command, args, options) {
  return spawn(command, args, {
    ...options,
    shell: windowsCommandScript(command),
  });
}

function windowsCommandScript(command) {
  return process.platform === "win32" && command.toLowerCase().endsWith(".cmd");
}

function resolveVoltaShim(binary) {
  if (!binary || !binary.includes(`${sep}.volta${sep}bin${sep}`)) {
    return binary;
  }

  const result = spawnFileSync("volta", ["which", "concurrently"], {
    cwd: resolve("."),
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  });
  if (result.status !== 0) {
    return binary;
  }

  return result.stdout.trim().split(/\r?\n/).pop() || binary;
}

function assertPinnedConcurrentlyVersion(binary) {
  const version = spawnFileSync(binary, ["--version"], {
    cwd: resolve("."),
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  });
  if (version.status !== 0) {
    return false;
  }

  const actual = version.stdout.trim();
  if (actual !== npmConcurrentlyVersion) {
    if (process.env.CONCURRENTLY_BIN) {
      throw new Error(
        `CONCURRENTLY_BIN must point to concurrently@${npmConcurrentlyVersion}, got ${actual}`
      );
    }
    return false;
  }
  return true;
}

function commandForConcurrentlyBinary(binary) {
  if (process.platform === "win32" && binary.toLowerCase().endsWith(".cmd")) {
    const jsBinary = resolve(
      dirname(binary),
      "..",
      "concurrently",
      "dist",
      "bin",
      "concurrently.js"
    );
    if (existsSync(jsBinary)) {
      return { command: process.execPath, args: [jsBinary] };
    }
  }

  return { command: binary, args: [] };
}

function run(commandInput, args, testCase) {
  if (testCase.prepare) {
    testCase.prepare();
  }

  const commandSpec =
    typeof commandInput === "string"
      ? { command: commandInput, args: [] }
      : commandInput;
  const command = commandSpec.command;
  const commandArgs = [...commandSpec.args, ...args];

  if (
    testCase.inputDelayMs !== undefined ||
    testCase.inputWrites !== undefined ||
    testCase.parentSignal !== undefined
  ) {
    return runAsync(command, commandArgs, testCase);
  }

  const result = spawnFileSync(command, commandArgs, {
    cwd: testCase.cwd ?? resolve("."),
    encoding: "utf8",
    env: environmentFor(testCase),
    input: testCase.input ?? "",
    stdio: ["pipe", "pipe", "pipe"],
    timeout: testCase.timeoutMs ?? 60000,
  });

  if (result.error) {
    throw new Error(`${testCase.name} (${testCase.side}): ${result.error.message}`);
  }

  return {
    status: result.status,
    signal: result.signal,
    stdout: result.stdout,
    stderr: result.stderr,
  };
}

function runAsync(command, args, testCase) {
  return new Promise((resolvePromise, rejectPromise) => {
    const child = spawnFile(command, args, {
      cwd: testCase.cwd ?? resolve("."),
      env: environmentFor(testCase),
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    let settled = false;
    let inputTimers = [];
    let signalTimer;
    const timeout = setTimeout(() => {
      if (settled) {
        return;
      }
      settled = true;
      if (signalTimer) {
        clearTimeout(signalTimer);
      }
      child.kill("SIGKILL");
      rejectPromise(new Error(`${testCase.name} (${testCase.side}): timed out`));
    }, testCase.timeoutMs ?? 60000);
    const clearSignalTimer = () => {
      if (signalTimer) {
        clearTimeout(signalTimer);
      }
    };
    const maybeSendParentSignal = () => {
      const parentSignal = testCase.parentSignal;
      if (!parentSignal || signalTimer) {
        return;
      }
      if (!stdout.includes(parentSignal.afterStdout)) {
        return;
      }
      signalTimer = setTimeout(() => {
        child.kill(parentSignal.signal);
      }, parentSignal.delayMs);
    };

    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
      maybeSendParentSignal();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.stdin.on("error", (error) => {
      if (error.code === "EPIPE") {
        // Delayed test input can race with a child that already closed stdin.
        // The process close event still carries the behavior under comparison.
        return;
      }
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timeout);
      clearSignalTimer();
      inputTimers.forEach(clearTimeout);
      rejectPromise(new Error(`${testCase.name}: stdin ${error.message}`));
    });
    child.on("error", (error) => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timeout);
      clearSignalTimer();
      inputTimers.forEach(clearTimeout);
      rejectPromise(new Error(`${testCase.name}: ${error.message}`));
    });
    child.on("close", (status, signal) => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timeout);
      clearSignalTimer();
      inputTimers.forEach(clearTimeout);
      resolvePromise({ status, signal, stdout, stderr });
    });

    if (
      testCase.inputDelayMs !== undefined ||
      testCase.inputWrites !== undefined
    ) {
      const inputWrites =
        testCase.inputWrites ?? [ { delayMs: testCase.inputDelayMs, input: testCase.input ?? "" } ];
      inputWrites.forEach((write, index) => {
        const writeInput = () => {
          child.stdin.write(write.input);
          if (index === inputWrites.length - 1) {
            child.stdin.end();
          }
        };
        if (write.afterStdout !== undefined) {
          const poll = () => {
            if (stdout.includes(write.afterStdout)) {
              writeInput();
              return;
            }
            inputTimers.push(setTimeout(poll, 20));
          };
          poll();
        } else {
          inputTimers.push(setTimeout(writeInput, write.delayMs));
        }
      });
    } else {
      child.stdin.end();
    }
  });
}

function createShortcutFixture() {
  const cwd = mkdtempSync(resolve(tmpdir(), "concurrently-ocaml-compat-"));
  const bin = resolve(cwd, "bin");
  mkdirSync(bin);
  writeFileSync(
    resolve(cwd, "package.json"),
    JSON.stringify(
      {
        scripts: {
          print: "printf shortcut",
          "client build": "printf spaced",
          "build-css": "printf css",
          "build-js": "printf js",
        },
      },
      null,
      2
    )
  );
  writeFileSync(
    resolve(cwd, "deno.json"),
    JSON.stringify(
      {
        tasks: {
          "task-api": "printf api",
          "task-ui": "printf ui",
        },
      },
      null,
      2
    )
  );
  for (const runner of ["yarn", "pnpm", "bun", "deno"]) {
    const executable = resolve(bin, runner);
    writeFileSync(
      executable,
      `#!/bin/sh\nprintf '${runner}:%s:%s' "$1" "$2"\n`
    );
    chmodSync(executable, 0o700);
  }
  return {
    cwd,
    fakeRunnerEnv: {
      PATH: `${bin}${delimiter}${process.env.PATH ?? ""}`,
    },
    cleanup() {
      rmSync(cwd, { force: true, recursive: true });
    },
  };
}

function createEscapedScriptFixture() {
  const cwd = mkdtempSync(resolve(tmpdir(), "concurrently-ocaml-escaped-"));
  writeFileSync(
    resolve(cwd, "package.json"),
    String.raw`{"scripts":{"build-\u0061":"printf a","build-b":"printf b"}}`
  );
  return {
    cwd,
    cleanup() {
      rmSync(cwd, { force: true, recursive: true });
    },
  };
}

function createLiteralWildcardFixture() {
  const cwd = mkdtempSync(resolve(tmpdir(), "concurrently-ocaml-literal-wildcard-"));
  writeFileSync(
    resolve(cwd, "package.json"),
    JSON.stringify(
      {
        scripts: {
          "build.js": "printf js",
          buildxjs: "printf x",
        },
      },
      null,
      2
    )
  );
  return {
    cwd,
    cleanup() {
      rmSync(cwd, { force: true, recursive: true });
    },
  };
}

function createInvalidPackageFixture() {
  const cwd = mkdtempSync(resolve(tmpdir(), "concurrently-ocaml-invalid-json-"));
  writeFileSync(
    resolve(cwd, "package.json"),
    `{"scripts":{"build-a":"printf a",}}`
  );
  return {
    cwd,
    cleanup() {
      rmSync(cwd, { force: true, recursive: true });
    },
  };
}

function createInvalidDenoFixture() {
  const root = mkdtempSync(resolve(tmpdir(), "concurrently-ocaml-deno-jsonc-"));
  const bin = resolve(root, "bin");
  const validCwd = resolve(root, "valid");
  const carriageReturnCwd = resolve(root, "carriage-return");
  const invalidCwd = resolve(root, "invalid");
  const unterminatedCommentCwd = resolve(root, "unterminated-comment");
  const duplicateCwd = resolve(root, "duplicate");
  const objectKeyOrderCwd = resolve(root, "object-key-order");
  const arrayTasksCwd = resolve(root, "array-tasks");
  const stringTasksCwd = resolve(root, "string-tasks");
  const stringPackageScriptsCwd = resolve(root, "string-package-scripts");
  mkdirSync(bin);
  mkdirSync(validCwd);
  mkdirSync(carriageReturnCwd);
  mkdirSync(invalidCwd);
  mkdirSync(unterminatedCommentCwd);
  mkdirSync(duplicateCwd);
  mkdirSync(objectKeyOrderCwd);
  mkdirSync(arrayTasksCwd);
  mkdirSync(stringTasksCwd);
  mkdirSync(stringPackageScriptsCwd);
  const deno = resolve(bin, "deno");
  writeFileSync(deno, `#!/bin/sh\nprintf 'deno:%s:%s' "$1" "$2"\n`);
  chmodSync(deno, 0o700);
  writeFileSync(
    resolve(validCwd, "deno.jsonc"),
    `{// comment\n"tasks":{"task-a":"printf a",},}\n`
  );
  writeFileSync(
    resolve(carriageReturnCwd, "deno.jsonc"),
    `{// comment\r"tasks":{"task-a":"printf a"}}`
  );
  writeFileSync(
    resolve(invalidCwd, "deno.json"),
    `{"tasks":{"task-a":"printf a"}`
  );
  writeFileSync(
    resolve(unterminatedCommentCwd, "deno.jsonc"),
    `{"tasks":{"task-a":"printf a"}}/*`
  );
  writeFileSync(
    resolve(duplicateCwd, "deno.json"),
    `{"tasks":{"task-old":"printf old"},"tasks":{"task-new":"printf new"}}`
  );
  writeFileSync(
    resolve(objectKeyOrderCwd, "deno.json"),
    `{"tasks":{"b":"printf b","2":"printf two","1":"printf one","a":"printf a","2":"printf overwrite","01":"printf leading"}}`
  );
  writeFileSync(
    resolve(arrayTasksCwd, "deno.json"),
    `{"tasks":["printf zero","printf one"]}`
  );
  writeFileSync(
    resolve(stringTasksCwd, "deno.json"),
    `{"tasks":"ab"}`
  );
  writeFileSync(
    resolve(stringPackageScriptsCwd, "package.json"),
    `{"scripts":"ab"}`
  );
  return {
    validCwd,
    carriageReturnCwd,
    invalidCwd,
    unterminatedCommentCwd,
    duplicateCwd,
    objectKeyOrderCwd,
    arrayTasksCwd,
    stringTasksCwd,
    stringPackageScriptsCwd,
    fakeRunnerEnv: {
      PATH: `${bin}${delimiter}${process.env.PATH ?? ""}`,
    },
    cleanup() {
      rmSync(root, { force: true, recursive: true });
    },
  };
}

function createKillTimeoutFixture() {
  const root = mkdtempSync(resolve(tmpdir(), "concurrently-ocaml-kill-timeout-"));
  return {
    trapCommand(name) {
      const marker = shellQuote(resolve(root, `${name}.ready`));
      return `sh -c "trap '' TERM; while :; do : > ${marker}; sleep 0.01; done"`;
    },
    finiteTrapCommand(name) {
      const marker = shellQuote(resolve(root, `${name}.ready`));
      return `sh -c "trap '' TERM; i=0; while [ \\$i -lt 100 ]; do : > ${marker}; i=\\$((i + 1)); sleep 0.01; done"`;
    },
    successCommand(name) {
      const marker = shellQuote(resolve(root, `${name}.ready`));
      return `sh -c "rm -f ${marker}; while [ ! -f ${marker} ]; do sleep 0.01; done; printf ok"`;
    },
    cleanup() {
      rmSync(root, { force: true, recursive: true });
    },
  };
}

function createRestartFixture() {
  const cwd = mkdtempSync(resolve(tmpdir(), "concurrently-ocaml-restart-"));
  const marker = resolve(cwd, "attempt.state");
  const command =
    "node -e 'const fs=require(\"fs\");const p=process.env.CONCURRENTLY_RESTART_MARKER;if(fs.existsSync(p)){process.stdout.write(\"ok\");process.exit(0)}fs.writeFileSync(p,\"1\");process.exit(1)'";
  const signalCommand =
    "node -e 'const fs=require(\"fs\");const p=process.env.CONCURRENTLY_RESTART_MARKER;if(fs.existsSync(p)){process.stdout.write(\"ok\");process.exit(0)}fs.writeFileSync(p,\"1\");process.stdout.write(\"ready\\n\");setTimeout(()=>process.exit(1),5000)'";
  return {
    cwd,
    marker,
    command,
    signalCommand,
    reset() {
      rmSync(marker, { force: true });
    },
    cleanup() {
      rmSync(cwd, { force: true, recursive: true });
    },
  };
}

function shellQuote(value) {
  return `'${value.replaceAll("'", "'\\''")}'`;
}

function nodePrintCommand(text) {
  return nodeEvalCommand(`process.stdout.write('${jsSingleQuoted(text)}')`);
}

function nodeStderrCommand(text) {
  return nodeEvalCommand(`process.stderr.write('${jsSingleQuoted(text)}')`);
}

function nodeDelayPrintCommand(text, delayMs) {
  return nodeEvalCommand(
    `setTimeout(function(){` +
      `process.stdout.write('${jsSingleQuoted(text)}')` +
      `},${delayMs})`
  );
}

function nodeExitCommand(exitCode) {
  return nodeEvalCommand(`process.exit(${exitCode})`);
}

function nodeHangCommand() {
  return nodeEvalCommand("setInterval(function(){},1000)");
}

function nodeEvalCommand(source) {
  return `node -e "${source.replaceAll('"', '\\"')}"`;
}

function jsSingleQuoted(value) {
  return value.replaceAll("\\", "\\\\").replaceAll("'", "\\'");
}

function environmentFor(testCase) {
  const env = { ...process.env, NO_COLOR: "1" };
  if (testCase.env) {
    for (const [key, value] of Object.entries(testCase.env)) {
      if (value === null) {
        delete env[key];
      } else {
        env[key] = value;
      }
    }
  }
  if (testCase.bypassVoltaNodeShim) {
    // Volta parses package.json in cwd before Node starts; this fixture needs
    // upstream concurrently to observe the invalid manifest itself.
    env.PATH = `${dirname(process.execPath)}${delimiter}${env.PATH ?? ""}`;
  }
  return env;
}

function assertEqual(actual, expected, label) {
  if (actual !== expected) {
    throw new Error(
      `${label}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`
    );
  }
}

function normalizeStdout(testCase, stdout) {
  return testCase.normalizeStdout ? testCase.normalizeStdout(stdout) : stdout;
}

function normalizeStderr(testCase, stderr) {
  return testCase.normalizeStderr ? testCase.normalizeStderr(stderr) : stderr;
}

function normalizeStatus(testCase, status) {
  return testCase.normalizeStatus ? testCase.normalizeStatus(status) : status;
}

function normalizeSignal(testCase, signal) {
  return testCase.normalizeSignal ? testCase.normalizeSignal(signal) : signal;
}

function normalizeVersionStdout(stdout) {
  return stdout.replace(/^\d+\.\d+\.\d+\r?\n$/, "<version>\n");
}

function normalizeHelpStdout(stdout) {
  return stdout
    .replace(/\r\n/g, "\n")
    .replace(/^concurrently(?:\.js)? /, "concurrently.js ");
}

function normalizeNpmLogPaths(stdout) {
  return stdout.replace(
    /A complete log of this run can be found in: .+?debug-\d+\.log/g,
    "A complete log of this run can be found in: <npm-log>"
  );
}

function normalizeTimingsStdout(stdout) {
  const timestampPattern = /\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}/g;
  return stdout
    .replace(timestampPattern, "<timestamp>")
    .replace(/started at \d{3}/g, "started at <timestamp>")
    .replace(/stopped at \d{3}/g, "stopped at <timestamp>")
    .replace(/after [\d,]+ms/g, "after <duration>ms")
    .split("\n")
    .map(normalizeTimingsTableRow)
    .join("\n");
}

function normalizeSignalKilledTimingsStdout(stdout) {
  return normalizeKilledSleepStatus(normalizeTimingsStdout(stdout));
}

function normalizeSignalKilledDurationSortedTimingsStdout(stdout) {
  return normalizeKilledSleepStatus(
    sortNormalizedTimingsTableRows(normalizeTimingsStdout(stdout))
  );
}

function normalizeKilledSleepStatus(stdout) {
  return stdout
    .replace(
      /^\[(\d+)\] sleep 1 exited with code (?:0|SIGTERM)$/gm,
      "[$1] sleep 1 exited with code <killed>"
    )
    .replace(
      /^--> │  │ <duration> │ (?:0|SIGTERM) │ true │ sleep 1 │$/gm,
      "--> │  │ <duration> │ <killed> │ true │ sleep 1 │"
    );
}

function normalizeDurationSortedTimingsStdout(stdout) {
  return sortNormalizedTimingsTableRows(normalizeTimingsStdout(stdout));
}

function normalizeFractionalMaxProcessesStdout(stdout) {
  const expectedLines = [
    "[0] one",
    "[0] sh -c 'sleep 0.3; printf one' exited with code 0",
    "[1] two",
    "[1] sh -c 'sleep 0.1; printf two' exited with code 0",
    "[2] three",
    "[2] printf three exited with code 0",
  ];
  const lines = stdout.trimEnd().split("\n");
  if (
    lines.length === expectedLines.length &&
    expectedLines.every((line) => lines.includes(line))
  ) {
    return `${expectedLines.join("\n")}\n`;
  }
  return stdout;
}

function normalizeLineOrderStdout(stdout) {
  const lines = stdout.trimEnd().split("\n");
  return `${lines.sort().join("\n")}\n`;
}

function normalizePartialInputTargetStdout(stdout) {
  const command =
    "[0] node -e \"process.stdout.write('partial'); setTimeout(()=>process.exit(0),2500)\" exited with code 0";
  const lines = stdout.trimEnd().split("\n");
  if (
    lines.includes("[0] partial") &&
    lines.includes('--> Unable to find command "missing", or it has no stdin open') &&
    lines.includes("--> ") &&
    lines.includes(command)
  ) {
    return [
      "[0] partial",
      '--> Unable to find command "missing", or it has no stdin open',
      "--> ",
      command,
      "",
    ].join("\n");
  }
  return stdout;
}

function sortNormalizedTimingsTableRows(stdout) {
  const lines = stdout.split("\n");
  const rowIndexes = [];
  for (let index = 0; index < lines.length; index += 1) {
    if (normalizedTimingsDataRow(lines[index])) {
      rowIndexes.push(index);
    }
  }

  const sortedRows = rowIndexes
    .map((index) => lines[index])
    .sort((left, right) => left.localeCompare(right));
  for (let index = 0; index < rowIndexes.length; index += 1) {
    lines[rowIndexes[index]] = sortedRows[index];
  }
  return lines.join("\n");
}

function normalizedTimingsDataRow(line) {
  if (!line.startsWith("--> │")) {
    return false;
  }

  const cells = line
    .slice("--> ".length)
    .split("│")
    .slice(1, -1)
    .map((cell) => cell.trim());
  return cells.length === 5 && cells[1] === "<duration>";
}

function normalizePidStdout(stdout) {
  return stdout
    .replace(/^\[\d+\]/gm, "[<pid>]")
    .replace(/^\d+:/gm, "<pid>:");
}

function normalizeNodeTimerWarningPid(stderr) {
  return stderr.replace(/^\(node:\d+\)/gm, "(node:<pid>)");
}

function normalizeNodeTimerWarningAndShellDiagnosticStderr(stderr) {
  return normalizeNodeTimerWarningPid(stderr).replace(
    /^sh: line \d+:\s+\d+ Killed: 9\s+sleep 0\.01\n/gm,
    ""
  );
}

function normalizeInvalidWildcardOmissionStderr(stderr) {
  if (stderr.includes("Invalid regular expression: /[/")) {
    return "<invalid wildcard omission>\n";
  }
  if (stderr.includes("invalid wildcard omission regular expression: [")) {
    return "<invalid wildcard omission>\n";
  }
  return stderr;
}

function normalizeUnknownSignalStderr(stderr) {
  if (stderr.includes("ERR_UNKNOWN_SIGNAL")) {
    return "<unknown signal>\n";
  }
  return stderr;
}

function normalizeSignalTrapCloseStatus(stdout) {
  return stdout
    .replace(
      /^\[0\] (trap 'exit 130' INT; sleep 1) exited with code (?:0|130|SIGINT)$/gm,
      "[0] $1 exited with code <SIGINT>"
    )
    .replace(
      /^\[0\] (trap 'exit 138' USR1; while :; do :; done) exited with code (?:0|138|SIGUSR1)$/gm,
      "[0] $1 exited with code <SIGUSR1>"
    );
}

function normalizeSignalTrapStatus(status) {
  return status === 0 || status === 1 ? "<signal-trap-status>" : status;
}

function normalizeShellSignalDiagnosticStdout(stdout) {
  return stdout
    .replace(/^\[\d+\] (?:Hangup|Terminated|User defined signal 1): \d+\n/gm, "")
    .replace(/^\[\d+\] sh: line \d+:\s+\d+ Killed: \d+\s+sleep 0\.01\n/gm, "")
    .replace(
      /^\[0\] (trap 'exit 0' TERM; sleep 1) exited with code (?:0|143|SIGTERM)$/gm,
      "[0] $1 exited with code <SIGTERM>"
    )
    .replace(
      /^\[0\] (trap 'printf "term\\n"; sleep 0\.05; exit 0' TERM; sleep 1) exited with code (?:0|143|SIGTERM)$/gm,
      "[0] $1 exited with code <SIGTERM>"
    )
    .replace(
      /^\[0\] (trap 'exit 129' HUP; sleep 1) exited with code (?:0|129|SIGHUP)$/gm,
      "[0] $1 exited with code <SIGHUP>"
    );
}

function normalizeShellTrapStatus(status) {
  return status === 0 || status === 1 ? "<shell-trap-status>" : status;
}

function normalizeShellSignalDiagnosticAndTrapCleanupStdout(stdout) {
  return normalizeShellSignalDiagnosticStdout(stdout).replace(
    /^\[\d+\] term\n/gm,
    ""
  );
}

function normalizeTimingsTableRow(line) {
  if (!line.startsWith("--> │")) {
    return line;
  }

  const cells = line
    .slice("--> ".length)
    .split("│")
    .slice(1, -1)
    .map((cell) => cell.trim());
  if (cells.length !== 5 || !/^\d[\d,]*$/.test(cells[1])) {
    return line;
  }

  cells[1] = "<duration>";
  return `--> │ ${cells.join(" │ ")} │`;
}
