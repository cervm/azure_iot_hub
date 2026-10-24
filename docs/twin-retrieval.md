# Internal twin retrieval

`DeviceClient.getTwin` opens implicitly and returns `TwinProperties` containing
desired and reported collections. These are internal types, not a published API.
Nested JSON values, strings, nulls, `$version` and `$metadata` are retained.
Missing collections default to empty maps; explicit null remains null, as in C#.

Each connection subscribes to `$iothub/twin/res/#` at QoS 1 and waits for SUBACK
before completing open or submitting operations. This follows C#'s open sequence.
A rejected subscription fails with `OperationFailureReason.protocol`, an agreed
deviation from C# ignoring the SUBACK failure code. The connection deadline also
bounds the subscription wait.

A GET publishes an empty QoS 1 message to `$iothub/twin/GET/?$rid={UUID}`.
Completion requires both PUBACK and a response with the matching `$rid`. An early
response is retained until PUBACK. Unknown, duplicate and obsolete responses
cannot complete another request. Incoming QoS 1 responses are acknowledged.

The pinned C# response policy is preserved: status values below 300 are parsed
as twin properties; 429 retries with exponential backoff; other error statuses,
including 5xx, fail the request. Failures expose the numeric status through the
internal `OperationFailure.statusCode`, without the response body. Invalid JSON
fails only its request with a redacted protocol error.

The 60-second response wait starts after PUBACK. If it expires, the client retries
with a new request ID, matching the C# transport timeout and outer retry pipeline.
The original whole-operation deadline still bounds all waits and retries.
Disconnects restore the response subscription and retry pending GETs with new IDs.

Twin GETs share pending operation/count and byte limits with telemetry. Retained
early-response payload bytes also consume that budget. Cancellation before PUBACK
retains the MQTT reservation until acknowledgement or retirement; after PUBACK it
releases the response waiter immediately. Closing releases all waiters and timers.

Controlled TLS tests cover adapted C# happy paths, pre-cancellation, service failure
and timeout cases, plus ordering, correlation, retry, cancellation and capacity
regressions. The opt-in `test/integration/twin_test.dart` reads a real device twin
without modifying properties; it has not been run against Azure yet.

Reported-property updates, desired-property subscriptions and reconnect snapshot
reconciliation remain subsequent work. The [upstream mapping](upstream.md) records
the pinned implementation. The wire contract is documented in Microsoft's
[MQTT twin retrieval guide](https://learn.microsoft.com/en-us/azure/iot-hub/iot-mqtt-connect-to-iot-hub#retrieve-device-twin-properties).
