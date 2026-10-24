# Internal telemetry transport

The unexported `DeviceClient` now supports connection strings, SAS authentication,
implicit open and QoS 1 telemetry over TLS on port 8883. A successful send means
PUBACK arrived; cancellation or failure after submission reports unknown delivery.
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
- Dart cannot cancel native DNS resolution before `startConnect` returns its task.
  The client serializes that setup, cancels late tasks and closes late sockets.
  Operations and shutdown still settle promptly; recovery can wait for DNS.
- Closing is terminal, cancels pending operations and stops recovery. TLS,
  credential and protocol failures stop automatic recovery and fail pending work;
  a later explicit operation may try again. Network failures retry.

Queue defaults and connection bounds are internal tuning values, not a published
configuration contract. There is no offline persistence.

## Validation and limits

Controlled tests use a local TLS peer and explicit CONNACK/PUBACK. A manual clock
drives operation, connection, retry and keepalive timers; socket I/O uses the real
event loop. Coverage includes C# pre-cancellation scenarios, CONNECT fields,
property encoding, byte/count capacity, binary payloads, fragmented packets,
transient retries, authentication refusal, certificate rejection, PINGRESP timeout,
late connection-task cleanup and repeated stalled TLS handshakes.

Controlled tests validated on macOS ARM64 with FVM Dart 3.13.5. Linux ARM64, native
DNS/TCP blackholes and long-running resource usage remain unverified. The late-DNS test
controls task delivery; it does not emulate an operating-system DNS blackhole.
The test certificate expires in October 2027; regeneration is documented beside it.

On 24 October 2026, the user ran the opt-in integration test against Azure IoT Hub
and reported `+1: All tests passed!`. This confirms SAS authentication, MQTT/TLS
connection and one QoS 1 publish through PUBACK. Live reconnect, token renewal and
downstream routing/consumption require separate validation.

Token renewal/replacement, WSS, twins and public API design remain subsequent
work. Each new connection signs a fresh token for key credentials. External SAS
bytes are passed unchanged, including the parser's existing clock-skew allowance;
the service determines validity. Connected sessions have no proactive renewal yet.
