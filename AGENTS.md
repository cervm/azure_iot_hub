# Working agreements

## Scope and style

- Keep code and documentation concise; avoid speculative abstractions.
- Ask when requirements are unclear. Discuss public API choices, new dependencies,
  and intentional behaviour changes before implementing them.
- Use modern, idiomatic Dart and the FVM-pinned SDK. Keep this package pure Dart
  for native runtimes, prioritising Linux ARM64.
- Use dot shorthand when an explicit declaration or clear argument/return context
  identifies the type. Keep type names where shorthand would obscure the meaning.
- Keep `lib/azure_iot_hub.dart` as the public entry point. Keep `InternalClient`,
  transport implementations, dependency types and mutable diagnostics internal.

## Compatibility and lifecycle

- Use the pinned stable C# SDK's observable behaviour as the baseline for supported
  features. Read the relevant contracts and source/test mappings in
  [doc/upstream.md](doc/upstream.md) before changing behaviour. Keep responsibilities
  and tests recognisable for comparison; adapt threading and language mechanics to Dart.
- Microsoft's IoT Hub protocol contract governs conflicts. Discuss and record
  deviations; preserve the agreed contracts below.
- `open()` must fail with a protocol error when the twin-response subscription is
  rejected, rather than following C# in ignoring the SUBACK failure code.
- Use `cancellation_token` internally for C#-style cooperative cancellation. Expose
  SDK-owned `CancellationTokenSource` and read-only `CancellationToken` wrappers;
  keep dependency types private. Avoid a speculative cancellation framework.
- A transient disconnect does not immediately fail a send; cancelling one operation
  does not stop client recovery.
- Always enforce one finite operation deadline, including reconnect waits and
  retries, even with a caller token. Default to four minutes. This intentionally
  differs from C# token precedence.
- Report connection-status handler errors to their registering Dart Zone without
  interrupting recovery. The first close always reports `disabled/clientClose`.
  These intentionally differ from C# callback and shutdown behaviour.
- Deliver desired-property patches and restore subscriptions. The application owns
  snapshot retrieval and version reconciliation. Re-registering after removal must
  subscribe again, correcting the pinned C# subscription-flag defect.
- Refresh cached SAS credentials when requested within the renewal window;
  do not schedule proactive disconnects.
- Use a caller-prepared `SecurityContext` for X.509 over MQTT/TLS or WebSockets.
  The application owns certificate loading, renewal and the context; retain chains
  there instead of installing them into the OS store. X.509 WebSockets require
  application opt-in to `allowLegacyUnsafeRenegotiation` on a dedicated IoT Hub
  context. Never enable it automatically or bypass server verification.
- Preserve C# C2D polling/callback dispatch and explicit ordered completion. Reject
  invalid completion without consuming earlier entries; defer automatic PUBACKs
  behind unfinished messages. Bound retained incoming messages and retire on
  overflow without acknowledging excess C2D data. Preserve null versus empty
  property values. These include agreed protocol corrections and resource limits.
- Preserve named/default async direct-method handlers and byte payloads. The
  application owns handler timeouts. Bound incoming calls separately using the
  existing count/byte limits; overload returns 503 when response capacity permits,
  otherwise the cloud caller times out.
- Make cancellation, deadlines, delivery uncertainty and resource limits explicit.
  Bound pending work and queues; guard late callbacks and completion races.
- Keep credentials, device payloads and raw transport/provider/handler exception
  text out of SDK diagnostics and failures.

## Validation and documentation

- Adapt relevant tests from the pinned C# SDK as the starting point, preserving
  recognisable cases, source references and copyright/licence notices in adapted
  code and tests. Add Dart-specific cases for lifecycle races and agreed deviations.
- Use deterministic lifecycle tests with controlled clocks, timers and transport.
  Keep real-hub tests opt-in; never commit or log credentials. Follow
  [doc/testing.md](doc/testing.md) for setup and live-test procedures.
- Run `fvm dart format .`, `fvm dart analyze` and relevant `fvm dart test` checks for
  code changes. Report validation limitations accurately.
- Update affected API docs, examples, README, changelog and source/test mappings
  when behaviour changes. Keep tested SDKs/platforms and live-hub coverage distinct
  in `doc/testing.md`.
- Before publishing, verify the declared minimum Dart SDK, review
  [upstream changes](doc/upstream.md#upstream-maintenance), and run
  `fvm dart pub publish --dry-run`. Inspect the archive: retain licence notices and
  exclude local tooling, credentials and test fixtures.
