# Working agreements

- Keep code and documentation concise; avoid speculative abstractions.
- Ask when requirements are unclear. Discuss public API choices, new dependencies,
  and intentional behaviour changes before implementing them.
- Use modern, idiomatic Dart and the FVM-pinned SDK. Keep this package pure Dart.
- Use dot shorthand when an explicit declaration or clear argument/return context
  identifies the type. Keep type names where shorthand would obscure the meaning.
- Target native Dart runtimes, prioritising Linux ARM64.
- Use the pinned stable C# SDK's observable behaviour as the baseline for supported
  features. Keep responsibilities and tests recognisable for upstream comparison;
  adapt threading and language mechanics to Dart.
- Microsoft's IoT Hub protocol contract governs conflicts. Discuss and record
  deviations; do not silently improve or simplify behaviour.
- Fail open with a protocol error when the twin-response subscription is rejected.
  This is an agreed deviation from C# ignoring the SUBACK failure code.
- Use the pinned reference and source/test mapping in [docs/upstream.md](docs/upstream.md).
  Preserve copyright and licence notices for adapted code and tests.
- Use `cancellation_token` internally for C#-style cooperative cancellation. Expose
  SDK-owned `CancellationTokenSource` and read-only `CancellationToken` wrappers;
  keep dependency types private. Avoid a speculative cancellation framework.
- Follow C# retry/reconnect behaviour: a transient disconnect does not immediately
  fail a send; cancelling one operation does not stop client recovery.
- Report connection-status handler errors to their registering Dart Zone without
  interrupting recovery. The first close always reports disabled/clientClose.
  These are agreed deviations from C# callback and shutdown behaviour.
- Follow C# desired-property behaviour: deliver patches and restore subscriptions.
  Snapshot retrieval and version reconciliation belong to the device application.
  Re-registering after removal must subscribe again; this corrects the pinned
  C# subscription-flag defect by agreement.
- Follow C# MQTT SAS renewal: refresh cached credentials when requested within
  the renewal window; do not schedule proactive disconnects.
- Always enforce a finite operation timeout, including when a caller supplies a
  cancellation token. Default to four minutes; include reconnect waits and retries
  in the same deadline. This is an agreed deviation from C# token precedence.
- Make cancellation, deadlines, delivery uncertainty and resource limits explicit.
  Bound pending work and queues; guard late callbacks and completion races.
- Adapt relevant tests from the pinned C# SDK as the starting point, preserving
  recognisable cases and source references. Add Dart-specific tests for lifecycle
  races and agreed deviations.
- Use deterministic lifecycle tests with controlled clocks, timers and transport.
  Keep real-hub integration tests opt-in; never commit or log credentials.
- Run `fvm dart format .`, `fvm dart analyze` and relevant `fvm dart test` checks for
  code changes. Report validation limitations accurately.
