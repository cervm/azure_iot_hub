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
```
