# Internal telemetry transport

The unexported `DeviceClient` now supports connection strings, SAS authentication,
implicit open, twin retrieval, reported-property updates and QoS 1 telemetry over
TLS on port 8883.
A successful send means PUBACK arrived; cancellation or failure after submission
reports unknown delivery.
Retries can produce duplicate telemetry, as with C# QoS 1 sends.

`MqttTransport` retains the pinned fork's codec, packet identifiers and publish
acknowledgement handling. Its connection adapter owns `RawSocket` through the TLS
handshake and handles partial reads/writes. No further fork changes are required.
The two upstream paths that log CONNECT credentials are bypassed, including when
another MQTT client enables the package's global logger.

## Lifetimes and bounds

- Every operation has one finite deadline, four minutes by default, including
  reconnect waits. Caller cancellation does not stop shared connection recovery.
- Submitted cancelled packets retain capacity until PUBACK or their original
  deadline. Expiry retires the connection and allows other operations to retry.
- The current internal defaults allow 16 pending operations and 4 MiB of pending
  payload/topic/frame bytes. Both limits are configurable and checked before
  submission. They bound retained work, not exact process RSS.
- Socket read and write buffers each have a separate cap of the pending-byte
  budget plus 64 KiB. Frame lengths are checked before accepting their contents.
- Connection attempts have a 60-second total deadline. The raw socket closes even
  if the peer stalls TLS; retirement also releases the caller of the TLS future,
  which Dart may otherwise leave pending after raw socket closure.
- Open completes after the twin-response subscription is acknowledged, following
  C#. The connection deadline also covers that SUBACK wait. A rejected subscription
  fails open with a protocol error, as explicitly agreed.
- Dart cannot cancel native DNS resolution before `startConnect` returns its task.
  The client serializes that setup, cancels late tasks and closes late sockets.
  Operations and shutdown still settle promptly; recovery can wait for DNS.
- Closing is terminal, cancels pending operations and stops recovery. TLS,
  credential and protocol failures stop automatic recovery and fail pending work;
  a later explicit operation may try again. Network failures retry.

Queue defaults and connection bounds are internal tuning values, not a published
configuration contract. There is no offline persistence.

## SAS renewal

Shared-key credentials use C#'s one-hour token lifetime and 15% renewal buffer.
When a connection attempt requests credentials, the cache reuses a token outside
that window or signs a fresh one inside it. The threshold is approximately
51 minutes after signing; C#'s expiry rounding and buffer truncation are preserved.

Reaching the renewal window or token expiry does not schedule a disconnect.
If IoT Hub closes the session, ordinary recovery requests credentials again.
No service-side grace period is assumed. This agreed C# behaviour takes priority
over PSW-252's proactive-renewal wording; see the [source mapping](upstream.md).

External SAS bytes are passed unchanged, including after the parser's existing
clock-skew check; the service determines validity. External token replacement
and provider callbacks remain unimplemented.

## Validation and limits

Controlled tests use a local TLS peer and explicit CONNACK/PUBACK. A manual clock
drives operation, connection, retry and keepalive timers; socket I/O uses the real
event loop. Coverage includes C# pre-cancellation scenarios, CONNECT fields,
property encoding, byte/count capacity, binary payloads, fragmented packets,
transient retries, authentication refusal, certificate rejection, PINGRESP timeout,
late connection-task cleanup and repeated stalled TLS handshakes. SAS coverage
checks reuse before the renewal window, refresh on reconnect within the window
and after expiry, and preservation of an in-flight send's original deadline.
A 70-minute virtual-clock test keeps one active connection without scheduled
renewal disconnects; its local peer does not enforce service-side token expiry.

Controlled tests validated on macOS ARM64 with FVM Dart 3.13.5. Linux ARM64, native
DNS/TCP blackholes and long-running resource usage remain unverified. The late-DNS test
controls task delivery; it does not emulate an operating-system DNS blackhole.
The test certificate expires in October 2027; regeneration is documented beside it.

On 24 October 2026, the user ran the opt-in integration test against Azure IoT Hub
and reported `+1: All tests passed!`. This confirms SAS authentication, MQTT/TLS
connection and one QoS 1 publish through PUBACK. Live reconnect, token renewal and
downstream routing/consumption require separate validation.

The previous telemetry result predates the connection-time twin subscription.
The user's subsequent successful live PATCH test covers that subscription,
reported-property updates, twin retrieval and cleanup; see [twin notes](twins.md).
External token replacement, WSS, remaining twin operations and public API design
remain subsequent work. The live SAS expiry test is deferred.
