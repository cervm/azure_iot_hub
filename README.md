# azure_iot_hub

A standalone, pure-Dart Azure IoT Hub device SDK for native runtimes.

In development: the public API is experimental and publishing is currently
disabled. Behaviour follows the pinned stable C# device SDK; see the
[compatibility reference](docs/upstream.md) for source/test mappings and intentional
differences.

## Features

Status describes the current implementation. See [testing](docs/testing.md) for
validation coverage and remaining gaps.

| Feature | Status | Details |
| --- | --- | --- |
| MQTT 3.1.1 over TLS | Implemented | Default transport, port 8883 |
| MQTT over secure WebSockets | Implemented | Explicit selection, port 443; no automatic fallback |
| SAS authentication | Implemented | Shared key, supplied token or asynchronous token provider |
| Device-to-cloud telemetry | Implemented | QoS 1; application properties, message/correlation IDs, content type/encoding |
| Read device twin properties | Implemented | Desired and reported properties as Dart maps |
| Update reported properties | Implemented | JSON patches, including deletion with `null` |
| Desired-property callbacks | Implemented | Patches and subscription recovery; application owns reconciliation |
| Direct methods | Implemented | Named/default async handlers, responses and subscription recovery |
| Retry and reconnect | Implemented | Transient failures; bounded pending work, no offline persistence |
| Connection-status callbacks | Implemented | Connection, recovery and shutdown notifications |
| Cancellation and timeouts | Implemented | SDK-owned tokens; finite timeout across retries |
| Cloud-to-device messages | Implemented | Polling or callbacks, properties and explicit ordered completion |
| X.509 authentication | Not implemented | |
| File upload | Not implemented | |
| Module clients | Not implemented | |
| IoT Plug and Play | Not implemented | No model ID or component support |
| AMQP / HTTPS transports | Not implemented | |

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

`setMethodHandler(name, handler)` registers an async direct-method handler;
`setMethodDefaultHandler(handler)` provides a fallback. Return a `MethodResponse`
with an integer status and optional JSON bytes. Passing null removes a handler.
Handler execution is application-owned; registration and response sends use finite
timeouts. See the [example](example/direct_methods_example.dart) and
[method contract](docs/upstream.md#direct-methods).

`receive()` waits for one cloud-to-device message; `setReceiveMessageHandler`
registers a callback instead. Call `complete(message)` after processing, in receive
order. Callback return does not acknowledge the message. Messages expose immutable
payload bytes and application/system properties. See the
[C2D contract](docs/upstream.md#cloud-to-device-messages) and
[manual test](docs/testing.md#manual-cloud-to-device-test).

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

Normal test runs use local peers and skip real-hub tests. See
[testing](docs/testing.md) for coverage, validation gaps and opt-in Azure tests.

The package currently depends on a pinned `mqtt_client`
[fork](docs/mqtt-prototype.md#focused-dependency-fix) for packet-identifier handling.
Implementation details and upstream test mappings are in the
[transport notes](docs/telemetry-transport.md), [twin notes](docs/twins.md) and
[C# compatibility reference](docs/upstream.md).
