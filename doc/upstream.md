# C# compatibility reference

For supported features, preserve C# observable behaviour and relevant tests while
using idiomatic Dart. Microsoft's documented IoT Hub protocol contract takes
precedence. Keep intentional differences small, explicit and agreed.

## Baseline

Verified on 24 October 2026:

- Package: `Microsoft.Azure.Devices.Client` **1.42.4**.
- Release tag: [`2026-8-28`](https://github.com/Azure/azure-iot-sdk-csharp/releases/tag/2026-8-28).
- Commit: [`7a99b886e81158a31bd6a47f86a32393dcc1c73b`](https://github.com/Azure/azure-iot-sdk-csharp/tree/7a99b886e81158a31bd6a47f86a32393dcc1c73b).

## Source/test map

These are reference points for the SDK. Public API, dependency, authentication,
telemetry, WSS, twin, direct-method and connection-status coverage are listed below.

| Behaviour | C# reference at the pinned commit | Dart coverage |
| --- | --- | --- |
| Default timeout and caller-token precedence | [DeviceClient.cs](https://github.com/Azure/azure-iot-sdk-csharp/blob/7a99b886e81158a31bd6a47f86a32393dcc1c73b/iothub/device/src/DeviceClient.cs), [InternalClient.cs](https://github.com/Azure/azure-iot-sdk-csharp/blob/7a99b886e81158a31bd6a47f86a32393dcc1c73b/iothub/device/src/InternalClient.cs) | Default deadline, timeout with a caller token, explicit cancellation, timeout classification |
| Implicit open, retries, reconnect and shutdown | [RetryDelegatingHandler.cs](https://github.com/Azure/azure-iot-sdk-csharp/blob/7a99b886e81158a31bd6a47f86a32393dcc1c73b/iothub/device/src/Pipeline/RetryDelegatingHandler.cs) | Offline send, cancellation during retry, close during recovery, late callbacks |
| MQTT cancellation, twin responses and timeouts | [MqttTransportHandlerTests.cs](https://github.com/Azure/azure-iot-sdk-csharp/blob/7a99b886e81158a31bd6a47f86a32393dcc1c73b/iothub/device/tests/Transport/Mqtt/MqttTransportHandlerTests.cs) | Adapted cancellation, twin-get and twin-patch cases |

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

## Public device API

The package exports [DeviceClient](../lib/src/device_client.dart), its message,
twin, method, connection-status, cancellation and failure types, `MqttTransportType`
and `SasTokenProvider`.
`DeviceClient.fromConnectionString` corresponds to C# `CreateFromConnectionString`;
`withTokenProvider` exposes the existing asynchronous credential acquisition.
Named constructors and `Future` methods without an `Async` suffix adapt the API to
Dart. Calls delegate to [InternalClient](../lib/src/internal_client.dart), retaining
the tested retry, deadline and transport behaviour.

**Agreed twin shape:** `getTwin()` returns `Twin` with `properties.desired` and
`properties.reported`, following C# `DeviceClient.GetTwinAsync` and
`shared/src/Twin.cs`. Collections are ordinary Dart maps, preserving `$version`,
`$metadata` and nulls, rather than reproducing `TwinCollection`'s dynamic API.
Only device-visible properties are included. Desired callbacks continue to deliver
patches; no snapshot merging or reconciliation was added.

**Agreed error surface:** retain one `OperationFailure` with `reason`, `delivery`
and optional `statusCode`, rather than exporting a C#-style exception hierarchy.
This is a Dart API adaptation, not a change to retry classification or delivery
uncertainty. Argument and local JSON validation retain Dart's `ArgumentError` and
`FormatException`. MQTT publication-topic validation failures are translated to a
redacted `ArgumentError`, including device IDs containing `+` or `#`; the existing
rejection before submission is unchanged. Credential parser, MQTT types, mutable
diagnostics, pending-work counters and injected clocks/randomness remain internal.

Public construction exposes the existing transport, positive timeout, pending-work,
port and TLS trust options. Defaults remain four minutes per operation, 60 seconds
per connection/twin response wait, 16 pending operations and 4 MiB of pending bytes.
`close()` permanently shuts down the client and is idempotent; it owns cleanup and
requires no separate disposal call.

[Public API tests](../test/device_client_api_test.dart) use the package library to
exercise telemetry, GET/PATCH, desired callbacks, SAS providers, cancellation,
capacity and service failure status over controlled TLS and WSS peers. Lifecycle
races remain covered by the deterministic internal suites. Live validation results
and remaining gaps are maintained in [testing](testing.md#validation-status).

## Connection-status callbacks

`setConnectionStatusChangesHandler` registers one synchronous callback; null removes
it. Registration/replacement does not replay state. Duplicate status/reason pairs
are suppressed, including transitions observed while no handler was registered.
The public enums retain C#'s values with Dart lower-camel-case spelling.

| Transition | Status / reason |
| --- | --- |
| Connection and required subscriptions ready | `connected / connectionOk` |
| Initial transient failure or lost connection with recovery active | `disconnectedRetrying / communicationError` |
| MQTT credential rejection | `disconnected / badCredential` |
| Terminal TLS, protocol or provider failure | `disconnected / communicationError` |
| First explicit close, in any phase | `disabled / clientClose` |

Reconnect reports connected only after response and desired subscriptions have
been restored. Individual cancellation, twin service errors and operation deadlines
do not themselves end shared recovery or emit retry exhaustion. If an unacknowledged
operation's cleanup deadline retires the connection, that actual loss reports
retrying. Provider timeouts also report retrying while serialized acquisition
settles; late results after close cannot emit another status.

MQTT CONNACK cannot distinguish an expired SAS or disabled device from other
authentication failures. The client does not infer `expiredSasToken`,
`deviceDisabled` or `noNetwork`. Its default transient retry policy has no finite
attempt limit, so it does not emit `retryExpired` when an individual caller times
out. Those enum values remain for C# API parity.

**Agreed callback deviation:** status handlers run in their registering Dart Zone.
Synchronous exceptions follow that zone's uncaught-error handling without entering
the SDK retry pipeline. C# invokes the handler directly and lets exceptions propagate
into connection processing. Returned application futures are not awaited.

**Agreed close deviation:** the first close emits `disabled/clientClose` even
before connection or during recovery, and releases the handler after dispatch.
C#'s notification depends on the active transport watcher/recovery path. Repeated
close is silent. State is committed before dispatch so callback-triggered close or
handler replacement cannot be overwritten by an outer notification. No notification
queue or additional timer is introduced.

| Responsibility | Pinned C# reference | Dart coverage |
| --- | --- | --- |
| Enums and registration/deduplication | `iothub/device/src/ConnectionStatus.cs`, `ConnectionStatusChangeReason.cs`, `InternalClient.SetConnectionStatusChangesHandler`, `OnConnectionStatusChanged` | [Status types](../lib/src/connection_status.dart), `InternalClient._changeConnectionStatus` |
| Initial open, recovery, failure classification and close | `iothub/device/src/Pipeline/RetryDelegatingHandler.cs`: `OpenInternalAsync`, `HandleDisconnectAsync`, `HandleConnectionStatusExceptions` | [Internal client](../lib/src/internal_client.dart), controlled TLS/WSS transitions |
| Open notification, null handler, duplicate suppression and connection loss | `iothub/device/tests/DeviceClientTests.cs`: four `DeviceClientOnConnection...` cases | Named adaptations in [status tests](../test/transport/connection_status_test.dart); the synthetic upstream `No_Network` case uses the runtime MQTT `communicationError` here |
| Transient initial-open retry | `iothub/device/tests/Pipeline/RetryDelegatingHandlerTests.cs`: `RetryDelegatingHandler_OpenAsyncRetries` | Named transport adaptation with controlled CONNACK failures |

Dart-specific cases cover subscription recovery, terminal failures, handler Zones,
reentrant send/close/replacement, slow providers, operation cancellation/deadlines,
and late completion after shutdown. [Public API tests](../test/device_client_api_test.dart)
verify exported registration, connection and close notifications.

## MQTT dependency

The package pins the `mqtt_client` fork at
[`29efbfa`](https://github.com/cervm/mqtt_client/commit/29efbfa768dfc23102a07fe159057a898f426810),
based on 10.13.0. It prevents reuse of packet identifiers awaiting protocol
completion, following [MQTT 3.1.1 §2.3.1](https://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html#_Toc398718025)
(MQTT-2.3.1-2 and MQTT-2.3.1-3). It preserves the original 1–32,767 range,
`maxMessageIdentifier`, public singleton and normal allocation sequence.
Exhaustion throws `NoMessageIdentifiersException` before publish/unsubscribe
submission; subscribe retains its existing null/failure behavior. Confirmed
subscriptions retain their local map keys without reserving those IDs against later publishes.

The fork's tests cover QoS 1/2, subscribe/unsubscribe, identifier exhaustion,
acknowledgement reuse and client isolation. Rerun the
[dependency regressions](../test/prototype/mqtt_cancellation_test.dart) when changing
it. That test-only harness uses the original dependency transport; the SDK owns
TLS/WebSocket setup and cleanup through its [transport adapters](telemetry-transport.md).

The harness retains C#'s named
`MqttTransportHandlerOpenAsyncTokenCancellationRequested` and
`MqttTransportHandlerSendEventAsyncTokenCancellationRequested` cases, with Microsoft's
copyright and [MIT licence](../third_party/azure-iot-sdk-csharp-LICENSE). Additional
Dart tests cover deadlines, PUBACK completion, late callbacks, bounded pending work
and packet-ID wrap. [Operation tests](../test/pending_operation_test.dart) cover
shared tokens, shutdown isolation, listener cleanup and terminal races.

A hosted dependency containing this fix is required before publishing to pub.dev.

## SDK-owned cancellation

[CancellationTokenSource](../lib/src/cancellation.dart) owns cancellation;
its `token` is read-only and exposes `isCancellationRequested`. This follows
[.NET's cancellation model](https://learn.microsoft.com/en-us/dotnet/standard/threading/cancellation-in-managed-threads).
Only SDK-owned cancellation types are exported; an internal bridge connects them to the existing
operation lifecycle without exposing dependency types or exceptions.

Cancellation is optional, permanent and idempotent. One token may serve multiple
operations; cancelling it does not stop shared client recovery. Completion,
timeout and client close detach their listeners without cancelling the caller's
token. Submitted work retains delivery uncertainty and its cleanup deadline.
The wrapper owns no timers or native handles and requires no disposal;
timed cancellation, linking and callback registration are outside this small API.

[Public API tests](../test/cancellation_test.dart) cover token identity and state.
The C# cancellation cases and Dart lifecycle tests use these wrappers
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
| Provider failures and connection recovery | `src/Pipeline/ErrorDelegatingHandler.cs`, `src/Transport/Mqtt/MqttIotHubAdapter.cs` | `InternalClient._connect`; [provider lifecycle tests](../test/transport/token_provider_test.dart) over TLS and WSS |
| Credential requests on MQTT CONNECT; fixed SAS passthrough | `src/Authentication/IotHubConnectionString.Core.cs`, `src/Transport/Mqtt/MqttIotHubAdapter.cs` | `InternalClient._connect`; reconnect and fixed-token cases in the [transport tests](../test/transport/device_client_test.dart) |

The named parser cases retain the upstream scenarios for host, device ID, complex
legacy IDs, credentials, policy name, gateway, missing properties and conflicting
credentials. Dart has no thread-local culture setting; its culture case checks
that device ID casing is preserved. Module credentials remain unsupported. The
SAS parser rejects X.509 connection-string flags; certificate authentication uses
the separate [X.509 entry point](#x509-authentication).

Regression cases also cover a valid SAS with an empty `SharedAccessKey=` field.
C#'s `ValidateFormatIfSpecified` skips the empty key and credential selection uses
the SAS. Dart normalizes that key to absent; missing or malformed SAS still fails.

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

The async provider receives the hub hostname and suggested TTL, matching
C#'s `SafeCreateNewToken`. It may choose a different lifetime; the returned token's
expiry controls caching. Acquisition is serialized per client, with eligibility
rechecked after waiting. Waiters retry acquisition after a provider failure rather
than inheriting that failure. Tokens already eligible for refresh cause the next
waiter to acquire again. The provider owns any external resources and I/O timeouts;
there is no shared authentication-object disposal API in this callback model.

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
Provider configuration and SDK failure types are exposed through the public API.
Transport authentication is covered below. The protocol reference is Microsoft's
[SAS authentication contract](https://learn.microsoft.com/en-us/azure/iot-hub/authenticate-authorize-sas).

## X.509 authentication

`DeviceClient.withX509` accepts the hub/device identity, optional gateway and a
required Dart `SecurityContext`. Configure it with the device certificate chain,
private key and trusted server roots before construction. The application owns
loading and renewal; the client retains the same context across reconnects and
leaves it reusable after close. Keep the context unchanged while a client uses it.
The certificate entry point is `withX509`; `fromConnectionString` retains its SAS
semantics. There is no new certificate package or SDK credential wrapper.

Like C#, certificate authentication is performed by TLS. MQTT CONNECT retains the
hub username and device client ID, with no password field or SAS acquisition.
Gateway routing changes the socket destination while preserving the hub identity.
Connection/operation deadlines, cancellation and recovery use the existing paths.
See Microsoft's [MQTT authentication contract](https://learn.microsoft.com/en-us/azure/iot-hub/iot-mqtt-connect-to-iot-hub)
and [mutual TLS support](https://learn.microsoft.com/en-us/azure/iot-hub/iot-hub-tls-support#mutual-tls-support).

**Agreed native adaptation:** C# accepts an `X509Certificate2` plus optional chain
certificates; its `ClientFactory` can install intermediates into the OS certificate
store. Dart loads the chain/key into the supplied context and changes no OS store.
Certificate loading errors remain Dart errors at the application call site.
`SecurityContext` exposes no certificate/key inspection API, so an empty or
incomplete context is detected during connection, not client construction. C#'s
null-certificate case maps to the required public parameter and an internal guard.
Device identity association is left to IoT Hub; the SDK does not parse certificate
subjects or perform a second certificate validation implementation.

Both MQTT/TLS (8883) and secure WebSockets (443) support X.509. As in C#'s
`CreateWebSocketChannelFactory`, the WebSocket request uses `/$iothub/websocket`
and subprotocol `mqtt` with the supplied client certificate. X.509 omits the
SAS-only `iothub-no-client-cert=true` query option. C# restricts its explicit chain
argument to TCP; Dart presents the context's chain over either transport without
OS installation.

**Agreed TLS opt-in:** IoT Hub requests the WebSocket client certificate through
TLS renegotiation. The application must explicitly enable Dart's
[`SecurityContext.allowLegacyUnsafeRenegotiation`](https://api.dart.dev/dart-io/SecurityContext/allowLegacyUnsafeRenegotiation.html)
on a dedicated IoT Hub context. Dart warns that this mechanism should only be used
with known legacy servers at a quiet point in the protocol. The SDK never enables
it or mutates caller TLS settings; normal server certificate verification remains
required. This explicit configuration is a Dart adaptation of C#'s platform TLS
behaviour. A live probe with Dart defaults upgraded to WebSocket but closed before
CONNACK; the same certificate connected with explicit opt-in. SAS retains its
existing query option and does not need this setting.

TLS failures, including a `TlsException` arriving after the initial handshake,
are terminal `.tls` failures; a rejecting MQTT CONNACK is `.authentication`.
A server may close TCP without delivering a TLS alert. Such an ambiguous close
retains the network retry policy and original operation deadline; it can end in
`.timeout`. Tests cover this native-runtime distinction without inferring an
authentication error from every disconnect. Credential details are omitted from
operation failures and connection diagnostics.

| Responsibility | Pinned C# reference | Dart coverage |
| --- | --- | --- |
| Identity, certificate ownership and SAS exclusion | `iothub/device/src/Authentication/DeviceAuthenticationWithX509Certificate.cs`, `IotHubConnectionStringBuilder.cs`; `src/ClientFactory.cs` | [Public constructor](../lib/src/device_client.dart), [identity tests](../test/authentication/iot_hub_connection_string_test.dart) |
| Certificate on TLS and omitted MQTT password | `src/Transport/Mqtt/MqttTransportHandler.cs`: `CreateChannelFactory`, `CreateWebSocketChannelFactory`; `MqttIotHubAdapterFactory.Create`, `MqttIotHubAdapter.ConnectAsync` | [X.509 transport tests](../test/transport/x509_test.dart) verify client certificate, complete chain, CONNECT flags, telemetry and twin retrieval over both transports; [WebSocket tests](../test/transport/websocket_test.dart) verify the upgrade URI and preservation of caller TLS settings |
| Missing certificate, invalid device association and supplied chain | `iothub/device/tests/ClientSettings/TransportSettingsTests.cs`: `DeviceClient_NullX509Certificate`; `e2e/test/iothub/DeviceClientX509AuthenticationE2ETests.cs`: `X509_InvalidDeviceId_Throw_UnauthorizedException_MqttTcp`, `X509_InvalidDeviceId_Throw_UnauthorizedException_MqttWs`, `X509_Cert_Chain_Install_Test_MqttTcp` | Named controlled adaptations; the chain case validates presentation instead of OS-store installation |

Additional cases cover missing key/intermediate, server trust, post-handshake TLS
alerts, context reuse, reconnect, cancellation, finite deadlines and close during
setup over both transports. The tests use public loopback certificates, including
a separate client CA and intermediate. Local WebSocket peers request certificates
in the initial TLS handshake; IoT Hub's later renegotiation is verified by the live
test. No revocation or OS certificate-store options were added.
See [testing](testing.md#validation-status) for live results and remaining coverage.

## Internal MQTT telemetry coverage

All C# paths below are relative to `iothub/device/` at the pinned commit.

| Responsibility | C# source | Dart implementation / tests |
| --- | --- | --- |
| CONNECT identity, credentials, persistent session, keepalive and CONNACK mapping | `src/Transport/Mqtt/MqttIotHubAdapter.cs`, `src/Transport/Mqtt/ClientSettings/MqttTransportSettings.cs`, `src/Common/Api/ClientApiVersionHelper.cs` | [Internal client](../lib/src/internal_client.dart), [MQTT adapter](../lib/src/transport/mqtt_transport.dart), [transport tests](../test/transport/device_client_test.dart) |
| Telemetry topic, system/application properties and byte limits | `MqttIotHubAdapter.PopulateMessagePropertiesFromMessage`, `src/Common/UrlEncodedDictionarySerializer.cs`, `src/Common/Utils.cs` | [Message](../lib/src/telemetry_message.dart), [property tests](../test/telemetry_message_test.dart), binary wire tests over both transports |
| Unsupported incoming publish QoS | `MqttIotHubAdapter.ProcessPublish` | [Transport regression](../test/transport/mqtt_transport_test.dart) rejects QoS 2 before dependency retention or PUBREC; client tests verify terminal protocol failure over both transports |
| Retry parameters and transient/security failure classification | `src/Pipeline/RetryDelegatingHandler.cs`, `src/Pipeline/ErrorDelegatingHandler.cs`, `src/RetryPolicies/ExponentialBackoff.cs`, `src/TransientFaultHandling/ExponentialBackoffRetryStrategy.cs` | Internal recovery uses 100 ms minimum, 100 ms delta with 80–120% jitter, and a 10 s cap; controlled refusal/disconnect/TLS tests |
| Pre-cancelled open/send and username without model ID | `tests/Transport/Mqtt/MqttTransportHandlerTests.cs`, `tests/Transport/Mqtt/MqttIotHubAdapterTest.cs` | Named adapted cases over both transports, retaining MIT notices |

CONNECT follows the pinned C# API version `2020-09-30`, clean session false,
300-second advertised keepalive, 75-second idle checks and a 30-second ping-response
deadline. Product identification names this Dart SDK. Gateway routing changes the
socket destination, not the hub identity used in the username or SAS audience.

Telemetry supports binary payloads, application properties,
message ID, correlation ID, content type and content encoding. Topic serialization
uses `Uri.EscapeDataString` semantics (not SAS's form encoding), preserves null
versus empty property values, and keeps system properties on name collisions.
The trailing property-bag slash and C# MQTT limits (262,143-byte payload,
65,535-byte topic) are retained. The immutable message also enforces Azure's
[256-KiB total-message limit](https://learn.microsoft.com/en-us/azure/iot-hub/iot-hub-devguide-quotas-throttling#other-limits)
at construction, before connection or pending-work reservation. Following the
[service size calculation](https://learn.microsoft.com/en-us/azure/iot-hub/iot-hub-devguide-messages-construct#message-size),
this includes the body, effective system-property values and application-property
names and values after precedence is applied. The existing `$.` system-property
prefix convention also applies to raw properties. UTF-8 byte counts preserve the
existing Unicode support; MQTT percent encoding and topic framing are measured
separately. This adds local service-contract validation to the pinned C# payload
and topic checks.

Incoming publications support QoS 0 and 1, matching the pinned C# adapter.
Unsupported QoS retires the connection with a terminal protocol failure before
dependency dispatch, preventing the separate QoS 2 retention queue from bypassing
the SDK's incoming storage limits.

Caller cancellation uses the SDK-owned wrappers. Authentication, TLS and protocol
failures are redacted and non-retryable for the current work; network failures and
CONNACK server-unavailable are retryable. Native task/socket cleanup, connection
bounds and queue limits adapt C#'s threading mechanics to Dart; see the
[transport notes](telemetry-transport.md) for test scope and outstanding validation.

## Internal secure WebSocket coverage

All C# paths are relative to `iothub/device/` at the pinned commit.

| Responsibility | C# source | Dart implementation / tests |
| --- | --- | --- |
| WSS endpoint, port and MQTT subprotocol | `src/Transport/Mqtt/MqttTransportHandler.cs`: `CreateWebSocketChannelFactory`; `src/Transport/WebSocketConstants.cs` | [WSS connection](../lib/src/transport/owned_websocket_connection.dart), explicit transport selection, port 443 and `/$iothub/websocket` with `mqtt` |
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
setting; SAS retains Dart's default TLS configuration. X.509 uses the
[explicit application opt-in](#x509-authentication) described above. SAS remains
in MQTT CONNECT, with normal server certificate validation. Live telemetry and twin
retrieval passed with this query; see the [validation notes](telemetry-transport.md)
for scope and limits.

## Internal twin operation coverage

| Responsibility | C# source at the pinned commit | Dart implementation / tests |
| --- | --- | --- |
| Subscribe on open, GET topic, UUID, response correlation, 60-second response wait and status handling | `iothub/device/src/Transport/Mqtt/MqttTransportHandler.cs`: `OpenInternalAsync`, `SubscribeTwinResponsesAsync`, `SendTwinGetAsync`, `SendTwinRequestAsync` | [Internal client](../lib/src/internal_client.dart), [response parsing](../lib/src/twin.dart), [transport tests](../test/transport/twin_get_test.dart) |
| PATCH topic, JSON serialization and successful empty response | `iothub/device/src/Transport/Mqtt/MqttTransportHandler.cs`: `SendTwinPatchAsync`, `SendTwinRequestAsync`; `shared/src/TwinCollectionJsonConverter.cs`; `iothub/device/src/JsonSerializerSettingsInitializer.cs` | `updateReportedProperties` and `encodeReportedProperties`; [PATCH transport tests](../test/transport/twin_patch_test.dart) preserve null deletion values and ISO-looking strings, accept empty 204 and upstream's empty 200 |
| PUBACK and SUBACK completion | `iothub/device/src/Transport/Mqtt/MqttIotHubAdapter.cs`: `SendMessageAsync`, `ProcessSubAck` | GET and PATCH wait for PUBACK and the correlated response in either order; failed SUBACK follows the agreed deviation above |
| Timeout retry and throttling | `iothub/device/src/Pipeline/ErrorDelegatingHandler.cs`, `RetryDelegatingHandler.cs` | Transport response timeouts and 429 retry within the unchanged operation deadline; other service errors, including 5xx, are non-retryable |
| Desired/reported collections and default values | `shared/src/TwinProperties.cs`, `TwinCollection.cs` in the same directory | `TwinProperties`; [JSON tests](../test/twin_test.dart) preserve metadata, versions, nested values and ISO-looking strings |
| Open subscription, GET/PATCH pre-cancellation, happy path, service failure and timeout | `iothub/device/tests/Transport/Mqtt/MqttTransportHandlerTests.cs` | Named adaptations in GET/PATCH suites over both transports; timeout cases include the outer client's retry behavior |
| Desired callback registration, replacement and removal | `iothub/device/src/InternalClient.cs`: `SetDesiredPropertyUpdateCallbackAsync`; `iothub/device/tests/DeviceClientTwinApiTests.cs` | `setDesiredPropertyUpdateCallback`; [desired-property transport tests](../test/transport/desired_properties_test.dart) retain first-registration, replacement, unsubscribe and callback case names |
| Desired subscription and dispatch | `MqttTransportHandler.cs`: `EnableTwinPatchAsync`, `DisableTwinPatchAsync`, `HandleIncomingTwinPatchAsync`; `InternalClient.OnReportedStatePatchReceived` | QoS 1 subscription, raw JSON patches and PUBACK after synchronous dispatch; named pre-cancellation/timeout adaptations and Dart lifecycle tests |
| Desired subscription recovery | `RetryDelegatingHandler.HandleDisconnectAsync` | Restores the subscription without GET or version reconciliation; controlled tests cover recovery deadlines and callback-triggered retirement |

The public `Twin` wraps the returned properties and uses Dart maps in place of
C#'s dynamic collection API. PATCH accepts a Dart map of JSON values. To enforce
the existing byte budget, it captures serialized bytes at
submission and reuses them across retries; C# serializes a mutable `TwinCollection`
inside each transport attempt. Invalid JSON diagnostics omit device properties.
See [twin notes](twins.md) for bounded storage and remaining live validation.

The desired callback uses a Dart closure in place of C#'s separate context object.
`InternalClient.OnReportedStatePatchReceived` invokes the user delegate but does
not await its returned Task; Dart likewise acknowledges after synchronous dispatch,
without awaiting application futures. C#'s transport closes on synchronous dispatch
failure, and its retry handler restores subscriptions; the Dart tests preserve that
sequence. The application owns asynchronous work and its error handling.

## Direct methods

The public API follows C#'s `MethodRequest`, `MethodResponse`, `MethodCallback`,
`SetMethodHandlerAsync` and `SetMethodDefaultHandlerAsync`. Dart uses async callbacks
and closures instead of `userContext`. Request/response bytes are copied and exposed
as unmodifiable lists; JSON-string getters retain null for absent/empty bodies.
The module-invocation timeout fields on C# `MethodRequest` are outside the supported
device API. Status is an application-defined integer.

First registration subscribes to `$iothub/methods/POST/#` at QoS 1 and waits for
SUBACK. Named handlers take precedence over the default, and replacement needs no
wire exchange. Removing the last handler waits for UNSUBACK. Unlike desired-property
callbacks, C# removes a method delegate locally before awaiting unsubscribe; Dart
preserves that removal on failure/cancellation, including while reconnect is
restoring the subscription. Failed first registration does not
install a handler. Late ACKs reconcile the acknowledged wire state with the
committed subscription flag. Reconnect restores methods and desired subscriptions
before reporting connected or resuming outgoing work.

Requests are routed using their method name and `$rid`. Empty or valid JSON invokes
the handler; invalid payloads return 400, unmatched names return 501, and handler
exceptions or invalid results return 500. Responses publish at QoS 1 to
`$iothub/methods/res/{status}/?$rid={id}` and complete at PUBACK. Response retries keep
the original request ID and bytes without invoking the handler again. Methods
normally arrive at QoS 0; incoming QoS 1 is also supported and acknowledged after
response completion, as in C#. Malformed method topics retire the connection
without invoking application code. SDK errors exclude payloads and handler
exception contents.

**Protocol constraints:** IoT Hub requires JSON request/response bodies up to
128 KiB; empty bodies remain supported as in C#. Dart validates UTF-8 and standard
JSON, without reproducing Newtonsoft's permissive extensions. The service limit
is enforced even though C#'s generic MQTT payload limit is larger. See Microsoft's
[direct-method contract](https://learn.microsoft.com/en-us/azure/iot-hub/iot-hub-devguide-direct-methods#handle-a-direct-method-on-a-device).

**Agreed lifetime and overload policy:** application handlers have no SDK execution
timeout and may overlap, following C#. Incoming calls have separate `maxPending`
and `maxPendingBytes` budgets (defaults: 16 calls and 4 MiB of payload/topic bytes).
Reservations include requests waiting for registration and remain until handler
execution and response sending settle, including across reconnect. These are work
budgets, not exact process-memory limits. Responses share the existing outgoing
budget and finite operation deadline. Excess incoming calls receive 503 if response
capacity permits; otherwise they are dropped and the cloud caller times out.
Rejected QoS 1 calls are acknowledged as soon as earlier deliveries permit, to
release their payloads.
There is no unbounded incoming queue or forced cancellation of application work.
Registration tokens do not cancel accepted handlers. Close does not await handlers;
late results/errors are consumed without sending or reopening the client.

| Responsibility | Pinned C# reference | Dart coverage |
| --- | --- | --- |
| Request/response data and JSON validation | `iothub/device/src/DirectMethod/MethodRequest.cs`, `MethodResponse.cs`; `src/Common/Utils.cs` | [Types](../lib/src/direct_method.dart), [data tests](../test/direct_method_test.dart) |
| Named/default registration, removal and dispatch | `iothub/device/src/InternalClient.cs`: `SetMethodHandlerAsync`, `SetMethodDefaultHandlerAsync`, `OnMethodCalledAsync`; `iothub/device/tests/DeviceClientTests.cs` | [Internal client](../lib/src/internal_client.dart); named adaptations of first-registration, replacement, removal, empty/invalid JSON, default precedence and missing-handler cases in [transport tests](../test/transport/direct_methods_test.dart) |
| Subscription ACKs, response topic and cancellation | `iothub/device/src/Transport/Mqtt/MqttTransportHandler.cs`; corresponding `MqttTransportHandlerTests.cs` | TLS/WSS subscription, PUBACK and pre-cancellation adaptations in the same transport suite |
| Recovery and response retries | `iothub/device/src/Pipeline/RetryDelegatingHandler.cs`: `EnableMethodsAsync`, `DisableMethodsAsync`, `SendMethodResponseAsync`, `HandleDisconnectAsync` | Subscription restoration, retry correlation and original response deadline tests |

Dart-specific cases cover early requests, cancellation/late-ACK races, handler
failures, incoming count/byte limits, saturated response queues, reentrant callbacks
and close with unfinished application work. [Public API tests](../test/device_client_api_test.dart)
exercise the exported types and both registration methods over TLS and WSS.
Rejected method SUBACKs use the existing protocol-error policy.

## Cloud-to-device messages

`receive({timeout, cancellationToken})` returns one immutable
`CloudToDeviceMessage`, or null when its finite wait expires. The default is the
client's operation timeout, including connection setup and retries. Caller
cancellation remains an `OperationFailure.cancelled`. A registered callback makes
new polling receives return null, following C#. Concurrent polling waits share
the existing pending-operation count limit.

`setReceiveMessageHandler(handler)` subscribes to
`devices/{deviceId}/messages/devicebound/#` at QoS 1 and waits for SUBACK.
Replacement needs no wire exchange. Passing null clears the handler locally
before awaiting UNSUBACK; reconnect restores committed callback subscriptions.
Messages arriving before registration completes are retained within the incoming
budget. Polling leaves its subscription active for the current connection, even
after a receive timeout; a pending/new receive subscribes again after reconnect.

Callbacks follow the existing desired-property style: synchronous dispatch without
awaiting application futures. The application owns asynchronous work, errors and
timeouts. Returning from a callback does not complete the message. Synchronous
dispatch failures retire the connection without acknowledgement. Closing does not
await application work.

`complete(message)` explicitly sends PUBACK. Foreign, already-completed, retired
or out-of-order deliveries fail with `OperationFailure.protocol`; QoS 0 deliveries
cannot be completed. The SDK uses object identity and connection lifetime instead
of exposing C#'s generation-prefixed lock-token string. PUBACK submission has no
service acknowledgement of its own, so success cannot rule out redelivery after
a disconnect. MQTT supports neither abandon nor reject.

**Agreed ordering corrections:** C# `MqttTransportHandler.CompleteAsync` dequeues
before validating the supplied lock token, losing an earlier entry on mismatch.
Its automatic twin/method completion can encounter that same queue behind an
unfinished C2D delivery. Dart validates without consuming earlier entries and
defers automatic PUBACKs until preceding deliveries are ready. Twin/desired
processing and method responses can proceed meanwhile. Explicit completion waiting
behind earlier internal work retains the normal finite timeout and cancellation;
cancellation before submission leaves the delivery available for completion.
This follows [MQTT 3.1.1 §4.6, MQTT-4.6.0-2](https://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html).
The owned transport sends these PUBACKs directly and releases mqtt_client's manual
ACK entries. Its map holds only one entry per packet ID; this adaptation permits
both an original and a duplicate QoS 1 delivery to complete in arrival order, as
in C#'s `OrderedTwoPhaseWorkQueue`. It requires no additional fork change.

**Agreed storage bound:** retained C2D messages and deferred QoS 1 acknowledgements
share a separate incoming `maxPending`/`maxPendingBytes` budget, counting payload
and topic bytes. This includes delivered C2D messages awaiting completion. Immediate
twin/desired acknowledgements need no retained entry. Overflow retires the current
connection without acknowledging excess C2D data; recovery allows unacknowledged
QoS 1 deliveries to be redelivered. QoS 0 has no redelivery guarantee. No messages
are persisted locally, and these work budgets are not exact process-memory limits.
Application references and asynchronous callback work belong to the application.

The message exposes immutable byte payloads, application/system property maps and
message ID, correlation ID, content type and encoding getters. System map keys use
their MQTT wire names; values remain strings rather than C#'s converted date/enum
objects. Unknown system fields are preserved. URL decoding retains literal `+`,
decodes escaped separators and uses the final value for repeated keys. By agreement,
`key` retains null and `key=` retains an empty string; the pinned C# deserializer
collapses both to null. The [IoT Hub MQTT property contract](https://learn.microsoft.com/en-us/azure/iot-hub/iot-mqtt-connect-to-iot-hub#receiving-cloud-to-device-messages)
defines that distinction. Malformed properties fail without exposing their values.

| Responsibility | Pinned C# reference | Dart coverage |
| --- | --- | --- |
| Polling, callback registration/removal and explicit completion | `iothub/device/src/InternalClient.cs`: `ReceiveAsync`, `SetReceiveMessageHandlerAsync`, `OnDeviceMessageReceivedAsync`, `CompleteAsync` | [Public API](../lib/src/device_client.dart), [receive implementation](../lib/src/internal_client_c2d.dart), [public tests](../test/device_client_api_test.dart) |
| Subscription, receive queue, lock generation and ordered completion | `iothub/device/src/Transport/Mqtt/MqttTransportHandler.cs`: `ProcessC2dMessage`, `EnableReceiveMessageAsync`, `DisableReceiveMessageAsync`, `CompleteIncomingMessageAsync`, `CompleteAsync`; `RetryDelegatingHandler.HandleDisconnectAsync` | [Transport tests](../test/transport/cloud_to_device_test.dart) over TLS/WSS |
| Property decoding | `MqttIotHubAdapter.PopulateMessagePropertiesFromPacket`, `src/Common/UrlEncodedDictionarySerializer.cs` | [Message type/parser](../lib/src/cloud_to_device_message.dart), [parser tests](../test/cloud_to_device_message_test.dart) |
| Single receive, timeout, callback replacement/removal and pending deliveries | `e2e/test/iothub/messaging/MessageReceiveE2ETests.cs`: `Message_DeviceReceiveSingleMessage_Mqtt`, `Message_DeviceReceiveMessageOperationTimeout_Mqtt`, `DeviceReceiveMessageUsingCallback_Mqtt`, `DeviceReceiveMessageUsingCallbackUpdateHandler_Mqtt`, `DeviceReceiveMessageUsingCallbackAndUnsubscribe_Mqtt`, `DeviceReceivePendingMessageUsingCallback_Mqtt` | Named controlled adaptations in the transport suite; pre-cancellation also follows `MqttTransportHandlerTests` |

Dart-specific tests cover capacity, stale completions, late SUBACKs, mixed-traffic
acknowledgement order, queued delivery after callback re-registration, reentrant
removal and completion cancellation/deadline/close races. The
[manual live test](testing.md#manual-cloud-to-device-test) exercises polling and
callback delivery through the public API.

## Upstream maintenance

Before a package release, check stable C# releases and changes affecting the mapped
features since this commit. Review relevant current C SDK LTS fixes and Python
regression tests as supplementary references. Record adopted fixes, intentional
deviations and their Dart tests; update the baseline only after reviewing the diff.
Preserve upstream MIT copyright and licence notices when adapting code or tests.
