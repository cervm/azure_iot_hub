# Testing

Run commands from the repository root using the FVM-pinned SDK.

## Local tests

```sh
fvm dart test
```

Normal runs require no Azure credentials and skip real-hub tests. Controlled TLS
and WSS peers cover telemetry, twins, authentication, cancellation, retries,
deadlines, connection status and bounded pending work. Public API tests use only
the package's SDK import. See the [C# source/test mappings](upstream.md).

## Live validation status

Live tests passed on 24 October 2026 for TLS telemetry, reported-property updates
and twin retrieval, desired callbacks before and after re-registration, and WSS
telemetry/twin retrieval. These results predate the public API migration and
connection-status callbacks; those changes have controlled test coverage only.

Linux ARM64, live reconnect, SAS expiry/renewal and long-running resource usage
remain unverified. See the [transport](telemetry-transport.md#validation-and-limits)
and [twin](twins.md) notes for details.

## Optional Azure tests

Configure `AZURE_IOT_TEST_DEVICE_CONNECTION_STRING` securely in your environment
for a dedicated test device. Never put credentials in source files, command
arguments or test logs. Run live tests sequentially when sharing a device identity;
simultaneous clients can disconnect each other.

| Test | What it checks |
| --- | --- |
| `telemetry_test.dart` | Sends one event over TLS and waits for PUBACK |
| `websocket_test.dart` | Sends telemetry and retrieves the twin over WSS on port 443 |
| `twin_test.dart` | Reads desired/reported properties without changing them |
| `reported_properties_test.dart` | Creates a temporary reported property, verifies nested merge/deletion and cleans up |

```sh
AZURE_IOT_RUN_INTEGRATION=1 fvm dart test test/integration/telemetry_test.dart
AZURE_IOT_RUN_INTEGRATION=1 fvm dart test test/integration/websocket_test.dart
AZURE_IOT_RUN_INTEGRATION=1 fvm dart test test/integration/twin_test.dart
AZURE_IOT_RUN_INTEGRATION=1 fvm dart test test/integration/reported_properties_test.dart
```

PUBACK confirms hub acknowledgement, not downstream routing or consumption.
The reported-property test writes a unique `sdkPatchTest_...` property and deletes
it in `finally`. It advances the reported version; failed network cleanup may
leave the test property behind.

## Manual desired-property test

With the same connection-string environment variable configured, run:

```sh
AZURE_IOT_RUN_MANUAL_DESIRED=1 fvm dart test test/integration/desired_properties_test.dart --reporter expanded
```

1. At `STEP 1 READY`, add the printed temporary property with numeric value `1`
   inside the device twin's `properties.desired` in Azure Portal and save.
2. At `STEP 2 READY`, change that property's value to `2` and save again.
3. After the test finishes, set the temporary property to `null` and save to delete it.

Each step allows three minutes for the portal edit. The test checks both patches
and increasing versions, with callback removal and re-registration between them.
It does not test reconnect recovery. The device cannot delete desired properties;
the test prints the property name for manual cleanup even on failure.
