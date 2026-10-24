## 0.1.0-dev.1

- Establish the package structure and C# compatibility reference.
- Add a test-only MQTT/cancellation prototype, adapted C# cancellation cases and
  dependency regression tests against the patched MQTT fork.
- Pin the focused packet-identifier fix and handle connection retirement in the
  prototype without changing the dependency's connection lifecycle.
- Add internal device connection-string parsing and SAS signing, with C# reference
  tests, fixed signature vectors and credential-redaction checks.
- Extract the operation lifecycle into internal SDK code, using `cancellation_token`
  without exposing its types, and add deterministic cancellation/deadline tests.
- Add internal SAS-authenticated MQTT/TLS telemetry with PUBACK completion,
  bounded queues, reconnect/backoff and explicit delivery uncertainty.
- Own the raw socket through TLS setup to release stalled handshakes and permit
  recovery; add controlled TLS regressions and an opt-in Azure smoke test.
- Cache shared-key SAS tokens and refresh eligible tokens on reconnect, following
  C# without scheduled disconnects; add adapted authentication and TLS regressions.
- Add internal twin retrieval, connection-time response subscription, correlated
  service responses, throttling retries and bounded response waits. Reject failed
  subscriptions as agreed; add adapted C# cases and an opt-in live twin test.
