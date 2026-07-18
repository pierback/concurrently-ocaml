const {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} = require("node:fs");
const { tmpdir } = require("node:os");
const { delimiter, resolve } = require("node:path");

function createCliFixtures({ shellQuote }) {
  const shortcutFixture = createShortcutFixture();
  const escapedScriptFixture = createEscapedScriptFixture();
  const literalWildcardFixture = createLiteralWildcardFixture();
  const invalidPackageFixture = createInvalidPackageFixture();
  const invalidDenoFixture = createInvalidDenoFixture();
  const killTimeoutFixture = createKillTimeoutFixture(shellQuote);
  const restartFixture = createRestartFixture();

  return {
    cleanup() {
      shortcutFixture.cleanup();
      escapedScriptFixture.cleanup();
      literalWildcardFixture.cleanup();
      invalidPackageFixture.cleanup();
      invalidDenoFixture.cleanup();
      killTimeoutFixture.cleanup();
      restartFixture.cleanup();
    },
    escapedScriptFixture,
    invalidDenoFixture,
    invalidPackageFixture,
    killTimeoutFixture,
    literalWildcardFixture,
    restartFixture,
    shortcutFixture,
  };
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

function createKillTimeoutFixture(shellQuote) {
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

module.exports = { createCliFixtures };
