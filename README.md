# azure_iot_hub

A standalone, pure-Dart Azure IoT Hub device SDK for native runtimes.

Experimental prerelease: the public API may change. Behaviour follows the pinned
stable C# device SDK; see the [compatibility reference](doc/upstream.md) for
source/test mappings and intentional differences.

## Features

Implemented features are listed below. See [testing](doc/testing.md) for validation
coverage and remaining gaps.

| Feature | Details |
| --- | --- |
| MQTT 3.1.1 over TLS | Default transport, port 8883 |
| MQTT over secure WebSockets | Explicit selection, port 443; no automatic fallback |
| SAS authentication | Shared key, supplied token or asynchronous token provider |
| X.509 authentication | Application-configured `SecurityContext`; WSS requires explicit TLS renegotiation opt-in |
| Device-to-cloud telemetry | QoS 1; application properties, message/correlation IDs, content type/encoding |
| Device twins | Read desired/reported properties, patch reported properties (including deletion with `null`), receive desired patches and restore subscriptions |
| Direct methods | Named/default async handlers, responses and subscription recovery |
| Cloud-to-device messages | Polling or callbacks, properties and explicit ordered completion |
| Retry and reconnect | Transient failures; bounded pending work, no offline persistence |
| Connection-status callbacks | Connection, recovery and shutdown notifications |
| Cancellation and timeouts | SDK-owned tokens; finite timeout across retries |

File upload, module clients, IoT Plug and Play (model IDs/components), AMQP and HTTPS
transports are not implemented.

## Usage

Requires Dart 3.13.5 or later within Dart 3. Add the prerelease to your project:

```sh
dart pub add 'azure_iot_hub:^0.1.0-dev.1'
```

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
`transport: .webSocket` for WSS on port 443. The
[runnable example](example/azure_iot_hub_example.dart) reads
`AZURE_IOT_DEVICE_CONNECTION_STRING`, sends telemetry and retrieves the twin:

```sh
dart run example/azure_iot_hub_example.dart
```

### Authentication

`DeviceClient.withTokenProvider` accepts an asynchronous SAS provider. Tokens are
cached and refreshed when a connection requests eligible credentials; renewal does
not schedule disconnects. See the
[authentication contract](doc/upstream.md#internal-authentication-coverage).

For certificate authentication, use `DeviceClient.withX509(hostName: ..., deviceId:
..., securityContext: context)`. Prepare the Dart `SecurityContext` with trusted
server roots, the device certificate chain and its private key before construction.
The application owns certificate loading and renewal. For WebSockets on port 443,
select `transport: .webSocket` and explicitly set
`context.allowLegacyUnsafeRenegotiation = true` on a dedicated IoT Hub context.
The SDK never changes this setting; server certificate verification remains enabled.
See the [X.509 contract](doc/upstream.md#x509-authentication) and
[live test setup](doc/testing.md#optional-x509-test).

### Twins and incoming messages

`getTwin()` returns `Twin` with desired and reported maps under `twin.properties`.
Reported-property updates are JSON patches; desired callbacks deliver patches for
the application to reconcile. See [twin operations](doc/twins.md).

Direct methods use named/default async handlers returning `MethodResponse`.
Cloud-to-device messages support polling and callbacks; call `complete(message)`
after processing, in receive order. See the [direct-method example](example/direct_methods_example.dart)
and [C2D contract](doc/upstream.md#cloud-to-device-messages).

### Timeouts and shutdown

Operations have a finite timeout, four minutes by default, covering retries and
reconnect waits. Optional SDK-owned cancellation tokens cancel individual operations
without stopping recovery. `OperationFailure` exposes `reason`, `delivery` and an
optional twin response `statusCode`. `DeliveryState.unknown` means the operation may
already have reached the hub, so retrying can duplicate its effects.

Connection-status callbacks report connection, recovery and shutdown. `close()`
permanently shuts down the client. See the [public API contract](doc/upstream.md#public-device-api).

## Development

Repository development uses the Dart SDK pinned by FVM.

```sh
fvm dart pub get
fvm dart format .
fvm dart analyze
fvm dart test
```

Normal test runs use local peers and skip real-hub tests. See
[testing](doc/testing.md) for coverage, validation gaps and opt-in Azure tests.

Implementation details and upstream test mappings are in the
[transport notes](doc/telemetry-transport.md), [twin notes](doc/twins.md) and
[C# compatibility reference](doc/upstream.md).

## License

[MIT](LICENSE), copyright 2026 Marek Cervinka. Portions adapted from Microsoft's
Azure IoT C# SDK retain their original copyright and
[MIT licence](third_party/azure-iot-sdk-csharp-LICENSE).
