# Testing

Run commands from the repository root using the FVM-pinned SDK.

## Local tests

```sh
fvm dart test
```

Normal runs require no Azure credentials and skip real-hub tests. Controlled TLS
and WSS peers cover telemetry, twins, authentication, cancellation, retries,
deadlines, direct methods, C2D messages, connection status and bounded pending work.
Public API tests use only the package's SDK import. See the
[C# source/test mappings](upstream.md).
X.509 tests additionally verify the client chain and MQTT password omission over
both transports, and cover rejected credentials and reconnects. Local WebSocket
peers request certificates during the initial TLS handshake; the opt-in live
test verifies IoT Hub's later certificate negotiation.

## Validation status

Controlled tests passed on macOS ARM64 with Dart 3.13.7 on 26 October 2026 and
the minimum SDK, Dart 3.13.5, on 27 October 2026 (651 passed; 7 live tests skipped).
The maintainer also reported successful Linux ARM64 testing on 27 October 2026.

Live checks as of 25 October 2026:

| Coverage | Result |
| --- | --- |
| SAS telemetry and twin retrieval over TLS/WSS | Passed before the public API migration; repeat through the current API |
| Reported-property updates and desired callbacks over TLS | Passed, including merge/deletion and callback re-registration |
| Direct methods over TLS | Named handler returned 200; default handler returned 501 |
| C2D messages over TLS | Polling and callback delivery passed with explicit completion submission |
| X.509 telemetry and twin retrieval over TLS/WSS | Passed with a self-signed certificate registered by thumbprint; WSS used explicit renegotiation opt-in |

Remaining validation:

- Native runtime: DNS/TCP stalls and long-running resource usage.
- Live lifecycle: reconnect and subscription restoration, SAS expiry/renewal and
  connection-status callbacks.
- Live messaging: direct methods/C2D over WSS, method overload handling and C2D
  service-side completion feedback/redelivery.
- Certificate authentication: CA-signed chains against IoT Hub.

Controlled tests cover the corresponding protocol and lifecycle paths where
applicable. DNS tests inject late task completion; they do not reproduce an
operating-system DNS stall.

## Optional Azure tests

Configure `AZURE_IOT_TEST_DEVICE_CONNECTION_STRING` securely in your environment
for a dedicated test device. Never put credentials in source files, command
arguments or test logs. Run live tests sequentially when sharing a device identity;
simultaneous clients can disconnect each other.

| Test | What it checks |
| --- | --- |
| `telemetry_test.dart` | Sends one event over TLS and waits for PUBACK |
| `websocket_test.dart` | Sends telemetry and retrieves the twin over WSS on port 443 |
| `twin_test.dart` | Reads desired/reported properties without changing them |
| `reported_properties_test.dart` | Creates a temporary reported property, verifies nested merge/deletion and cleans up |

```sh
AZURE_IOT_RUN_INTEGRATION=1 fvm dart test test/integration/telemetry_test.dart
AZURE_IOT_RUN_INTEGRATION=1 fvm dart test test/integration/websocket_test.dart
AZURE_IOT_RUN_INTEGRATION=1 fvm dart test test/integration/twin_test.dart
AZURE_IOT_RUN_INTEGRATION=1 fvm dart test test/integration/reported_properties_test.dart
```

PUBACK confirms hub acknowledgement, not downstream routing or consumption.
The reported-property test writes a unique `sdkPatchTest_...` property and deletes
it in `finally`. It advances the reported version; failed network cleanup may
leave the test property behind.

## Manual desired-property test

With the same connection-string environment variable configured, run:

```sh
AZURE_IOT_RUN_MANUAL_DESIRED=1 fvm dart test test/integration/desired_properties_test.dart --reporter expanded
```

1. At `STEP 1 READY`, add the printed temporary property with numeric value `1`
   inside the device twin's `properties.desired` in Azure Portal and save.
2. At `STEP 2 READY`, change that property's value to `2` and save again.
3. After the test finishes, set the temporary property to `null` and save to delete it.

Each step allows three minutes for the portal edit. The test checks both patches
and increasing versions, with callback removal and re-registration between them.
It does not test reconnect recovery. The device cannot delete desired properties;
the test prints the property name for manual cleanup even on failure.

## Manual direct-method check

Configure `AZURE_IOT_DEVICE_CONNECTION_STRING` for the dedicated test device and run:

```sh
fvm dart run example/direct_methods_example.dart
```

After `READY`, invoke `getStatus` with payload `{}` from the device's **Direct method**
page in Azure Portal. Verify method status `200` and payload `{"ready":true}`.
Invoke an unregistered name to check the default handler returns `501`.
Press Ctrl+C to close. This example changes no device properties; it is a manual
check of service-visible responses, not an automated test or a reconnect test.

## Manual cloud-to-device test

Configure `AZURE_IOT_TEST_DEVICE_CONNECTION_STRING` for a dedicated test device
with no unrelated pending C2D messages, then run:

```sh
AZURE_IOT_RUN_MANUAL_C2D=1 fvm dart test test/integration/cloud_to_device_test.dart --reporter expanded
```

At each `STEP ... READY`, send the printed JSON body as a cloud-to-device message
to that device from Azure Portal. Step 1 uses `receive()`; step 2 uses the callback.
Both verify the body and call `complete(message)`. Each step allows three minutes.
The test changes no twin properties and closes after the second message.

Set `AZURE_IOT_TEST_TRANSPORT=webSocket` to repeat over WSS. This checks delivery
and local PUBACK submission, not service-side feedback or reconnect redelivery.
Failed/interrupted tests can leave messages queued at the hub. Avoid sending
additional messages while a step is pending.

## Optional X.509 test

Use your own device certificate and private key; repository fixtures are public
test data. Register a dedicated X.509 device in IoT Hub whose ID matches the
certificate's subject CN, using its thumbprint or a verified issuing CA as
appropriate. See Microsoft's [certificate authentication guide](https://learn.microsoft.com/en-us/azure/iot-hub/authenticate-authorize-x509).

Configure these environment variables:

| Variable | Value |
| --- | --- |
| `AZURE_IOT_TEST_X509_HOST_NAME` | Hub hostname, such as `name.azure-devices.net` |
| `AZURE_IOT_TEST_X509_DEVICE_ID` | Registered device ID |
| `AZURE_IOT_TEST_X509_CERTIFICATE_PATH` | PEM device certificate followed by any intermediate certificates |
| `AZURE_IOT_TEST_X509_PRIVATE_KEY_PATH` | Matching PEM private key file |
| `AZURE_IOT_TEST_X509_PRIVATE_KEY_PASSWORD` | Optional password for an encrypted key; supply securely |

```sh
AZURE_IOT_RUN_X509_INTEGRATION=1 fvm dart test test/integration/x509_test.dart --reporter expanded
```

To use WebSockets on port 443:

```sh
AZURE_IOT_RUN_X509_INTEGRATION=1 AZURE_IOT_TEST_TRANSPORT=webSocket \
fvm dart test test/integration/x509_test.dart --reporter expanded
```

The WebSocket test explicitly sets `allowLegacyUnsafeRenegotiation = true` on its
dedicated context so IoT Hub can request the client certificate. Dart warns that
this setting is only suitable for known legacy servers; see the
[agreed TLS contract](upstream.md#x509-authentication). The SDK does not enable it
automatically. MQTT/TLS keeps the default setting.

The test sends one telemetry event and retrieves the twin using the public X.509
constructor. It uses platform server roots and makes no twin changes. Certificate
files stay outside this repository. No SAS connection string is used.
