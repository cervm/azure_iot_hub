# Cancellation and MQTT prototype

This records the original test-only experiment and the dependency fix used by the
SDK. For the current client, see the [README](../README.md) and
[transport notes](telemetry-transport.md). The prototype's operation lifecycle uses
the SDK's internal `PendingOperation` component. The SDK internally uses
`cancellation_token` 2.0.1 and pins the `mqtt_client` fork at
[`e9baef8`](https://github.com/cervm/mqtt_client/commit/e9baef8c848f3ada77b1f02750adf479ab8b3f0d),
based on 10.13.0.

Run with `fvm dart test test/prototype --reporter expanded`. The suite uses a local
TCP peer which explicitly sends CONNACK and PUBACK. No Azure credentials are needed.
Operation deadlines, connection deadlines and retry delays are advanced by a
controlled timer. Socket I/O and mqtt_client's own timers use the real event loop.
The MQTT CONNACK timeout is one real second; the outer connection deadline is
five virtual seconds. Operation deadlines do not depend on real sleeps.

## Results

The 22 tests pass on macOS ARM64 with Dart 3.13.5. Two cases are adapted from the
pinned C# MQTT tests; see [the source/test mapping](upstream.md#prototype-coverage).

- Pre-cancelled operations do not allocate a connection or submit a message.
- Cancellation, shutdown and deadlines settle each tested operation once.
  Cancellation listeners detach after success, cancellation and timeout.
- A caller token can cancel multiple operations without stopping client recovery.
- An operation deadline includes connection waits and retries. Supplying a caller
  token does not disable it.
- QoS 1 completion waits for PUBACK. Cancellation, timeout or shutdown after
  submission reports unknown delivery, including after reconnect.
- An unacknowledged, cancelled publish keeps its bounded slot until PUBACK or its
  original deadline. Expiry retires the connection; active operations can retry on
  a new connection under their original deadlines.
- Pending count and payload size are bounded. Obsolete callbacks are ignored.
- Shutdown is idempotent and stops recovery. It cancels callers immediately, then
  waits for an outstanding connection attempt before using public `disconnect()`.
  Keeping the handler reachable allows cleanup of a late socket and CONNACK.
- Recovery waits for a retired attempt to settle before creating its replacement.
- Packet-ID wrap preserves both outstanding publishes and their PUBACK correlation.

## Focused dependency fix

The fork prevents reuse of packet identifiers still awaiting protocol completion.
This follows [MQTT 3.1.1 §2.3.1](https://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html#_Toc398718025),
particularly MQTT-2.3.1-2 and MQTT-2.3.1-3. It retains the original 1–32,767 range,
public singleton and normal allocation sequence; `maxMessageIdentifier` is unchanged.

The fork adds 23 regressions covering QoS 1/2, subscribe/unsubscribe, identifier
exhaustion, reuse after acknowledgements and client isolation, including a wire
test. Exhaustion throws `StateError` before publish/unsubscribe submission;
subscribe retains its existing null/failure behaviour. Confirmed subscriptions
keep their local map keys, without reserving those IDs against later publishes.

Fork validation: formatting and analysis pass; 350 tests pass. One existing TLS
keep-alive test fails certificate verification on this machine; the identical
failure was reproduced on the untouched `3e89bc7` baseline. No upstream pull
request has been submitted.

Connection behaviour is unchanged in this fork. The prototype handles the pending
CONNACK/disconnect issue by retaining the client until its bounded attempt settles.
This can delay shutdown cleanup and recovery; it does not delay caller cancellation.

**Original limitation:** a separate native TLS experiment showed an open peer socket after
a stalled handshake timed out and public disconnect ran. A finite connection future
does not prove bounded native TLS resource cleanup. The SDK's subsequent
[owned TLS adapter](telemetry-transport.md) fixes this on the tested macOS runtime;
the test-only prototype intentionally retains the original dependency transport.

## Scope

The SDK uses `cancellation_token` internally: cooperative registration and merged
tokens support the tested lifetime model. It exposes its own
[source/token wrappers](upstream.md#sdk-owned-cancellation), keeping dependency
types internal.
The focused fork is pinned above; an upstream PR is deferred.
Rerun these regressions when changing the dependency.

The fixed retry delay, tiny payload/count limits and loopback TCP are experiment
controls. Azure topics, transport authentication, twins, error classification,
exponential backoff and jitter remain unimplemented in this harness. Current SDK
validation coverage and gaps are recorded in [testing](testing.md).
The harness retains the four-minute default operation timeout; tests shorten it
to ten virtual seconds.
