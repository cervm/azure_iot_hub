## 0.1.0-dev.1

- Establish the package structure and C# compatibility reference.
- Add a test-only MQTT/cancellation prototype, adapted C# cancellation cases and
  dependency regression tests against the patched MQTT fork.
- Pin the focused packet-identifier fix and handle connection retirement in the
  prototype without changing the dependency's connection lifecycle.
- Add internal device connection-string parsing and SAS signing, with C# reference
  tests, fixed signature vectors and credential-redaction checks.
