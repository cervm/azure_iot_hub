# azure_iot_hub

A standalone, pure-Dart Azure IoT Hub device SDK for native runtimes.

Early development: device APIs are not implemented yet. The initial release targets
SAS authentication, MQTT over TLS and secure WebSockets, telemetry, and device twins.

Behaviour follows the stable C# device SDK. See the [upstream reference](docs/upstream.md)
for the pinned version, source/test mapping and intentional differences.

## Development

Use the Dart SDK pinned by FVM:

```sh
fvm dart pub get
fvm dart format .
fvm dart analyze
fvm dart test
```

The [cancellation/MQTT prototype](docs/mqtt-prototype.md) exercises the actual MQTT
client against a controlled loopback peer. It is test-only and needs no Azure credentials.

Internal connection-string parsing and SAS signing are implemented with adapted
C# tests. They are not yet exposed through a public device client; token renewal
and transport integration remain to be implemented.

The prototype uses the SDK's internal operation lifecycle for linked cancellation,
finite deadlines and delivery uncertainty. `cancellation_token` remains an internal
dependency; its types are not exported by this package.
