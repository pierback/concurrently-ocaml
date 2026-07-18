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

module.exports = { closeEventsSucceeded, runOnFinishCallbacks };
