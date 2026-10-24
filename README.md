# azure_iot_hub

A standalone, pure-Dart Azure IoT Hub device SDK for native runtimes.

Early development: the device API is internal and not exported. The initial release targets
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

An internal client now connects using device SAS credentials over MQTT/TLS and
sends QoS 1 telemetry, completing on PUBACK. Controlled TLS tests cover retries,
cancellation, deadlines, certificate validation, stalled-handshake cleanup and
bounded pending work. Shared-key SAS tokens are cached and refreshed on reconnect
when eligible, following C#; renewal does not schedule disconnects. See the
[transport notes](docs/telemetry-transport.md).

The prototype uses the SDK's internal operation lifecycle for linked cancellation,
finite deadlines and delivery uncertainty. `cancellation_token` remains an internal
dependency; its types are not exported by this package.

External token replacement, secure WebSockets, twins and the public API remain
unimplemented.
The live Azure telemetry smoke test has passed in a user-run test. Linux ARM64
and long-running reliability validation remain outstanding.

## Optional Azure smoke test

Configure `AZURE_IOT_TEST_DEVICE_CONNECTION_STRING` securely in your environment
for a dedicated test device, then run:

```sh
AZURE_IOT_RUN_INTEGRATION=1 fvm dart test test/integration/telemetry_test.dart
```

This sends one telemetry event and waits for IoT Hub's PUBACK. It does not verify
downstream routing or consumption. Normal test runs skip it; never put credentials
in source files, command arguments or test logs.
