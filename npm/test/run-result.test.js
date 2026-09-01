"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");

const {
  closeEventsSucceeded,
  nativeRunSucceeded,
} = require("../lib/run-result");

test("native outcome trusts the runner when kill-event timestamps invert", () => {
  const firstEvents = [
    { exitCode: "SIGTERM", killed: true },
    { exitCode: 0, killed: false },
  ];

  assert.equal(closeEventsSucceeded(firstEvents, "first"), false);
  assert.equal(
    nativeRunSucceeded(0, firstEvents, {
      killOthersOn: ["success"],
      nativeOutcome: "success",
      successCondition: "first",
    }),
    true
  );
  assert.equal(
    nativeRunSucceeded(0, firstEvents, {
      killOthersOn: ["failure"],
      nativeOutcome: "success",
      successCondition: "first",
    }),
    false
  );
  assert.equal(
    nativeRunSucceeded(1, firstEvents, {
      killOthersOn: ["success"],
      nativeOutcome: "success",
      successCondition: "first",
    }),
    false
  );

  const lastEvents = [...firstEvents].reverse();
  assert.equal(closeEventsSucceeded(lastEvents, "last"), false);
  assert.equal(
    nativeRunSucceeded(0, lastEvents, {
      killOthersOn: ["success"],
      nativeOutcome: "success",
      successCondition: "last",
    }),
    true
  );
});

test("native outcome does not hide SIGINT after a real kill trigger", () => {
  const firstEvents = [
    { exitCode: "SIGTERM", killed: true },
    { exitCode: 1, killed: false },
  ];

  assert.equal(closeEventsSucceeded(firstEvents, "first"), false);
  assert.equal(
    nativeRunSucceeded(0, firstEvents, {
      killOthersOn: ["failure"],
      nativeOutcome: "interrupted",
      successCondition: "first",
    }),
    false
  );

  const lastEvents = [...firstEvents].reverse();
  assert.equal(closeEventsSucceeded(lastEvents, "last"), false);
  assert.equal(
    nativeRunSucceeded(0, lastEvents, {
      killOthersOn: ["failure"],
      nativeOutcome: "interrupted",
      successCondition: "last",
    }),
    false
  );
});

test("native outcome preserves event policy without killed commands", () => {
  const events = [{ exitCode: 1, killed: false }];

  assert.equal(nativeRunSucceeded(0, events), false);
  assert.equal(nativeRunSucceeded(1, [{ exitCode: 0 }]), true);
});

test("native outcome preserves JavaScript numeric selector coercion", () => {
  const events = [
    {
      command: { name: "" },
      exitCode: 1,
      index: 0,
    },
    {
      command: { name: "" },
      exitCode: 0,
      index: 1,
    },
  ];

  assert.equal(
    nativeRunSucceeded(1, events, { successCondition: "command-1.0" }),
    true
  );
});

test("native outcome preserves positive selector existence after SIGINT", () => {
  const events = [
    {
      command: { name: "worker" },
      exitCode: "SIGINT",
      index: 0,
      killed: true,
    },
  ];

  assert.equal(
    nativeRunSucceeded(0, events, { successCondition: "command-missing" }),
    false
  );
  assert.equal(
    nativeRunSucceeded(0, events, { successCondition: "command-worker" }),
    false
  );
});
