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
- Use the pinned reference and source/test mapping in [doc/upstream.md](doc/upstream.md).
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
- Use a caller-prepared `SecurityContext` for X.509 over MQTT/TLS or WebSockets.
  Keep certificate loading, renewal and context ownership with the application;
  retain chains in the context instead of installing them into the OS store.
  For X.509 WebSockets, require application opt-in to
  `allowLegacyUnsafeRenegotiation` on a dedicated IoT Hub context. Never enable it
  automatically or bypass server verification.
- Follow C# C2D polling/callback dispatch and explicit ordered completion. Reject
  invalid completion without consuming earlier entries; defer automatic PUBACKs
  behind unfinished messages. Bound retained incoming messages and retire on
  overflow without acknowledging excess C2D data. Preserve null versus empty
  property values. These are agreed protocol corrections and resource limits.
- Follow C# direct-method dispatch with named/default async handlers and byte
  payloads. The application owns handler timeouts. Bound incoming calls separately
  using the existing count/byte limits; overload returns 503 when response capacity
  permits, otherwise the cloud caller times out. This is an agreed overload policy.
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
