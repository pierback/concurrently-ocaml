"use strict";

function closeEventsSucceeded(events, successCondition = "all") {
  if (events.length === 0) {
    return true;
  }
  if (successCondition === "first") {
    return events[0].exitCode === 0;
  }
  if (successCondition === "last") {
    return events[events.length - 1].exitCode === 0;
  }
  const match = /^(!?)command-(.+)$/.exec(String(successCondition));
  if (!match) {
    return events.every((event) => event.exitCode === 0);
  }
  const negated = match[1] === "!";
  const selector = match[2];
  const targetEvents = closeEventsForSelector(events, selector);
  if (negated) {
    return events.every(
      (event) => targetEvents.includes(event) || event.exitCode === 0
    );
  }
  return (
    targetEvents.length > 0 &&
    targetEvents.every((event) => event.exitCode === 0)
  );
}

function nativeRunSucceeded(
  exitCode,
  events,
  { killOthersOn = [], nativeOutcome, successCondition = "all" } = {}
) {
  // A native kill decision precedes event-file serialization, so a killed
  // sibling can receive an earlier timestamp than the command that triggered it.
  return (
    closeEventsSucceeded(events, successCondition) ||
    (exitCode === 0 &&
      nativeOutcome === "success" &&
      killOrderingCanUseNativeOutcome(events, successCondition, killOthersOn))
  );
}

function killOrderingCanUseNativeOutcome(events, successCondition, killOthersOn) {
  if (successCondition !== "first" && successCondition !== "last") {
    return false;
  }
  const selectedEvent =
    successCondition === "first" ? events[0] : events[events.length - 1];
  if (!selectedEvent?.killed) {
    return false;
  }
  return events.some(
    (event) =>
      !event.killed &&
      killOthersOn.includes(event.exitCode === 0 ? "success" : "failure")
  );
}

function closeEventsForSelector(events, selector) {
  const selectedIndex = Number(selector);
  if (Number.isNaN(selectedIndex)) {
    return events.filter((event) => event.command.name === selector);
  }
  return events.filter(
    (event) => event.command.name === selector || event.index === selectedIndex
  );
}

function runOnFinishCallbacks(result, onFinishCallbacks) {
  if (onFinishCallbacks.length === 0) {
    return result;
  }

  return result.finally(() =>
    Promise.all(onFinishCallbacks.map((onFinish) => onFinish()))
  );
}

module.exports = {
  closeEventsSucceeded,
  nativeRunSucceeded,
  runOnFinishCallbacks,
};
