// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license; see third_party/azure-iot-sdk-csharp-LICENSE.
// Adapted from DeviceClientX509AuthenticationE2ETests and TransportSettingsTests.
// See doc/upstream.md for the pinned reference and native Dart adaptations.
import 'dart:convert';
import 'dart:io';

import 'package:azure_iot_hub/azure_iot_hub.dart';
import 'package:azure_iot_hub/src/internal_client.dart';
import 'package:azure_iot_hub/src/transport/mqtt_transport.dart';
import 'package:azure_iot_hub/src/transport/owned_tls_connection.dart';
import 'package:azure_iot_hub/src/transport/owned_websocket_connection.dart';
import 'package:test/test.dart';

import '../prototype/support/manual_time.dart';
import '../prototype/support/mqtt_peer.dart';
import 'support/device_test_support.dart';
import 'support/x509_test_support.dart';

void main() {
  for (final transportType in MqttTransportType.values) {
    group(transportType.name, () {
      late MqttPeerServer server;
      late ManualTime time;
      late InternalClient client;
      late SecurityContext context;

      InternalClient create({SecurityContext? securityContext}) =>
          InternalClient(
            .withX509(
              hostName: 'hub.azure-devices.net',
              deviceId: 'device-1',
              gatewayHostName: '127.0.0.1',
            ),
            securityContext: securityContext ?? context,
            transport: transportType,
            port: server.port,
            operationTimeout: const .new(seconds: 10),
            connectionTimeout: const .new(seconds: 5),
            schedule: time.schedule,
            now: () => epoch.add(time.elapsed),
            randomInt: (_) => 20,
          );

      setUp(() async {
        final startServer = transportType == .tcp
            ? MqttPeerServer.startTls
            : MqttPeerServer.startWebSocket;
        server = await startServer(
          x509ServerContext(),
          requireClientCertificate: true,
        );
        time = ManualTime();
        context = x509ClientContext()
          ..allowLegacyUnsafeRenegotiation = transportType == .webSocket;
        client = create();
      });

      tearDown(() async {
        await client.close();
        await server.close();
        expect(client.pendingCount, 0);
        expect(client.pendingBytes, 0);
        expect(time.activeTimers, 0);
      });

      Future<MqttPeer> accept({int code = 0}) async {
        final peer = await server.nextConnection();
        final connect = await peer.nextPacket(1);
        expect(peer.peerCertificate?.subject, contains('CN=device-1'));
        expect(connect.body[7] & 0x80, 0x80); // Username flag.
        expect(connect.body[7] & 0x40, 0); // Password flag must be absent.
        final fields = <String>[];
        var offset = 10;
        while (offset < connect.body.length) {
          final length = (connect.body[offset] << 8) | connect.body[offset + 1];
          offset += 2;
          fields.add(
            utf8.decode(connect.body.sublist(offset, offset + length)),
          );
          offset += length;
        }
        expect(fields, hasLength(2));
        expect(fields.first, 'device-1');
        expect(
          fields.last,
          startsWith('hub.azure-devices.net/device-1/?api-version=2020-09-30&'),
        );
        await peer.connack(code: code, twinResponses: code == 0);
        return peer;
      }

      test(
        transportType == .tcp
            ? 'X509_Cert_Chain_Install_Test_MqttTcp: presents chain without OS installation'
            : 'presents client certificate chain over WebSockets',
        () async {
          final sending = client.sendEvent(.new([1, 2]));
          final peer = await accept();
          final publish = await peer.nextPacket(3);
          await peer.puback(publish.packetId);
          await sending;
          final getting = client.getTwin();
          final request = await peer.nextPacket(3);
          await peer.puback(request.packetId);
          await respond(peer, requestId(request));
          expect((await getting).desired, isEmpty);
          expect(server.errors, isEmpty);
        },
      );

      test(
        'X509_InvalidDeviceId_Throw_UnauthorizedException_${transportType == .tcp ? 'MqttTcp' : 'MqttWs'}',
        () async {
          // The TLS peer validates the certificate; CONNACK models IoT Hub refusing
          // its association with the requested device identity after that handshake.
          final opening = expectLater(
            client.open(),
            throwsA(failure(.authentication, .notSubmitted)),
          );
          final peer = await accept(code: 5);
          await opening;
          await peer.disconnected;
          time.elapse(const .new(seconds: 10));
          expect(client.connectionDiagnostics.attempts, 1);
        },
      );

      for (final missing in ['certificate', 'private key', 'intermediate']) {
        test('missing $missing cannot connect or escape its deadline', () async {
          await client.close();
          final incomplete = clientContext();
          if (missing == 'private key') {
            incomplete.useCertificateChain(deviceChain);
          } else if (missing == 'intermediate') {
            final chain = await File(deviceChain).readAsString();
            final leaf = chain.substring(
              0,
              chain.indexOf('-----END CERTIFICATE-----') +
                  '-----END CERTIFICATE-----'.length,
            );
            incomplete.useCertificateChainBytes(utf8.encode(leaf));
            incomplete.usePrivateKey(deviceKey);
          }
          client = create(securityContext: incomplete);
          final opening = expectLater(
            client.open(),
            throwsA(
              anyOf(
                failure(.tls, .notSubmitted),
                failure(.timeout, .notSubmitted),
              ),
            ),
          );
          await until(() => client.connectionDiagnostics.failure != null);
          // Some native TLS stacks close TCP without delivering the peer's TLS alert.
          // An ambiguous network close keeps retrying within the original deadline.
          if (client.connectionDiagnostics.failure == 'network') {
            time.elapse(const .new(seconds: 10));
          }
          await opening;
          expect(server.peers, isEmpty);
          // HttpServer suppresses TLS handshake errors from individual clients.
          if (transportType == .tcp) expect(server.errors, isNotEmpty);
        });
      }

      test('server trust remains required with a client certificate', () async {
        await client.close();
        final untrusted = SecurityContext()
          ..useCertificateChain(deviceChain)
          ..usePrivateKey(deviceKey);
        client = create(securityContext: untrusted);
        await expectLater(client.open(), throwsA(failure(.tls, .notSubmitted)));
        expect(server.peers, isEmpty);
      });

      test('a TLS alert after handshake remains terminal and redacted', () async {
        final transport = MqttTransport(
          '127.0.0.1',
          'device-1',
          port: server.port,
          maxBufferedBytes: 1024,
          securityContext: context,
          transport: transportType,
          usingX509: true,
          schedule: time.schedule,
          now: () => epoch.add(time.elapsed),
        );
        try {
          final connecting = expectLater(
            transport.connect('device-1', null),
            throwsA(
              isA<TransportFailure>()
                  .having((e) => e.kind, 'kind', TransportFailureKind.tls)
                  .having(
                    (e) => e.toString(),
                    'redaction',
                    isNot(contains('secret')),
                  ),
            ),
          );
          final peer = await server.nextConnection();
          await peer.nextPacket(1);
          // Inject the native wire error without adding a production test hook.
          final wire =
              // ignore: invalid_use_of_protected_member
              transport.connectionHandler!.connection;
          // A TLS 1.3 alert after native setup is TlsException, not HandshakeException.
          const error = TlsException('secret certificate diagnostic');
          if (wire is OwnedTlsConnection) {
            wire.onFailure(error);
          } else {
            (wire as OwnedWebSocketConnection).onFailure(error);
          }
          await connecting;
          expect(transport.failure?.isTransient, isFalse);
          await peer.disconnected;
        } finally {
          transport.retire();
          await transport.settled;
        }
      });

      test(
        'reconnect reuses the client context without acquiring a SAS token',
        () async {
          final opening = client.open();
          final peer = await accept();
          await opening;
          final sending = client.sendEvent(.new([1]));
          final original = await peer.nextPacket(3);
          await peer.close();
          await until(() => !client.isConnected);
          time.elapse(const .new(milliseconds: 100));
          final recovered = await accept();
          final retried = await recovered.nextPacket(3);
          expect(retried.topic, original.topic);
          await recovered.puback(retried.packetId);
          await sending;
          expect(client.connectionDiagnostics.attempts, 2);
        },
      );

      test('caller cancellation does not stop X509 connection setup', () async {
        final source = CancellationTokenSource();
        final opening = expectLater(
          client.open(cancellationToken: source.token),
          throwsA(failure(.cancelled, .notSubmitted)),
        );
        final peer = await server.nextConnection();
        await peer.nextPacket(1);
        source.cancel();
        await opening;
        await peer.connack(twinResponses: true);
        await until(() => client.isConnected);
        expect(server.peers, hasLength(1));
      });

      test('pre-cancellation does not open a mutual TLS connection', () async {
        final source = CancellationTokenSource()..cancel();
        await expectLater(
          client.open(cancellationToken: source.token),
          throwsA(failure(.cancelled, .notSubmitted)),
        );
        expect(client.connectionDiagnostics.attempts, 0);
      });

      test(
        'connection timeout retires the certificate connection and retries',
        () async {
          final opening = expectLater(
            client.open(),
            throwsA(failure(.timeout, .notSubmitted)),
          );
          final peer = await server.nextConnection();
          await peer.nextPacket(1);
          time.elapse(const .new(seconds: 5));
          await peer.disconnected;
          time.elapse(const .new(milliseconds: 100));
          final retry = await server.nextConnection();
          await retry.nextPacket(1);
          time.elapse(const .new(milliseconds: 4900));
          await opening;
          await client.close();
          await retry.disconnected;
        },
      );

      test(
        'close during certificate connection setup prevents late completion',
        () async {
          final opening = expectLater(
            client.open(),
            throwsA(failure(.closed, .notSubmitted)),
          );
          final peer = await server.nextConnection();
          await peer.nextPacket(1);
          await client.close();
          await opening;
          await peer.disconnected;
          expect(client.isConnected, isFalse);
        },
      );

      test(
        'DeviceClient_NullX509Certificate: requires an explicit context',
        () {
          expect(
            () => InternalClient(
              .withX509(
                hostName: 'hub.azure-devices.net',
                deviceId: 'device-1',
              ),
            ),
            throwsArgumentError,
          );
        },
      );

      test(
        'construction preserves TLS opt-in and the transport default port',
        () async {
          for (final allowed in [false, true]) {
            final supplied = x509ClientContext()
              ..allowLegacyUnsafeRenegotiation = allowed;
            final internal = InternalClient(
              .withX509(
                hostName: 'hub.azure-devices.net',
                deviceId: 'device-1',
              ),
              securityContext: supplied,
              transport: transportType,
            );
            expect(internal.port, transportType == .tcp ? 8883 : 443);
            expect(supplied.allowLegacyUnsafeRenegotiation, allowed);
            await internal.close();
            expect(supplied.allowLegacyUnsafeRenegotiation, allowed);
          }
          expect(server.peers, isEmpty);
        },
      );

      test('public X509 constructor sends and leaves its context reusable after close', () async {
        for (var i = 0; i < 2; i++) {
          final sdk = DeviceClient.withX509(
            hostName: 'hub.azure-devices.net',
            deviceId: 'device-1',
            gatewayHostName: '127.0.0.1',
            securityContext: context,
            transport: transportType,
            port: server.port,
          );
          try {
            final sending = sdk.sendEvent(.new([1]));
            final peer = await accept();
            final publish = await peer.nextPacket(3);
            await peer.puback(publish.packetId);
            await sending;
          } finally {
            await sdk.close();
            expect(
              context.allowLegacyUnsafeRenegotiation,
              transportType == .webSocket,
            );
          }
        }
      });
    });
  }
}
