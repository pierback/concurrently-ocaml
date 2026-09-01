"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");

const { assertApiShellSupportsIpc } = require("../lib/shell-command");

test("the Windows shell launcher rejects command IPC", () => {
  assert.throws(
    () =>
      assertApiShellSupportsIpc(
        { stdio: ["ignore", "pipe", "pipe", "ipc"] },
        "win32"
      ),
    /command IPC on Windows requires options\.spawn/
  );
});

test("the shell launcher accepts Windows without IPC and POSIX with IPC", () => {
  assert.doesNotThrow(() =>
    assertApiShellSupportsIpc(
      { stdio: ["ignore", "pipe", "pipe"] },
      "win32"
    )
  );
  assert.doesNotThrow(() =>
    assertApiShellSupportsIpc(
      { stdio: ["ignore", "pipe", "pipe", "ipc"] },
      "linux"
    )
  );
});
