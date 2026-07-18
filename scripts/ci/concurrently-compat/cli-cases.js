const { createExpansionCases } = require("./cli-cases-expansion");
const { createLifecycleCases } = require("./cli-cases-lifecycle");
const {
  createSchedulingInputCases,
} = require("./cli-cases-scheduling-input");
const { createWindowsCases } = require("./cli-cases-windows");
const {
  normalizeEmptyCommandAssertionStderr,
  normalizeHelpStdout,
  normalizePidStdout,
  normalizeSignalKilledDurationSortedTimingsStdout,
  normalizeSignalKilledTimingsStdout,
  normalizeTimingsStdout,
  normalizeVersionStdout,
} = require("./cli-normalizers");

function createCliCases({ commands, fixtures, oneSlotPercentage }) {
  const { nodeDelayPrintCommand, nodeExitCommand, nodePrintCommand } = commands;
  const forceColorBaseEnv = {
    CI: null,
    GITHUB_ACTIONS: null,
    COLORTERM: null,
    NO_COLOR: null,
  };
  const forceNoColorEnv = { ...forceColorBaseEnv, TERM: "dumb", FORCE_COLOR: "0" };
  const forceFalseColorEnv = { ...forceColorBaseEnv, TERM: "dumb", FORCE_COLOR: "false" };
  const forceBasicColorEnv = { ...forceColorBaseEnv, TERM: "dumb", FORCE_COLOR: "1" };
  const forceAnsi256ColorEnv = { ...forceColorBaseEnv, TERM: "xterm-256color", FORCE_COLOR: "2" };
  const forceAnsi256SuffixColorEnv = { ...forceColorBaseEnv, TERM: "xterm-256color", FORCE_COLOR: "2foo" };
  const forceTruecolorEnv = {
    ...forceColorBaseEnv,
    COLORTERM: "truecolor",
    TERM: "xterm-256color",
    FORCE_COLOR: "3",
  };
  const forceGithubActionsColorEnv = { ...forceTruecolorEnv, CI: "true", GITHUB_ACTIONS: "true" };
  const forceGithubActionsDumbColorEnv = { ...forceTruecolorEnv, TERM: "dumb", CI: "true", GITHUB_ACTIONS: "true" };
  const forceSpacedZeroColorEnv = { ...forceColorBaseEnv, TERM: "dumb", FORCE_COLOR: " 0" };
  const forceNanColorEnv = { ...forceColorBaseEnv, TERM: "dumb", FORCE_COLOR: "NaN" };
  const forceGithubActionsNanColorEnv = { ...forceNanColorEnv, TERM: "xterm-256color", CI: "true", GITHUB_ACTIONS: "true" };
  const forceGithubActionsNegativeColorEnv = { ...forceNanColorEnv, TERM: "xterm-256color", FORCE_COLOR: "-1", CI: "true", GITHUB_ACTIONS: "true" };
  const inputReadyDelayMs = 2500;
  const sharedPrefixColorsRepeatCase = {
    name: "prefix colors repeat the last explicit color",
    upstream: "concurrently --help --prefix-colors last color repetition",
    args: [
      "-g",
      "-m",
      "1",
      "-c",
      "red,blue",
      nodePrintCommand("one"),
      nodePrintCommand("two"),
      nodePrintCommand("three"),
    ],
    env: forceBasicColorEnv,
  };
  const sharedPercentageMaxProcessesCase = {
    name: "percentage max processes deterministically serializes",
    upstream: "concurrently --help percentage max-processes",
    args: [
      "--no-color",
      "--max-processes",
      oneSlotPercentage,
      nodeDelayPrintCommand("slow", 100),
      nodePrintCommand("fast"),
    ],
  };
  const sharedRepeatedTeardownCase = {
    name: "repeated teardown flags preserve order",
    upstream: "concurrently --help --teardown repeatable array",
    args: [
      "--no-color",
      "--teardown",
      nodePrintCommand("first"),
      "--teardown",
      nodePrintCommand("second"),
      nodePrintCommand("main"),
    ],
  };
  const sharedFailingTeardownCase = {
    name: "failing teardown does not change main success",
    upstream: "concurrently --help --teardown exit status contract",
    args: ["--no-color", "--teardown", nodeExitCommand(7), nodePrintCommand("main")],
  };

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
      normalizeStdout: normalizeHelpStdout,
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
      name: "custom posix shell runs command",
      upstream: "bin/concurrently.spec.ts --shell",
      args: ["--no-color", "--shell", "/bin/bash", "printf \"$0\""],
    },
    {
      name: "no commands prints help",
      upstream: "bin/concurrently.ts default command handling",
      args: ["--no-color"],
      normalizeStderr: normalizeHelpStdout,
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
      name: "empty double quoted command strips then rejects",
      upstream: "dist/src/command-parser/strip-quotes.js strips quoted content before command assertion",
      args: ["--no-color", "\"\""],
      normalizeStderr: normalizeEmptyCommandAssertionStderr,
    },
    {
      name: "empty single quoted command strips then rejects",
      upstream: "dist/src/command-parser/strip-quotes.js strips quoted content before command assertion",
      args: ["--no-color", "''"],
      normalizeStderr: normalizeEmptyCommandAssertionStderr,
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
      name: "colored default auto prefix",
      upstream: "dist/src/defaults.js prefixColors auto",
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
    sharedPrefixColorsRepeatCase,
    {
      name: "colored hex prefix github actions color level",
      upstream: "supports-color GitHub Actions color level",
      args: ["-c", "#336699", "printf one"],
      env: forceGithubActionsColorEnv,
    },
    {
      name: "colored hex prefix github actions dumb terminal color level",
      upstream: "supports-color TERM=dumb before GitHub Actions CI level",
      args: ["-c", "#336699", "printf one"],
      env: forceGithubActionsDumbColorEnv,
    },
    {
      name: "colored hex prefix github actions invalid force color",
      upstream: "supports-color invalid FORCE_COLOR before GitHub Actions CI level",
      args: ["-c", "#336699", "printf one"],
      env: forceGithubActionsNanColorEnv,
    },
    {
      name: "colored hex prefix github actions negative force color",
      upstream: "supports-color negative FORCE_COLOR before GitHub Actions CI level",
      args: ["-c", "#336699", "printf one"],
      env: forceGithubActionsNegativeColorEnv,
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
      name: "colored rgb function-style prefix",
      upstream: "dist/src/logger.js getChalkPath rgb function call",
      args: ["-c", "rgb(1,2,3)", "printf one"],
      env: forceTruecolorEnv,
    },
    {
      name: "colored ansi256 function-style prefix",
      upstream: "dist/src/logger.js getChalkPath ansi256 function call",
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
    ...createExpansionCases({ fixtures }),
    ...createLifecycleCases({
      commands,
      fixtures,
      sharedFailingTeardownCase,
      sharedRepeatedTeardownCase,
    }),
    ...createSchedulingInputCases({
      commands,
      fixtures,
      inputReadyDelayMs,
      sharedPercentageMaxProcessesCase,
    }),
  ];

  const windowsCases = createWindowsCases({
    commands,
    inputReadyDelayMs,
    sharedFailingTeardownCase,
    sharedPercentageMaxProcessesCase,
    sharedPrefixColorsRepeatCase,
    sharedRepeatedTeardownCase,
  });

  return process.platform === "win32" ? windowsCases : posixCases;
}

module.exports = { createCliCases };
