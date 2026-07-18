const { runNativeApiCore } = require("./native-api-core");
const {
  runNativeApiCustomSpawnWithTimeout,
} = require("./native-api-custom-spawn");
const { runNativeApiShell } = require("./native-api-shell");
const {
  runNativeApiTeardownSelectors,
} = require("./native-api-teardown-selectors");

async function runNativeApiSmoke({
  assertEqual,
  cliCommandRunner,
  commands,
  nativeApiExplicitShell,
}) {
  await runNativeApiCore({ assertEqual, cliCommandRunner, commands });
  await runNativeApiShell({
    assertEqual,
    commands,
    nativeApiExplicitShell,
  });
  await runNativeApiCustomSpawnWithTimeout({
    assertEqual,
    commands,
    nativeApiExplicitShell,
  });
  await runNativeApiTeardownSelectors({ assertEqual, commands });
}

module.exports = { runNativeApiSmoke };
