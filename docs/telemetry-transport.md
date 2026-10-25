# Telemetry transport

The public `DeviceClient` delegates to `InternalClient` for SAS or X.509 authentication,
implicit open, twin retrieval, reported-property updates, desired-property callbacks
and QoS 1 telemetry over TLS on port 8883 or secure WebSockets on port 443.
A successful send means PUBACK arrived; cancellation or failure after submission
reports unknown delivery.
Retries can produce duplicate telemetry, as with C# QoS 1 sends.

`MqttTransport` retains the pinned fork's codec, packet identifiers and publish
acknowledgement handling. Both connection adapters share a bounded MQTT decoder
and an owned `RawSocket` through the TLS handshake, including partial reads/writes.
The two upstream paths that log CONNECT credentials are bypassed, including when
another MQTT client enables the package's global logger.

## Secure WebSockets

The `transport: .webSocket` option selects WSS explicitly;
TCP/TLS remains the default. This corresponds to C#'s explicit MQTT transport
options; automatic TCP-to-WSS fallback and proxy configuration are not implemented.
SAS WSS uses `/$iothub/websocket?iothub-no-client-cert=true`, subprotocol `mqtt`,
binary messages and no compression; see the [source mapping](upstream.md).
X.509 WSS omits that query option to permit client-certificate negotiation and
requires explicit application opt-in to TLS renegotiation on a dedicated context;
see the [X.509 contract](upstream.md#x509-authentication).
Gateway routing still changes only the connection destination, not hub identity.

`mqtt_client` already supports WSS using Dart's `WebSocket`. Its connection wrapper
cannot abort native setup immediately or enforce our buffer limits. We reuse the
same Dart handshake/framing implementation through an owned `HttpClient` and TLS
socket, keeping the SDK's cancellation, deadlines and cleanup. We do not implement
WebSocket framing ourselves. Shutdown closes native I/O immediately and disposes
the WebSocket sink after an active write settles.

## Lifetimes and bounds

- Every operation has one finite deadline, four minutes by default, including
  reconnect waits. Caller cancellation does not stop shared connection recovery.
- Submitted cancelled packets retain capacity until acknowledgement or their
  original deadline. Expiry retires the connection and allows other operations to retry.
- The defaults allow 16 pending operations and 4 MiB of pending
  payload/topic/frame bytes. Both limits are configurable and checked before
  submission. They bound retained work, not exact process RSS.
- Socket read and write buffers each have a separate cap of the pending-byte
  budget plus 64 KiB. Frame lengths are checked before accepting their contents.
- WSS additionally caps queued outgoing MQTT bytes and each incoming WebSocket
  frame. A raw-byte budget between complete messages bounds unfinished fragmented
  messages (including frame/control overhead); Dart's frame limit alone does not.
  Compression is disabled. These are separate bounds, not a combined RSS limit.
- Connection attempts have a 60-second total deadline. The raw socket closes even
  if the peer stalls TLS or the HTTP upgrade. Retirement also releases the caller
  of the TLS future, which Dart may leave pending after raw socket closure.
- Open completes after the twin-response subscription is acknowledged, following
  C#. The connection deadline also covers that SUBACK wait. A rejected subscription
  fails open with a protocol error, as explicitly agreed.
- Dart cannot cancel native DNS resolution before `startConnect` returns its task.
  The client serializes that setup, cancels late tasks and closes late sockets.
  Operations and shutdown still settle promptly; recovery can wait for DNS.
- Closing is terminal, cancels pending operations and stops recovery. TLS,
  credential and protocol failures stop automatic recovery and fail pending work;
  a later explicit operation may try again. Network failures retry.
  Desired-patch decoding or synchronous callback failures retire the connection
  and recover its subscriptions, following C#; see [twin notes](twins.md).

Public constructors expose pending-work limits and connection/operation timeouts.
These limits do not provide offline persistence.

## SAS renewal

Shared-key credentials use C#'s one-hour token lifetime and 15% renewal buffer.
When a connection attempt requests credentials, the cache reuses a token outside
that window or signs a fresh one inside it. The threshold is approximately
51 minutes after signing; C#'s expiry rounding and buffer truncation are preserved.

Reaching the renewal window or token expiry does not schedule a disconnect.
If IoT Hub closes the session, ordinary recovery requests credentials again.
No service-side grace period is assumed; see the C# [source mapping](upstream.md).

Fixed SAS bytes are passed unchanged, including after the parser's existing
clock-skew check; the service determines validity. Async providers can acquire
replacement tokens on reconnect, using the returned expiry for caching. Acquisition
shares existing deadlines; see the [authentication contract](upstream.md#internal-authentication-coverage).

## Validation and limits

Controlled tests run the same telemetry and twin suites over local TLS and WSS
peers with explicit CONNACK/PUBACK. A manual clock drives operation, connection,
retry and keepalive timers; socket I/O uses the real event loop. Coverage includes
C# pre-cancellation scenarios, CONNECT fields,
property encoding, byte/count capacity, binary payloads, fragmented packets,
transient retries, authentication refusal, certificate rejection, PINGRESP timeout,
late connection-task cleanup and repeated stalled TLS handshakes. SAS coverage
checks reuse before the renewal window, refresh on reconnect within the window
and after expiry, and preservation of an in-flight send's original deadline.
WSS-specific cases cover upgrade headers, binary/masked frames, fragmentation,
invalid upgrade responses, oversized frames, queued writes, close during an active
write and stalled HTTP upgrade cleanup. Late native setup cleanup runs over both
transports. A 70-minute virtual-clock test keeps one active connection without
scheduled renewal disconnects; its local peer does not enforce service-side token expiry.

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
On 24 October 2026, the user also ran `test/integration/websocket_test.dart` and
reported `+1: All tests passed!`. This confirms WSS setup, SAS authentication,
twin-response subscription, telemetry PUBACK and twin GET on port 443. The test
passed after adding `iothub-no-client-cert=true`; the preceding run disconnected
while awaiting CONNACK. The underlying certificate-negotiation mechanism was not
captured, so it remains an inference. Live WSS reconnect and long-running recovery
remain unverified.

Controlled regressions cover mixed-case hostnames and independently decode the
outgoing CONNECT frame to verify masking and the complete MQTT payload.
The internal client retains a bounded diagnostic snapshot:
attempt count, connection stage, failure category, HTTP status and WebSocket close
code. It excludes endpoints, device identities, credentials, response bodies,
WebSocket close reasons and raw exception text.
The public device API keeps these mutable diagnostics internal. Live tests now use
the public import; that migration has not yet been rerun against Azure.
The live SAS expiry test is deferred.
