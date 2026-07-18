"use strict";

function outputWriter(outputSink) {
  let pendingWrites = 0;
  let outputError;
  let ended = false;
  const waiters = [];
  const settleWaiters = () => {
    if (pendingWrites !== 0) {
      return;
    }
    while (waiters.length > 0) {
      const waiter = waiters.shift();
      if (outputError) {
        waiter.reject(outputError);
      } else {
        waiter.resolve();
      }
    }
  };
  return {
    write(chunk, command) {
      if (!outputSink) {
        return;
      }
      pendingWrites += 1;
      try {
        outputSink.write(chunk, command, (error) => {
          if (error && !outputError) {
            outputError = error;
          }
          pendingWrites -= 1;
          settleWaiters();
        });
      } catch (error) {
        if (!outputError) {
          outputError = error;
        }
        pendingWrites -= 1;
        settleWaiters();
      }
    },
    finish() {
      if (!ended) {
        ended = true;
        try {
          outputSink?.end?.();
        } catch (error) {
          if (!outputError) {
            outputError = error;
          }
        }
      }
      if (pendingWrites === 0) {
        return outputError ? Promise.reject(outputError) : Promise.resolve();
      }
      return new Promise((resolve, reject) => {
        waiters.push({ resolve, reject });
      });
    },
  };
}

module.exports = { createOutputWriter: outputWriter };
