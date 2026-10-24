# C# compatibility reference

For supported features, preserve C# observable behaviour and relevant tests while
using idiomatic Dart. Microsoft's documented IoT Hub protocol contract takes
precedence. Keep intentional differences small, explicit and agreed.

## Baseline

Verified on 24 October 2026:

- Package: `Microsoft.Azure.Devices.Client` **1.42.4**.
- Release tag: [`2026-8-28`](https://github.com/Azure/azure-iot-sdk-csharp/releases/tag/2026-8-28).
- Commit: [`7a99b886e81158a31bd6a47f86a32393dcc1c73b`](https://github.com/Azure/azure-iot-sdk-csharp/tree/7a99b886e81158a31bd6a47f86a32393dcc1c73b).

## Initial source/test map

These are reference points for the SDK. Prototype, authentication and internal
telemetry, WSS and twin operation coverage are listed below. Public device APIs
remain unimplemented.

| Behaviour | C# reference at the pinned commit | Dart coverage to add |
| --- | --- | --- |
| Default timeout and caller-token precedence | [DeviceClient.cs](https://github.com/Azure/azure-iot-sdk-csharp/blob/7a99b886e81158a31bd6a47f86a32393dcc1c73b/iothub/device/src/DeviceClient.cs), [InternalClient.cs](https://github.com/Azure/azure-iot-sdk-csharp/blob/7a99b886e81158a31bd6a47f86a32393dcc1c73b/iothub/device/src/InternalClient.cs) | Default deadline, timeout with a caller token, explicit cancellation, timeout classification |
| Implicit open, retries, reconnect and shutdown | [RetryDelegatingHandler.cs](https://github.com/Azure/azure-iot-sdk-csharp/blob/7a99b886e81158a31bd6a47f86a32393dcc1c73b/iothub/device/src/Pipeline/RetryDelegatingHandler.cs) | Offline send, cancellation during retry, close during recovery, late callbacks |
| MQTT cancellation, twin responses and timeouts | [MqttTransportHandlerTests.cs](https://github.com/Azure/azure-iot-sdk-csharp/blob/7a99b886e81158a31bd6a47f86a32393dcc1c73b/iothub/device/tests/Transport/Mqtt/MqttTransportHandlerTests.cs) | Adapt relevant cancellation, twin-get and twin-patch cases |

## Verified behaviour and decisions

- C# sends implicitly open the connection and retry transient failures. The
  operation token is linked to client shutdown; reconnect has its own lifetime.
- **Agreed SAS renewal decision:** follow C# MQTT credential caching and refresh
  when a connection requests an eligible token. Do not schedule proactive
  disconnects.
- **Agreed SUBACK deviation:** fail open with a protocol error when the
  twin-response subscription is rejected. C# `MqttIotHubAdapter.ProcessSubAck`
  completes the subscription without checking the failure code; `mqtt_client`
  reports it. Do not report a rejected subscription as a successful open.
- C# uses a four-minute default operation timeout. Supplying a cancellation token
  bypasses that default. Setting the global timeout to zero also disables it.
- **Agreed Dart deviation:** always enforce a finite operation timeout, even with
  a caller token. Retain the four-minute default. One deadline covers the entire
  operation, including connection waits and retries; reconnect must not restart it.
  A caller token may cancel earlier. Do not support disabling the timeout with
  zero. Test timeout/cancellation/acknowledgement races and distinguish their outcomes.
- **Agreed cancellation API:** expose SDK-owned `CancellationTokenSource` and
  read-only `CancellationToken` wrappers, following C#'s source/token split.
  Keep `cancellation_token` private; the SDK owns cleanup, deadlines and
  late-completion handling.
- **Agreed desired-property boundary:** follow C# by delivering patches and
  restoring subscriptions. The device application retrieves snapshots and
  reconciles versions, following the [IoT Hub reconnection flow](https://learn.microsoft.com/en-us/azure/iot-hub/iot-hub-devguide-device-twins#device-reconnection-flow).
  Do not add an automatic snapshot fetch, merged state or reconciliation helper.
- **Agreed C# defect correction:** `InternalClient` does not clear
  `_twinPatchSubscribedWithService` after disabling desired notifications. Dart
  subscribes again when a callback is re-registered after removal, rather than
  reproducing the resulting missed subscription.
  A source review on 24 October 2026 confirmed that Python resets its enabled flag
  on removal and enables the feature again on re-registration; its
  [pipeline](https://github.com/Azure/azure-iot-sdk-python/blob/main/azure-iot-device/azure/iot/device/iothub/pipeline/mqtt_pipeline.py#L532)
  and [tests](https://github.com/Azure/azure-iot-sdk-python/blob/main/tests/unit/iothub/pipeline/test_mqtt_pipeline.py#L783)
  support this correction. Python also clears the flag on disable failure;
  Dart retains the cancellation and acknowledgement rules documented here.
- Pending work and transport resources must remain bounded even when callers
  cancel or acknowledgements never arrive. Cancellation after submission must
  preserve delivery uncertainty.

## Prototype coverage

[mqtt_cancellation_test.dart](../test/prototype/mqtt_cancellation_test.dart) adapts
`MqttTransportHandlerOpenAsyncTokenCancellationRequested` and
`MqttTransportHandlerSendEventAsyncTokenCancellationRequested` from the pinned C#
MQTT suite, retaining their names and pre-cancelled-token scenarios. The adapted
tests carry Microsoft's copyright notice and the
[upstream MIT licence](../third_party/azure-iot-sdk-csharp-LICENSE).

Additional Dart tests cover the agreed timeout deviation, cancellation during
connection/publishing, PUBACK completion, late/duplicate acknowledgements, bounded
pending packets, reconnect without deadline reset, stale disconnect callbacks and
shutdown. These are new tests, not claims of porting C# test coverage wholesale.
See [prototype findings](mqtt-prototype.md) for the dependency fixes and remaining
validation boundaries.

The prototype now uses [PendingOperation](../lib/src/pending_operation.dart) from
the SDK's internal implementation. Its deadline covers retries and survives caller
cancellation while an in-flight packet still needs cleanup. The owner releases
that deadline on acknowledgement or connection retirement. The
[operation tests](../test/pending_operation_test.dart) additionally verify shared
tokens, shutdown isolation, listener cleanup, pre-cancellation and terminal races
with deterministic timers. Dependency cancellation types remain internal.

## SDK-owned cancellation

[CancellationTokenSource](../lib/src/cancellation.dart) owns cancellation;
its `token` is read-only and exposes `isCancellationRequested`. This follows
[.NET's cancellation model](https://learn.microsoft.com/en-us/dotnet/standard/threading/cancellation-in-managed-threads).
Only these SDK types are exported; an internal bridge connects them to the existing
operation lifecycle without exposing dependency types or exceptions.

Cancellation is optional, permanent and idempotent. One token may serve multiple
operations; cancelling it does not stop shared client recovery. Completion,
timeout and client close detach their listeners without cancelling the caller's
token. Submitted work retains delivery uncertainty and its cleanup deadline.
The initial wrapper owns no timers or native handles and requires no disposal;
timed cancellation, linking and callback registration are outside this small API.

[Public API tests](../test/cancellation_test.dart) cover token identity and state.
The existing C# cancellation cases and Dart lifecycle tests now use these wrappers
across telemetry, twin and provider operations over TLS and WSS. Additional
[transport cases](../test/transport/device_client_test.dart) cover shared-source
cancellation, independent operations, reuse after success and listener cleanup
after completion, timeout and close.

## Internal authentication coverage

All C# paths below are relative to `iothub/device/` at the pinned commit.

| Responsibility | C# source | Dart implementation / tests |
| --- | --- | --- |
| Connection-string parsing and validation | `src/Authentication/IotHubConnectionStringBuilder.cs`, `src/Common/Extensions/CommonExtensions.cs`, `tests/Authentication/IotHubConnectionStringBuilderTests.cs` | [Parser](../lib/src/authentication/iot_hub_connection_string.dart), [adapted tests](../test/authentication/iot_hub_connection_string_test.dart) |
| Device/policy token scope | `src/Authentication/DeviceAuthenticationWithSakRefresh.cs`, `src/Authentication/IotHubConnectionString.cs` | `IotHubConnectionString.createSasToken`; independent HMAC vectors in the parser tests |
| Token signing, expiry and external tokens | `src/Common/Security/SharedAccessSignatureBuilder.cs`, `SharedAccessSignature.cs`, `SharedAccessSignatureConstants.cs`, `StringValidationHelper.cs` in the same directory | [SAS implementation](../lib/src/authentication/shared_access_signature.dart), [tests](../test/authentication/shared_access_signature_test.dart) |
| Fixed expiry example | `tests/Authentication/HsmAuthentication/SasTokenBuilderTest.cs` | `TestBuildExpiry_ShouldReturnExpireOn` in the SAS tests |
| Cached token, refresh threshold and device defaults | `src/Authentication/AuthenticationWithTokenRefresh.cs`, `DeviceAuthenticationWithTokenRefresh.cs` in the same directory; matching files in `tests/Authentication/` with `Tests.cs` suffix | [SAS cache](../lib/src/authentication/sas_token_cache.dart), [adapted tests](../test/authentication/sas_token_cache_test.dart) |
| Asynchronous token acquisition, serialization and changed lifetime | `AuthenticationWithTokenRefresh.SafeCreateNewToken` and `GetTokenAsync`; `AuthenticationWithTokenRefreshTests` initial-property, concurrent-update and new-TTL cases | `IotHubConnectionString.withTokenProvider`, [provider tests](../test/authentication/sas_token_provider_test.dart) |
| Provider failures and connection recovery | `src/Pipeline/ErrorDelegatingHandler.cs`, `src/Transport/Mqtt/MqttIotHubAdapter.cs` | `DeviceClient._connect`; [provider lifecycle tests](../test/transport/token_provider_test.dart) over TLS and WSS |
| Credential requests on MQTT CONNECT; fixed SAS passthrough | `src/Authentication/IotHubConnectionString.Core.cs`, `src/Transport/Mqtt/MqttIotHubAdapter.cs` | `DeviceClient._connect`; reconnect and fixed-token cases in the [transport tests](../test/transport/device_client_test.dart) |

The named parser cases retain the upstream scenarios for host, device ID, complex
legacy IDs, credentials, policy name, gateway, missing properties and conflicting
credentials. Dart has no thread-local culture setting; its culture case checks
that device ID casing is preserved. Module and X.509 credentials are explicitly
unsupported in this initial device SAS subset.

Signing preserves C#'s one-hour builder default, `WebUtility.UrlEncode` semantics,
device-ID encoding before audience encoding, hub scope for policy keys and
round-to-even expiry seconds. External tokens retain their original bytes and
expiry. Their parser retains C#'s five-minute clock-skew allowance; that allowance
must not postpone renewal or imply service-side validity after expiry.

The cache uses C#'s one-hour lifetime and 15% buffer; zero requests either default.
It calculates the buffer from the whole seconds remaining after acquisition, with
C#'s single-precision arithmetic and integer truncation. Credential requests before
the threshold reuse the token; requests at or after it acquire a new token. SAS timestamps
use wall-clock time, independently of each operation's existing deadline.
There is no renewal timer and no assumed service-side grace period.

The internal async provider receives the hub hostname and suggested TTL, matching
C#'s `SafeCreateNewToken`. It may choose a different lifetime; the returned token's
expiry controls caching. Acquisition is serialized per client, with eligibility
rechecked after waiting. Waiters retry acquisition after a provider failure rather
than inheriting that failure. Tokens already eligible for refresh cause the next
waiter to acquire again. The provider owns any external resources and I/O timeouts;
there is no shared authentication-object disposal API in this internal callback model.

As in C#, the callback receives no cancellation token. Cancelling one caller leaves
shared acquisition running. Acquisition consumes the existing connection and
operation deadlines; close and caller completion never wait for it. An unresolved
provider remains the only acquisition in flight, even after timeout, preventing
unbounded abandoned callbacks. Once it settles, an expired attempt cannot connect;
recovery may reuse a valid cached result on its next attempt. Closing prevents all
further connection attempts. A provider that never settles therefore blocks that
client's recovery, while operations still time out and close remains prompt.

Following C#'s error pipeline, provider I/O, timeout and cancellation exceptions
are transient; TLS errors and other acquisition/validation failures stop recovery.
Diagnostics retain only the category and authentication stage. Arbitrary provider
exception text is not propagated through client failures.

Named cache/provider tests adapt upstream initial-property, cached-token,
concurrent-update, changed-TTL and invalid-argument scenarios. Deterministic Dart
cases cover slow providers, failed/expired tokens, serialized retries, cancellation,
close, deadline races and reconnect. Existing cases retain threshold equality,
fractional expiry, buffer rounding and unchanged fixed SAS tokens after expiry.

Errors use Dart `FormatException` without the input as its source. Diagnostic
`toString()` methods redact credentials; they do not provide
C#'s connection-string serialization. These classes are internal and unexported.
Provider configuration and public error types remain internal pending API review.
Transport authentication is covered below. The protocol reference is Microsoft's
[SAS authentication contract](https://learn.microsoft.com/en-us/azure/iot-hub/authenticate-authorize-sas).

## Internal MQTT telemetry coverage

All C# paths below are relative to `iothub/device/` at the pinned commit.

| Responsibility | C# source | Dart implementation / tests |
| --- | --- | --- |
| CONNECT identity, credentials, persistent session, keepalive and CONNACK mapping | `src/Transport/Mqtt/MqttIotHubAdapter.cs`, `src/Transport/Mqtt/ClientSettings/MqttTransportSettings.cs`, `src/Common/Api/ClientApiVersionHelper.cs` | [Device client](../lib/src/device_client.dart), [MQTT adapter](../lib/src/transport/mqtt_transport.dart), [transport tests](../test/transport/device_client_test.dart) |
| Telemetry topic, system/application properties and byte limits | `MqttIotHubAdapter.PopulateMessagePropertiesFromMessage`, `src/Common/UrlEncodedDictionarySerializer.cs`, `src/Common/Utils.cs` | [Message](../lib/src/telemetry_message.dart), [property tests](../test/telemetry_message_test.dart), binary wire tests over both transports |
| Retry parameters and transient/security failure classification | `src/Pipeline/RetryDelegatingHandler.cs`, `src/Pipeline/ErrorDelegatingHandler.cs`, `src/RetryPolicies/ExponentialBackoff.cs`, `src/TransientFaultHandling/ExponentialBackoffRetryStrategy.cs` | Internal recovery uses 100 ms minimum, 100 ms delta with 80–120% jitter, and a 10 s cap; controlled refusal/disconnect/TLS tests |
| Pre-cancelled open/send and username without model ID | `tests/Transport/Mqtt/MqttTransportHandlerTests.cs`, `tests/Transport/Mqtt/MqttIotHubAdapterTest.cs` | Named adapted cases over both transports, retaining MIT notices |

CONNECT follows the pinned C# API version `2020-09-30`, clean session false,
300-second advertised keepalive, 75-second idle checks and a 30-second ping-response
deadline. Product identification names this Dart SDK. Gateway routing changes the
socket destination, not the hub identity used in the username or SAS audience.

The initial message subset supports binary payloads, application properties,
message ID, correlation ID, content type and content encoding. Topic serialization
uses `Uri.EscapeDataString` semantics (not SAS's form encoding), preserves null
versus empty property values, and keeps system properties on name collisions.
The trailing property-bag slash and C# MQTT limits (262,143-byte payload,
65,535-byte topic) are retained. Service quotas also account for message properties.

Caller cancellation uses the SDK-owned wrappers. Authentication, TLS and protocol
failures are redacted and non-retryable for the current work; network failures and
CONNACK server-unavailable are retryable. Native task/socket cleanup, connection
bounds and queue limits adapt C#'s threading mechanics to Dart; see the
[transport notes](telemetry-transport.md) for test scope and outstanding validation.

## Internal secure WebSocket coverage

All C# paths are relative to `iothub/device/` at the pinned commit.

| Responsibility | C# source | Dart implementation / tests |
| --- | --- | --- |
| WSS endpoint, port and MQTT subprotocol | `src/Transport/Mqtt/MqttTransportHandler.cs`: `CreateWebSocketChannelFactory`; `src/Transport/WebSocketConstants.cs` | [WSS connection](../lib/src/transport/owned_websocket_connection.dart), explicit internal transport selection, port 443 and `/$iothub/websocket` with `mqtt` |
| Runtime WebSocket I/O and MQTT framing | `src/Transport/Mqtt/ClientWebSocketChannel.cs`; `MqttTransportHandler.CreateWebSocketChannelFactory` | Dart `WebSocket` handles HTTP upgrade/framing; owned TLS socket and the shared MQTT decoder preserve cancellation and bounds |
| Writes before connection and after close | `tests/Transport/Mqtt/ClientWebSocketChannelTests.cs` | Named adaptations in [WSS tests](../test/transport/websocket_test.dart); `WriteAfterCloseTest` is ignored upstream but runs here |

Telemetry, GET, PATCH and desired-property suites now run against both TLS and WSS,
including their existing named C# adaptations. Additional Dart tests cover HTTP
upgrade cleanup, late DNS, frame/fragment limits and closing during an active write.
WebSocket connection errors use the existing transient network classification,
following `ErrorDelegatingHandler`; TLS verification failures remain terminal.
The transport choice corresponds to C#'s `Mqtt_Tcp_Only` and
`Mqtt_WebSocket_Only`. Automatic fallback and proxy configuration are not yet
implemented. The [IoT Hub MQTT contract](https://learn.microsoft.com/en-us/azure/iot-hub/iot-mqtt-connect-to-iot-hub)
confirms MQTT 3.1.1 over secure WebSockets on port 443.

For SAS, the Dart upgrade URI additionally uses `?iothub-no-client-cert=true`.
This is a deliberate transport adaptation from the pinned C# URL. Microsoft
provides this option as `AZ_IOT_HUB_CLIENT_WEB_SOCKET_PATH_NO_X509_CLIENT_CERT`
for devices without client certificates that otherwise fail to connect
([Embedded C source](https://github.com/Azure/azure-sdk-for-c/blob/main/sdk/inc/azure/iot/az_iot_hub_client.h)).
Dart exposes TLS renegotiation only through the explicitly named
[`allowLegacyUnsafeRenegotiation`](https://api.dart.dev/dart-io/SecurityContext/allowLegacyUnsafeRenegotiation.html)
setting; this implementation retains Dart's default TLS configuration. SAS remains
in MQTT CONNECT, with normal server certificate validation. Live telemetry and twin
retrieval passed with this query; see the [validation notes](telemetry-transport.md)
for scope and limits.

## Internal twin operation coverage

| Responsibility | C# source at the pinned commit | Dart implementation / tests |
| --- | --- | --- |
| Subscribe on open, GET topic, UUID, response correlation, 60-second response wait and status handling | `iothub/device/src/Transport/Mqtt/MqttTransportHandler.cs`: `OpenInternalAsync`, `SubscribeTwinResponsesAsync`, `SendTwinGetAsync`, `SendTwinRequestAsync` | [Device client](../lib/src/device_client.dart), [response parsing](../lib/src/twin.dart), [transport tests](../test/transport/twin_get_test.dart) |
| PATCH topic, JSON serialization and successful empty response | `iothub/device/src/Transport/Mqtt/MqttTransportHandler.cs`: `SendTwinPatchAsync`, `SendTwinRequestAsync`; `shared/src/TwinCollectionJsonConverter.cs`; `iothub/device/src/JsonSerializerSettingsInitializer.cs` | `updateReportedProperties` and `encodeReportedProperties`; [PATCH transport tests](../test/transport/twin_patch_test.dart) preserve null deletion values and ISO-looking strings, accept empty 204 and upstream's empty 200 |
| PUBACK and SUBACK completion | `iothub/device/src/Transport/Mqtt/MqttIotHubAdapter.cs`: `SendMessageAsync`, `ProcessSubAck` | GET and PATCH wait for PUBACK and the correlated response in either order; failed SUBACK follows the agreed deviation above |
| Timeout retry and throttling | `iothub/device/src/Pipeline/ErrorDelegatingHandler.cs`, `RetryDelegatingHandler.cs` | Transport response timeouts and 429 retry within the unchanged operation deadline; other service errors, including 5xx, are non-retryable |
| Desired/reported collections and default values | `shared/src/TwinProperties.cs`, `TwinCollection.cs` in the same directory | Internal `TwinProperties`; [JSON tests](../test/twin_test.dart) preserve metadata, versions, nested values and ISO-looking strings |
| Open subscription, GET/PATCH pre-cancellation, happy path, service failure and timeout | `iothub/device/tests/Transport/Mqtt/MqttTransportHandlerTests.cs` | Named adaptations in GET/PATCH suites over both transports; timeout cases include the outer client's retry behavior |
| Desired callback registration, replacement and removal | `iothub/device/src/InternalClient.cs`: `SetDesiredPropertyUpdateCallbackAsync`; `iothub/device/tests/DeviceClientTwinApiTests.cs` | `setDesiredPropertyUpdateCallback`; [desired-property transport tests](../test/transport/desired_properties_test.dart) retain first-registration, replacement, unsubscribe and callback case names |
| Desired subscription and dispatch | `MqttTransportHandler.cs`: `EnableTwinPatchAsync`, `DisableTwinPatchAsync`, `HandleIncomingTwinPatchAsync`; `InternalClient.OnReportedStatePatchReceived` | QoS 1 subscription, raw JSON patches and PUBACK after synchronous dispatch; named pre-cancellation/timeout adaptations and Dart lifecycle tests |
| Desired subscription recovery | `RetryDelegatingHandler.HandleDisconnectAsync` | Restores the subscription without GET or version reconciliation; controlled tests cover recovery deadlines and callback-triggered retirement |

The public twin model is not settled. This increment returns the properties
section through an internal type. It does not implement C#'s dynamic collection
API. PATCH accepts an internal Dart map of JSON
values. To enforce the existing byte budget, it captures serialized bytes at
submission and reuses them across retries; C# serializes a mutable `TwinCollection`
inside each transport attempt. Invalid JSON diagnostics omit device properties.
See [twin notes](twins.md) for bounded storage and remaining live validation.

The desired callback uses a Dart closure in place of C#'s separate context object.
`InternalClient.OnReportedStatePatchReceived` invokes the user delegate but does
not await its returned Task; Dart likewise acknowledges after synchronous dispatch,
without awaiting application futures. C#'s transport closes on synchronous dispatch
failure, and its retry handler restores subscriptions; the Dart tests preserve that
sequence. The application owns asynchronous work and its error handling.

## Upstream maintenance

Before a package release, check stable C# releases and changes affecting the mapped
features since this commit. Review relevant current C SDK LTS fixes and Python
regression tests as supplementary references. Record adopted fixes, intentional
deviations and their Dart tests; update the baseline only after reviewing the diff.
Preserve upstream MIT copyright and licence notices when adapting code or tests.
