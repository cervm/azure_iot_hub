# azure_iot_hub

A standalone, pure-Dart Azure IoT Hub device SDK for native runtimes.

The experimental public API supports SAS authentication, MQTT over TLS and secure
WebSockets, telemetry, and device twins. Behaviour follows the pinned stable C#
device SDK; see the [upstream reference](docs/upstream.md) for source/test mappings
and intentional differences.

## Usage

Import the package library. Connection strings should come from secure configuration:

```dart
import 'dart:convert';
import 'package:azure_iot_hub/azure_iot_hub.dart';

Future<void> sendTelemetry(String connectionString) async {
  final client = DeviceClient.fromConnectionString(connectionString);
  try {
    await client.sendEvent(
      .new(
        utf8.encode(jsonEncode({'temperature': 21.5})),
        contentType: 'application/json',
        contentEncoding: 'utf-8',
      ),
    );
  } finally {
    await client.close();
  }
}
```

Operations connect implicitly; `open()` is also available. Select
`transport: .webSocket` for WSS on port 443. `DeviceClient.withTokenProvider`
accepts an asynchronous SAS provider. Tokens are cached and refreshed when a
connection requests eligible credentials, following C#; renewal does not schedule
disconnects. See the [authentication notes](docs/upstream.md#internal-authentication-coverage).

`getTwin()` returns `Twin` with `twin.properties.desired` and `reported` maps.
`updateReportedProperties` sends a JSON patch; null values delete properties.
`setDesiredPropertyUpdateCallback` receives patches and accepts null to unsubscribe.
Applications own snapshot retrieval and version reconciliation. See the
[twin notes](docs/twins.md).

Cancellation is optional: pass a `CancellationTokenSource`'s `token` and call
`source.cancel()`. Every operation retains a finite timeout, four minutes by
default, including reconnect waits. `OperationFailure` exposes `reason`, `delivery`
and an optional twin response `statusCode`. `DeliveryState.unknown` means a failed
operation may already have reached the hub; retrying can duplicate its effects.
See the [public API contract](docs/upstream.md#public-device-api).

`setConnectionStatusChangesHandler((status, reason) { ... })` observes connection,
recovery and shutdown. Passing null removes the handler; registration does not
replay the current state. Duplicate status/reason pairs are suppressed. Handler
errors go to its registering Dart Zone, and the first `close()` always reports
`disabled/clientClose`. See the [status contract](docs/upstream.md#connection-status-callbacks).

The [runnable example](example/azure_iot_hub_example.dart) reads
`AZURE_IOT_DEVICE_CONNECTION_STRING`, sends telemetry and retrieves the twin:

```sh
fvm dart run example/azure_iot_hub_example.dart
```

## Development

Use the Dart SDK pinned by FVM:

```sh
fvm dart pub get
fvm dart format .
fvm dart analyze
fvm dart test
```

Controlled tests cover both transports, cancellation, retries, deadlines, SAS
providers and bounded pending work. Public API tests exercise the same operations
using only the package's SDK import. See the [transport notes](docs/telemetry-transport.md)
and [MQTT prototype](docs/mqtt-prototype.md).

User-run live tests have passed for telemetry, twin updates, desired callbacks
and WSS. Linux ARM64, live reconnect and long-running reliability validation remain
outstanding. The public API migration has not yet been rerun against a real hub.

## Optional Azure smoke test

Configure `AZURE_IOT_TEST_DEVICE_CONNECTION_STRING` securely in your environment
for a dedicated test device, then run:

```sh
AZURE_IOT_RUN_INTEGRATION=1 fvm dart test test/integration/telemetry_test.dart
```

This sends one telemetry event and waits for IoT Hub's PUBACK. It does not verify
downstream routing or consumption. Normal test runs skip it; never put credentials
in source files, command arguments or test logs.

To validate secure WebSockets on port 443 with the same device:

```sh
AZURE_IOT_RUN_INTEGRATION=1 fvm dart test test/integration/websocket_test.dart
```

This sends telemetry and retrieves the twin over WSS. It checks PUBACK and twin
versions without changing twin properties. The user-run test passed on
24 October 2026 after adding the documented SAS query option; see the
[transport validation notes](docs/telemetry-transport.md).

To validate twin retrieval separately with the same environment configuration:

```sh
AZURE_IOT_RUN_INTEGRATION=1 fvm dart test test/integration/twin_test.dart
```

This reads desired/reported properties without changing them. To exercise updates:

```sh
AZURE_IOT_RUN_INTEGRATION=1 fvm dart test test/integration/reported_properties_test.dart
```

The update test writes a uniquely named `sdkPatchTest_...` reported property,
checks nested merge/deletion, and deletes it in `finally`. It advances the reported
version; failed network cleanup may leave the test property behind.

To validate desired-property callbacks and re-registration, run the manual test
with its separate opt-in:

```sh
AZURE_IOT_RUN_MANUAL_DESIRED=1 fvm dart test test/integration/desired_properties_test.dart --reporter expanded
```

When it prints `STEP 1 READY`, add the printed temporary property with numeric
value `1` inside the test device twin's `properties.desired` in Azure Portal and
save. When it prints `STEP 2 READY`, change that same property's value to `2` and
save again. Allow the test to finish, then set the temporary property to `null`
and save to delete it.
Each step allows three minutes for the portal edit. The test checks both patches
and increasing versions, with callback removal and re-registration between them.
It does not test reconnect recovery. The device cannot perform desired-property
cleanup itself; the test prints the property name even on failure.

Run live tests sequentially when sharing a device identity; simultaneous clients
can disconnect each other. The user-run PATCH test passed, verifying updates,
twin retrieval and cleanup. The manual desired-property test also passed,
verifying patch delivery before and after callback removal and re-registration;
see the [validation notes](docs/twins.md). Live reconnect and the longer SAS expiry
test remain unverified.
