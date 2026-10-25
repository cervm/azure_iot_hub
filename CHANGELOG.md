## 0.1.0-dev.1 (unreleased)

- Add an experimental `DeviceClient` API for native Dart runtimes, following the
  pinned C# SDK's behaviour for supported features.
- Support SAS authentication with shared keys, supplied tokens and asynchronous
  token providers, including credential caching and refresh on reconnect.
- Support MQTT over TLS and secure WebSockets, using a pinned `mqtt_client` fork
  that prevents reuse of in-flight packet identifiers.
- Send QoS 1 telemetry with application properties and supported message metadata.
- Retrieve twin properties, update reported properties and receive desired-property
  patches, restoring subscriptions after reconnect.
- Add SDK-owned cancellation tokens, finite operation deadlines, transient retries,
  bounded pending work and explicit delivery uncertainty.
- Add connection-status callbacks for connection, recovery and shutdown.
- Include adapted C# tests, deterministic lifecycle tests and opt-in IoT Hub tests.
