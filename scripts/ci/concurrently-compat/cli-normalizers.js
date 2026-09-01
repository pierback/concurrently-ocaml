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
    .replace(/^(?:index|concurrently)(?:\.js)? /, "concurrently.js ");
}

function normalizeNpmLogPaths(stdout) {
  return stdout.replace(
    /A complete log of this run can be found in: .+?debug-\d+\.log/g,
    "A complete log of this run can be found in: <npm-log>"
  );
}

function normalizeNodeTimeoutWarningStderr(stderr) {
  return stderr.replace(
    /^\(node:\d+\) Timeout(?:NaN|Negative)Warning: [^\r\n]*\r?\nTimeout duration was set to 1\.\r?\n(?:\(Use `node --trace-warnings \.\.\.` to show where the warning was created\)\r?\n)?/gm,
    ""
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
      /^--> │[ ]{2}│ <duration> │ (?:0|SIGTERM) │ true │ sleep 1 │$/gm,
      "--> │  │ <duration> │ <killed> │ true │ sleep 1 │"
    );
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

function normalizeInvalidWildcardOmissionStderr(stderr) {
  if (stderr.includes("Invalid regular expression: /[/")) {
    return "<invalid wildcard omission>\n";
  }
  if (stderr.includes("invalid wildcard omission regular expression: [")) {
    return "<invalid wildcard omission>\n";
  }
  return stderr;
}

function normalizeEmptyCommandAssertionStderr(stderr) {
  if (stderr.includes("[concurrently] command cannot be empty")) {
    return "<empty command assertion>\n";
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
    )
    // Kill-timeout signal escalation races shell process-group termination;
    // upstream can report either signal for these trap fixtures.
    .replace(
      /^\[0\] (sh -c "trap '' TERM; while :; do : > '[^']+\/(?:fractional|submillisecond|negative)\.ready'; sleep 0\.01; done") exited with code (?:SIGTERM|SIGKILL)$/gm,
      "[0] $1 exited with code <SIGTERM_OR_SIGKILL>"
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

module.exports = {
  normalizeEmptyCommandAssertionStderr,
  normalizeFractionalMaxProcessesStdout,
  normalizeHelpStdout,
  normalizeInvalidWildcardOmissionStderr,
  normalizeLineOrderStdout,
  normalizeNpmLogPaths,
  normalizeNodeTimeoutWarningStderr,
  normalizePartialInputTargetStdout,
  normalizePidStdout,
  normalizeShellSignalDiagnosticAndTrapCleanupStdout,
  normalizeShellSignalDiagnosticStdout,
  normalizeShellTrapStatus,
  normalizeSignal,
  normalizeSignalKilledDurationSortedTimingsStdout,
  normalizeSignalKilledTimingsStdout,
  normalizeSignalTrapCloseStatus,
  normalizeSignalTrapStatus,
  normalizeStatus,
  normalizeStderr,
  normalizeStdout,
  normalizeTimingsStdout,
  normalizeUnknownSignalStderr,
  normalizeVersionStdout,
};
