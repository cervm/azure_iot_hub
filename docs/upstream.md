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

These are reference points, not implemented Dart coverage yet.

| Behaviour | C# reference at the pinned commit | Dart coverage to add |
| --- | --- | --- |
| Default timeout and caller-token precedence | [DeviceClient.cs](https://github.com/Azure/azure-iot-sdk-csharp/blob/7a99b886e81158a31bd6a47f86a32393dcc1c73b/iothub/device/src/DeviceClient.cs), [InternalClient.cs](https://github.com/Azure/azure-iot-sdk-csharp/blob/7a99b886e81158a31bd6a47f86a32393dcc1c73b/iothub/device/src/InternalClient.cs) | Default deadline, timeout with a caller token, explicit cancellation, timeout classification |
| Implicit open, retries, reconnect and shutdown | [RetryDelegatingHandler.cs](https://github.com/Azure/azure-iot-sdk-csharp/blob/7a99b886e81158a31bd6a47f86a32393dcc1c73b/iothub/device/src/Pipeline/RetryDelegatingHandler.cs) | Offline send, cancellation during retry, close during recovery, late callbacks |
| MQTT cancellation, twin responses and timeouts | [MqttTransportHandlerTests.cs](https://github.com/Azure/azure-iot-sdk-csharp/blob/7a99b886e81158a31bd6a47f86a32393dcc1c73b/iothub/device/tests/Transport/Mqtt/MqttTransportHandlerTests.cs) | Adapt relevant cancellation, twin-get and twin-patch cases |

## Verified behaviour and decisions

- C# sends implicitly open the connection and retry transient failures. The
  operation token is linked to client shutdown; reconnect has its own lifetime.
- C# uses a four-minute default operation timeout. Supplying a cancellation token
  bypasses that default. Setting the global timeout to zero also disables it.
- **Agreed Dart deviation:** always enforce a finite operation timeout, even with
  a caller token. Retain the four-minute default. One deadline covers the entire
  operation, including connection waits and retries; reconnect must not restart it.
  A caller token may cancel earlier. Do not support disabling the timeout with
  zero. Test timeout/cancellation/acknowledgement races and distinguish their outcomes.
- Begin by evaluating `cancellation_token` for cooperative cancellation. A wrapper
  around a future cannot itself stop MQTT work. Verify cleanup, linked cancellation
  and late-completion races before adopting the dependency in production code.
- A future package replacement is a public API consideration if dependency types
  are exposed. Decide that boundary before publishing the cancellation API.
- PSW-252 requires twin snapshot reconciliation after reconnect. The inspected C#
  recovery handler restores subscriptions; our supported recovery flow must also
  subscribe, fetch a snapshot and reconcile buffered notifications by `$version`,
  following the [IoT Hub contract](https://learn.microsoft.com/en-us/azure/iot-hub/iot-hub-devguide-device-twins#device-reconnection-flow).
- Pending work and transport resources must remain bounded even when callers
  cancel or acknowledgements never arrive. Cancellation after submission must
  preserve delivery uncertainty.

## Upstream maintenance

Before a package release, check stable C# releases and changes affecting the mapped
features since this commit. Review relevant current C SDK LTS fixes and Python
regression tests as supplementary references. Record adopted fixes, intentional
deviations and their Dart tests; update the baseline only after reviewing the diff.
Preserve upstream MIT copyright and licence notices when adapting code or tests.
