# Twin operations

`DeviceClient.getTwin` opens implicitly and returns `Twin`, with desired and reported
maps at `twin.properties.desired` and `twin.properties.reported`.
Nested JSON values, strings, nulls, `$version` and `$metadata` are retained.
Missing collections default to empty maps; explicit null remains null, as in C#.

`DeviceClient.updateReportedProperties` accepts a JSON-compatible map as a patch.
Null values delete properties, including nested properties; omitted properties are
unchanged. The patch is encoded once on submission, so caller mutation cannot
change queued or retried bytes. This adapts C#'s mutable `TwinCollection` input to
the Dart client's existing byte budget and snapshot semantics. Invalid JSON values
and payloads above C#'s 262,143-byte MQTT limit fail before opening a connection.
IoT Hub enforces its own property-name and twin-size restrictions.

Each connection subscribes to `$iothub/twin/res/#` at QoS 1 and waits for SUBACK
before completing open or submitting operations. This follows C#'s open sequence.
A rejected subscription fails with `OperationFailureReason.protocol`, an agreed
deviation from C# ignoring the SUBACK failure code. The connection deadline also
bounds the subscription wait.

A GET publishes an empty QoS 1 message to `$iothub/twin/GET/?$rid={UUID}`. A PATCH
publishes the encoded JSON to `$iothub/twin/PATCH/properties/reported/?$rid={UUID}`.
Completion requires both PUBACK and a response with the matching `$rid`. An early
response is retained until PUBACK. Unknown, duplicate and obsolete responses
cannot complete another request. Incoming QoS 1 responses are acknowledged.

The pinned C# response policy is preserved: status values below 300 succeed.
GET parses the body as twin properties; PATCH ignores the body, including an empty
204 response. A 429 retries with exponential backoff; other error statuses,
including 5xx, fail the request. Failures expose the numeric status through the
`OperationFailure.statusCode`, without the response body. Invalid JSON
fails only its request with a redacted protocol error.

The 60-second response wait starts after PUBACK. If it expires, the client retries
with a new request ID, matching the C# transport timeout and outer retry pipeline.
The original whole-operation deadline still bounds all waits and retries.
Disconnects restore the response subscription and retry pending requests with new
IDs. PATCH retries retain the original payload. A timed-out or cancelled PATCH
after submission may already have been applied; retries can apply it again and
advance the reported-property version again.

Twin operations share pending count and byte limits with telemetry. Patch payloads
consume the byte budget along with topics and MQTT overhead. Retained
early-response payload bytes also consume that budget. Cancellation before PUBACK
retains the MQTT reservation until acknowledgement or retirement; after PUBACK it
releases the response waiter immediately. Closing releases all waiters and timers.

Controlled TLS and WSS tests cover adapted C# happy paths, pre-cancellation,
service failure and timeout cases for GET and PATCH, plus ordering, correlation,
retry, cancellation, serialization and capacity regressions. The opt-in
`test/integration/twin_test.dart`
reads a real device twin. `test/integration/reported_properties_test.dart` writes a
unique `sdkPatchTest_...` property, verifies nested merge/deletion, and deletes the
property in `finally`. Failed network cleanup may leave that test property behind;
reported-property versions still advance after successful cleanup.

On 24 October 2026, the user ran `reported_properties_test.dart` against Azure
and supplied `00:01 +1: All tests passed!`. This validates reported-property
creation, nested merge/deletion, twin retrieval and final cleanup. A post-test
twin snapshot showed reported `$version` 4 and no test property. The separate
read-only twin test has not been reported as run; twin retrieval is covered by
the successful PATCH test. Live reconnect and expiry/renewal remain unverified.

## Desired-property callbacks

`DeviceClient.setDesiredPropertyUpdateCallback` registers a callback
receiving a JSON map. First registration subscribes to
`$iothub/twin/PATCH/properties/desired/#` at QoS 1 and waits for SUBACK. Replacing
the callback uses the existing subscription. Passing null waits for UNSUBACK
before removing the callback. Registration calls are serialized and share the
client's pending-operation limit and original deadlines.

Callbacks receive each patch with null deletion values, nested JSON, `$version`
and metadata intact. The SDK does not merge patches, deduplicate versions or fetch
snapshots. Reconnect restores the subscription before resuming queued operations.
The application owns snapshot retrieval and version reconciliation, following
Microsoft's [device reconnection flow](https://learn.microsoft.com/en-us/azure/iot-hub/iot-hub-devguide-device-twins#device-reconnection-flow).

As in the pinned C# dispatcher, callback invocation precedes PUBACK, but asynchronous
application work is not awaited. Applications must handle errors from that work.
Malformed JSON or a synchronous callback exception retires the connection without
acknowledging the notification; recovery restores the subscription. Closing inside
a callback stops I/O immediately and defers MQTT stream disposal until dispatch
returns. No property values or callback exception contents are logged.

Cancellation leaves the last successful callback registration in place. An
outstanding SUBSCRIBE or UNSUBSCRIBE retains its reservation until ACK, retirement
or the original deadline. If a late ACK changed the wire subscription, the client
restores the committed registration with a bounded exchange. Background recovery
uses the connection deadline.

**Agreed C# defect correction:** the pinned `InternalClient` never clears
`_twinPatchSubscribedWithService` after disabling notifications. Re-registering can
therefore skip SUBSCRIBE. Dart tracks acknowledged subscription state and subscribes
again after removal. Rejected SUBACKs follow the existing protocol-error policy.

Controlled TLS and WSS tests adapt C# registration, replacement, removal, callback
and cancellation/timeout cases. Additional cases cover reconnect without GET,
repeated versions, asynchronous callback work, cancellation races, missing acknowledgements,
callback failures and shutdown. The opt-in
[`desired_properties_test.dart`](../test/integration/desired_properties_test.dart)
prompts for two portal edits to verify delivery before and after callback removal
and re-registration. It requires `AZURE_IOT_RUN_MANUAL_DESIRED=1`, independently of
the automatic integration-test flag. The operator deletes the temporary desired
property afterward by setting it to `null` in the portal and saving, following
the [portal twin-editing instructions](https://learn.microsoft.com/en-us/azure/iot-hub/manage-device-twins#view-and-update-device-twins).
This test does not exercise reconnect recovery.

On 24 October 2026, the user ran the manual desired-property test against Azure
and supplied `00:51 +1: All tests passed!`. Both requested patches arrived with
integer versions, and the second version was greater than the first. This validates
live delivery before and after callback removal and re-registration. Portal cleanup
is manual and was not verified by the test; live reconnect remains unverified.

The [upstream mapping](upstream.md) records the pinned implementation. The wire contract is documented in Microsoft's
[MQTT twin guide](https://learn.microsoft.com/en-us/azure/iot-hub/iot-mqtt-connect-to-iot-hub#update-device-twins-reported-properties).
