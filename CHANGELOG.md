## 0.1.0-dev.1

- Add an experimental `DeviceClient` API for native Dart runtimes, following the
  pinned C# SDK's behaviour for supported features.
- Support SAS authentication with shared keys, supplied tokens and asynchronous
  token providers, including credential caching and refresh on reconnect.
- Support X.509 authentication over MQTT/TLS and secure WebSockets with a prepared
  Dart `SecurityContext`; WebSockets require explicit TLS renegotiation opt-in.
- Support MQTT over TLS and secure WebSockets.
- Send QoS 1 telemetry with application properties and supported message metadata.
- Retrieve twin properties, update reported properties and receive desired-property
  patches, restoring subscriptions after reconnect.
- Add SDK-owned cancellation tokens, finite operation deadlines, transient retries,
  bounded pending work and explicit delivery uncertainty.
- Add connection-status callbacks for connection, recovery and shutdown.
- Handle direct methods with named/default async callbacks, bounded incoming work,
  response retries and subscription recovery.
- Receive cloud-to-device messages by polling or callback, with message properties,
  explicit ordered completion and bounded incoming storage.
- Include adapted C# tests, deterministic lifecycle tests and opt-in IoT Hub tests.
