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
telemetry and twin retrieval coverage are listed below. Public device APIs,
reported-property updates and desired-property recovery remain unimplemented.

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
  disconnects. This takes priority over PSW-252's proactive-renewal requirement.
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
- Use `cancellation_token` internally for cooperative cancellation. Keep package
  types out of the public SDK API; review how callers request cancellation once
  the client works end to end. A future wrapper cannot itself stop MQTT work;
  the SDK still owns cleanup, deadlines and late-completion handling.
- PSW-252 requires twin snapshot reconciliation after reconnect. The inspected C#
  recovery handler restores subscriptions; our supported recovery flow must also
  subscribe, fetch a snapshot and reconcile buffered notifications by `$version`,
  following the [IoT Hub contract](https://learn.microsoft.com/en-us/azure/iot-hub/iot-hub-devguide-device-twins#device-reconnection-flow).
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
with deterministic timers. No cancellation types have been exported.

## Internal authentication coverage

All C# paths below are relative to `iothub/device/` at the pinned commit.

| Responsibility | C# source | Dart implementation / tests |
| --- | --- | --- |
| Connection-string parsing and validation | `src/Authentication/IotHubConnectionStringBuilder.cs`, `src/Common/Extensions/CommonExtensions.cs`, `tests/Authentication/IotHubConnectionStringBuilderTests.cs` | [Parser](../lib/src/authentication/iot_hub_connection_string.dart), [adapted tests](../test/authentication/iot_hub_connection_string_test.dart) |
| Device/policy token scope | `src/Authentication/DeviceAuthenticationWithSakRefresh.cs`, `src/Authentication/IotHubConnectionString.cs` | `IotHubConnectionString.createSasToken`; independent HMAC vectors in the parser tests |
| Token signing, expiry and external tokens | `src/Common/Security/SharedAccessSignatureBuilder.cs`, `SharedAccessSignature.cs`, `SharedAccessSignatureConstants.cs`, `StringValidationHelper.cs` in the same directory | [SAS implementation](../lib/src/authentication/shared_access_signature.dart), [tests](../test/authentication/shared_access_signature_test.dart) |
| Fixed expiry example | `tests/Authentication/HsmAuthentication/SasTokenBuilderTest.cs` | `TestBuildExpiry_ShouldReturnExpireOn` in the SAS tests |
| Cached token, refresh threshold and device defaults | `src/Authentication/AuthenticationWithTokenRefresh.cs`, `DeviceAuthenticationWithTokenRefresh.cs` in the same directory; matching files in `tests/Authentication/` with `Tests.cs` suffix | [SAS cache](../lib/src/authentication/sas_token_cache.dart), [adapted tests](../test/authentication/sas_token_cache_test.dart) |
| Credential requests on MQTT CONNECT; fixed SAS passthrough | `src/Authentication/IotHubConnectionString.Core.cs`, `src/Transport/Mqtt/MqttIotHubAdapter.cs` | `DeviceClient._connect`; reconnect and fixed-token cases in the [TLS tests](../test/transport/device_client_test.dart) |

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
It calculates the buffer from the whole seconds remaining after signing, with
C#'s single-precision arithmetic and integer truncation. Credential requests before
the threshold reuse the token; requests at or after it sign again. SAS timestamps
use wall-clock time, independently of each operation's existing deadline.
There is no renewal timer and no assumed service-side grace period.

The named cache tests adapt upstream initial-property, cached-token, concurrent
request and invalid-argument scenarios. Synchronous signing within a Dart isolate
needs no semaphore: queued callers share one cached result. There is no async
provider abstraction yet. Additional tests cover threshold equality, fractional
expiry, buffer rounding and unchanged external tokens after expiry.

Errors use Dart `FormatException` without the input as its source. Diagnostic
`toString()` methods redact credentials, as required by PSW-252; they do not provide
C#'s connection-string serialization. These classes are internal and unexported.
External token replacement, provider callbacks and public error types remain to be
implemented. Transport authentication is covered below. The protocol reference is Microsoft's
[SAS authentication contract](https://learn.microsoft.com/en-us/azure/iot-hub/authenticate-authorize-sas).

## Internal TLS telemetry coverage

All C# paths below are relative to `iothub/device/` at the pinned commit.

| Responsibility | C# source | Dart implementation / tests |
| --- | --- | --- |
| CONNECT identity, credentials, persistent session, keepalive and CONNACK mapping | `src/Transport/Mqtt/MqttIotHubAdapter.cs`, `src/Transport/Mqtt/ClientSettings/MqttTransportSettings.cs`, `src/Common/Api/ClientApiVersionHelper.cs` | [Device client](../lib/src/device_client.dart), [MQTT adapter](../lib/src/transport/mqtt_transport.dart), [TLS tests](../test/transport/device_client_test.dart) |
| Telemetry topic, system/application properties and byte limits | `MqttIotHubAdapter.PopulateMessagePropertiesFromMessage`, `src/Common/UrlEncodedDictionarySerializer.cs`, `src/Common/Utils.cs` | [Message](../lib/src/telemetry_message.dart), [property tests](../test/telemetry_message_test.dart), binary wire tests in the TLS suite |
| Retry parameters and transient/security failure classification | `src/Pipeline/RetryDelegatingHandler.cs`, `src/Pipeline/ErrorDelegatingHandler.cs`, `src/RetryPolicies/ExponentialBackoff.cs`, `src/TransientFaultHandling/ExponentialBackoffRetryStrategy.cs` | Internal recovery uses 100 ms minimum, 100 ms delta with 80–120% jitter, and a 10 s cap; controlled refusal/disconnect/TLS tests |
| Pre-cancelled open/send and username without model ID | `tests/Transport/Mqtt/MqttTransportHandlerTests.cs`, `tests/Transport/Mqtt/MqttIotHubAdapterTest.cs` | Named adapted cases in the TLS suite, retaining MIT notices |

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

Caller cancellation types remain internal. Authentication, TLS and protocol
failures are redacted and non-retryable for the current work; network failures and
CONNACK server-unavailable are retryable. Native task/socket cleanup, connection
bounds and queue limits adapt C#'s threading mechanics to Dart; see the
[transport notes](telemetry-transport.md) for test scope and outstanding validation.

## Internal twin retrieval coverage

| Responsibility | C# source at the pinned commit | Dart implementation / tests |
| --- | --- | --- |
| Subscribe on open, GET topic, UUID, response correlation, 60-second response wait and status handling | `iothub/device/src/Transport/Mqtt/MqttTransportHandler.cs`: `OpenInternalAsync`, `SubscribeTwinResponsesAsync`, `SendTwinGetAsync`, `SendTwinRequestAsync` | [Device client](../lib/src/device_client.dart), [response parsing](../lib/src/twin.dart), [TLS tests](../test/transport/twin_get_test.dart) |
| PUBACK and SUBACK completion | `iothub/device/src/Transport/Mqtt/MqttIotHubAdapter.cs`: `SendMessageAsync`, `ProcessSubAck` | GET waits for PUBACK and the correlated response in either order; failed SUBACK follows the agreed deviation above |
| Timeout retry and throttling | `iothub/device/src/Pipeline/ErrorDelegatingHandler.cs`, `RetryDelegatingHandler.cs` | Transport response timeouts and 429 retry within the unchanged operation deadline; other service errors, including 5xx, are non-retryable |
| Desired/reported collections and default values | `shared/src/TwinProperties.cs`, `TwinCollection.cs` in the same directory | Internal `TwinProperties`; [JSON tests](../test/twin_test.dart) preserve metadata, versions, nested values and ISO-looking strings |
| Open subscription, GET pre-cancellation, happy path, service failure and timeout | `iothub/device/tests/Transport/Mqtt/MqttTransportHandlerTests.cs` | Named adaptations in the TLS suite; the timeout case includes the outer client's retry behavior |

The public twin model is not settled. This increment returns the properties
section through an internal type. It does not implement C#'s dynamic collection
API, reported-property updates or desired-property notifications. Malformed JSON
errors omit device properties. See [twin retrieval notes](twin-retrieval.md) for
bounded response storage and remaining live validation.

## Upstream maintenance

Before a package release, check stable C# releases and changes affecting the mapped
features since this commit. Review relevant current C SDK LTS fixes and Python
regression tests as supplementary references. Record adopted fixes, intentional
deviations and their Dart tests; update the baseline only after reviewing the diff.
Preserve upstream MIT copyright and licence notices when adapting code or tests.
