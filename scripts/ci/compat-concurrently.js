#!/usr/bin/env node

const {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} = require("node:fs");
const { tmpdir } = require("node:os");
const { delimiter, resolve, sep } = require("node:path");
const { spawn, spawnSync } = require("node:child_process");

const npmConcurrentlyVersion = "9.2.1";
const localBinary = resolve("_build", "default", "bin", "main.exe");
const npmConcurrentlyBinary = resolveNpmConcurrentlyBinary();
const inputEchoCommand =
  "node -e \"process.stdin.once('data',d=>{process.stdout.write(d);process.exit(0)})\"";
const firstInputEchoCommand =
  "node -e \"process.stdin.once('data',d=>{process.stdout.write('first:'+d);process.exit(0)})\"";
const secondInputEchoCommand =
  "node -e \"process.stdin.once('data',d=>{process.stdout.write('second:'+d);process.exit(0)})\"";
const forceBasicColorEnv = { NO_COLOR: null, FORCE_COLOR: "1" };
const forceTruecolorEnv = { NO_COLOR: null, FORCE_COLOR: "3" };
const shortcutFixture = createShortcutFixture();
const restartFixture = createRestartFixture();

if (!existsSync(localBinary)) {
  throw new Error(`missing local binary: ${localBinary}; run npm run compile first`);
}

const cases = [
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
    name: "failed command close notification",
    upstream: "src/flow-control/log-exit.spec.ts",
    args: ["--no-color", "sh -c 'exit 3'"],
  },
  {
    name: "formatted stderr is emitted on stdout",
    upstream: "src/logger.spec.ts output stream routing",
    args: ["--no-color", "definitely-not-a-command-xyz"],
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
    normalizeStdout: normalizeTimingsStdout,
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
    name: "passthrough disabled treats arguments as commands",
    upstream: "bin/concurrently.spec.ts --passthrough-arguments disabled",
    args: ["--no-color", "-g", "printf '{1}'", "--", "printf arg"],
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
    normalizeStderr: normalizeNodeTimerWarningPid,
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
    args: ["--no-color", "-k", "printf ok", "sleep 1"],
  },
  {
    name: "combined short kill and group flags",
    upstream: "yargs short-option-groups for boolean aliases",
    args: ["--no-color", "-kg", "printf ok", "sleep 1"],
  },
  {
    name: "env kill others default success projection",
    upstream: "docs/cli/configuration.md CONCURRENTLY_KILL_OTHERS",
    args: ["--no-color", "printf ok", "sleep 1"],
    env: { CONCURRENTLY_KILL_OTHERS: "true" },
  },
  {
    name: "kill others success first projection",
    upstream: "bin/concurrently.spec.ts exiting conditions --success first",
    args: ["--no-color", "-k", "-s", "first", "printf ok", "sleep 1"],
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
    normalizeStdout: normalizeSignalTrapCloseStatus,
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
    normalizeStdout: normalizeSignalTrapCloseStatus,
  },
  {
    name: "unsupported kill signal is ignored when unused",
    upstream: "dist/src/flow-control/kill-others.js lazy signal use",
    args: ["--no-color", "-k", "--kill-signal", "SIGFOO", "printf ok"],
  },
  {
    name: "empty kill signal defaults to sigterm when unused",
    upstream: "dist/bin/concurrently.js yargs string coercion",
    args: ["--no-color", "--kill-signal", "", "printf ok"],
  },
  {
    name: "empty kill signal defaults to sigterm when used",
    upstream: "dist/bin/concurrently.js yargs string coercion",
    args: ["--no-color", "-k", "--kill-signal", "", "sleep 1", "printf ok"],
  },
  {
    name: "kill others skips queued commands after success",
    upstream: "src/concurrently.spec.ts maxProcesses with killOthers",
    args: ["--no-color", "-k", "-m", "1", "printf ok", "printf queued"],
  },
  {
    name: "kill others on fail",
    upstream: "bin/concurrently.spec.ts --kill-others-on-fail",
    args: ["--no-color", "--kill-others-on-fail", "sleep 1", "exit 1"],
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
    args: ["--no-color", "--raw", "-k", "printf ok", "sleep 1"],
  },
  {
    name: "kill timeout fractional emits force kill status",
    upstream: "dist/src/flow-control/kill-others.js setTimeout numeric coercion",
    args: [
      "--no-color",
      "--kill-timeout",
      "1.5",
      "-k",
      "trap '' TERM; sleep 1",
      "printf ok",
    ],
  },
  {
    name: "kill timeout sub-millisecond fractional still force kills",
    upstream: "dist/src/flow-control/kill-others.js setTimeout numeric coercion",
    args: [
      "--no-color",
      "--kill-timeout",
      "0.5",
      "-k",
      "trap '' TERM; sleep 1",
      "printf ok",
    ],
  },
  {
    name: "kill timeout negative warning is emitted when used",
    upstream: "dist/src/flow-control/kill-others.js setTimeout negative warning",
    args: [
      "--no-color",
      "--kill-timeout",
      "-1.5",
      "-k",
      "trap '' TERM; sleep 1",
      "printf ok",
    ],
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
      "trap '' TERM; sleep 1",
      "printf ok",
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
      "trap '' TERM; sleep 1",
      "printf ok",
    ],
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
    inputDelayMs: 250,
  },
  {
    name: "handle input routes by command index",
    upstream: "bin/concurrently.spec.ts --handle-input specified process",
    args: ["--no-color", "-g", "-i", firstInputEchoCommand, secondInputEchoCommand],
    inputWrites: [
      { delayMs: 250, input: "1:two\n" },
      { delayMs: 300, input: "0:one\n" },
    ],
  },
  {
    name: "handle input routes by command name",
    upstream: "bin/concurrently.spec.ts --handle-input specified process",
    args: [
      "--no-color",
      "-g",
      "-i",
      "-n",
      "api,worker",
      firstInputEchoCommand,
      secondInputEchoCommand,
    ],
    inputWrites: [
      { delayMs: 250, input: "worker:two\n" },
      { delayMs: 300, input: "api:one\n" },
    ],
  },
  {
    name: "default input target routes unprefixed input",
    upstream: "bin/concurrently.spec.ts --default-input-target",
    args: [
      "--no-color",
      "-g",
      "-i",
      "--default-input-target",
      "1",
      firstInputEchoCommand,
      secondInputEchoCommand,
    ],
    inputWrites: [
      { delayMs: 250, input: "two\n" },
      { delayMs: 300, input: "0:one\n" },
    ],
  },
  {
    name: "empty default input target routes to first command",
    upstream: "dist/bin/concurrently.js defaultInputTarget Number coercion",
    args: ["--no-color", "-i", "--default-input-target", "", inputEchoCommand],
    input: "hello\n",
    inputDelayMs: 250,
  },
  {
    name: "env handle input and default target route input",
    upstream: "dist/bin/concurrently.js yargs .env('CONCURRENTLY') input defaults",
    args: ["--no-color", "-g", firstInputEchoCommand, secondInputEchoCommand],
    env: {
      CONCURRENTLY_HANDLE_INPUT: "true",
      CONCURRENTLY_DEFAULT_INPUT_TARGET: "1",
    },
    inputWrites: [
      { delayMs: 250, input: "two\n" },
      { delayMs: 300, input: "0:one\n" },
    ],
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
      "printf one",
    ],
    input: "hello\n",
    inputDelayMs: 250,
  },
];

(async () => {
  try {
    for (const testCase of cases) {
      const local = await runLocal(testCase);
      const npm = await runNpm(testCase);

      assertEqual(local.status, npm.status, `${testCase.name} exit status`);
      assertEqual(local.signal, npm.signal, `${testCase.name} signal`);
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
  } finally {
    shortcutFixture.cleanup();
    restartFixture.cleanup();
  }
})().catch((error) => {
  console.error(error);
  process.exit(1);
});

function runLocal(testCase) {
  return run(localBinary, testCase.args, testCase);
}

function runNpm(testCase) {
  return run(npmConcurrentlyBinary, testCase.args, testCase);
}

function resolveNpmConcurrentlyBinary() {
  const local = resolveLocalPinnedConcurrentlyBinary();
  if (local) {
    return local;
  }

  const result = spawnSync("npm", [
    "exec",
    "--yes",
    "--package",
    `concurrently@${npmConcurrentlyVersion}`,
    "--",
    "which",
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

  const binary = result.stdout.trim().split(/\r?\n/).pop();
  if (!binary) {
    throw new Error(`which concurrently returned no binary path`);
  }
  return binary;
}

function resolveLocalPinnedConcurrentlyBinary() {
  const configured = process.env.CONCURRENTLY_BIN;
  if (configured) {
    assertPinnedConcurrentlyVersion(configured);
    return configured;
  }

  const which = spawnSync("which", ["concurrently"], {
    cwd: resolve("."),
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  });
  const binary = resolveVoltaShim(which.stdout.trim().split(/\r?\n/).pop());
  if (!binary) {
    return null;
  }

  return assertPinnedConcurrentlyVersion(binary) ? binary : null;
}

function resolveVoltaShim(binary) {
  if (!binary || !binary.includes(`${sep}.volta${sep}bin${sep}`)) {
    return binary;
  }

  const result = spawnSync("volta", ["which", "concurrently"], {
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
  const version = spawnSync(binary, ["--version"], {
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

function run(command, args, testCase) {
  if (testCase.prepare) {
    testCase.prepare();
  }

  if (testCase.inputDelayMs !== undefined || testCase.inputWrites !== undefined) {
    return runAsync(command, args, testCase);
  }

  const result = spawnSync(command, args, {
    cwd: testCase.cwd ?? resolve("."),
    encoding: "utf8",
    env: environmentFor(testCase),
    input: testCase.input ?? "",
    stdio: ["pipe", "pipe", "pipe"],
    timeout: testCase.timeoutMs ?? 5000,
  });

  if (result.error) {
    throw new Error(`${testCase.name}: ${result.error.message}`);
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
    const child = spawn(command, args, {
      cwd: testCase.cwd ?? resolve("."),
      env: environmentFor(testCase),
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    let settled = false;
    let inputTimers = [];
    const timeout = setTimeout(() => {
      if (settled) {
        return;
      }
      settled = true;
      child.kill("SIGKILL");
      rejectPromise(new Error(`${testCase.name}: timed out`));
    }, testCase.timeoutMs ?? 5000);

    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", (error) => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timeout);
      inputTimers.forEach(clearTimeout);
      rejectPromise(new Error(`${testCase.name}: ${error.message}`));
    });
    child.on("close", (status, signal) => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timeout);
      inputTimers.forEach(clearTimeout);
      resolvePromise({ status, signal, stdout, stderr });
    });

    const inputWrites =
      testCase.inputWrites ?? [ { delayMs: testCase.inputDelayMs, input: testCase.input ?? "" } ];
    inputWrites.forEach((write, index) => {
      inputTimers.push(setTimeout(() => {
        child.stdin.write(write.input);
        if (index === inputWrites.length - 1) {
          child.stdin.end();
        }
      }, write.delayMs));
    });
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

function createRestartFixture() {
  const cwd = mkdtempSync(resolve(tmpdir(), "concurrently-ocaml-restart-"));
  const marker = resolve(cwd, "attempt.state");
  const command =
    "node -e 'const fs=require(\"fs\");const p=process.env.CONCURRENTLY_RESTART_MARKER;if(fs.existsSync(p)){process.stdout.write(\"ok\");process.exit(0)}fs.writeFileSync(p,\"1\");process.exit(1)'";
  return {
    cwd,
    marker,
    command,
    reset() {
      rmSync(marker, { force: true });
    },
    cleanup() {
      rmSync(cwd, { force: true, recursive: true });
    },
  };
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

function normalizeVersionStdout(stdout) {
  return stdout.replace(/^\d+\.\d+\.\d+\n$/, "<version>\n");
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

function normalizePidStdout(stdout) {
  return stdout
    .replace(/^\[\d+\]/gm, "[<pid>]")
    .replace(/^\d+:/gm, "<pid>:");
}

function normalizeNodeTimerWarningPid(stderr) {
  return stderr.replace(/^\(node:\d+\)/gm, "(node:<pid>)");
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

function normalizeSignalTrapCloseStatus(stdout) {
  return stdout
    .replace(/exited with code (?:130|SIGINT)/g, "exited with code <SIGINT>")
    .replace(/exited with code (?:138|SIGUSR1)/g, "exited with code <SIGUSR1>");
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
