const assert = require("node:assert/strict");
const test = require("node:test");

const { eventWrapperCommand } = require("../lib/native-backend");

test("native event wrapper is safe to pass through a single cmd.exe command", () => {
  const wrapper = eventWrapperCommand(
    'node -e "setTimeout(() => {}, 1000)"',
    "/tmp/events/0.json",
    "/tmp/events/0.start",
    "/tmp/events/0.kill",
    false,
    "/tmp/events/0.env.json",
    undefined,
    false,
    false,
    "cmd.exe"
  );

  assert.doesNotMatch(wrapper, /[\r\n]/);
});

test("native event wrapper does not double-encode shell metacharacters", () => {
  const command = String.raw`node -e "console.log('C:\\quoted\\path')";`.repeat(50);
  const wrapper = eventWrapperCommand(
    command,
    "/tmp/events/0.json",
    "/tmp/events/0.start",
    "/tmp/events/0.kill",
    false,
    "/tmp/events/0.env.json",
    undefined,
    false,
    false,
    "cmd.exe"
  );

  assert.ok(wrapper.length < 8192, `wrapper is ${wrapper.length} bytes`);
});
