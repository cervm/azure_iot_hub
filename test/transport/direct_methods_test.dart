// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license; see third_party/azure-iot-sdk-csharp-LICENSE.
// Named cases adapt DeviceClientTests and MqttTransportHandlerTests.
// See docs/upstream.md for source mappings and additional Dart lifecycle cases.
import 'dart:async';
import 'dart:convert';

import 'package:azure_iot_hub/azure_iot_hub.dart';
import 'package:azure_iot_hub/src/internal_client.dart';
import 'package:test/test.dart';

import '../prototype/support/manual_time.dart';
import '../prototype/support/mqtt_peer.dart';
import 'support/device_test_support.dart';

int controlId(Packet packet) => (packet.body[0] << 8) | packet.body[1];

Future<int> methodControl(MqttPeer peer, {bool subscribe = true}) async {
  final packet = await peer.nextPacket(subscribe ? 8 : 10);
  final length = (packet.body[2] << 8) | packet.body[3];
  expect(
    utf8.decode(packet.body.sublist(4, 4 + length)),
    r'$iothub/methods/POST/#',
  );
  if (subscribe) expect(packet.body.last, 1);
  return controlId(packet);
}

Future<void> invoke(
  MqttPeer peer, {
  String name = 'test',
  String rid = 'abc123',
  String body = '{}',
  int qos = 0,
}) => peer.publish(
  '${r'$iothub/methods/POST/'}$name/?${r'$rid='}$rid',
  utf8.encode(body),
  qos: qos,
);

Future<Packet> response(
  MqttPeer peer, {
  int status = 200,
  String rid = 'abc123',
  String body = '',
  bool acknowledge = true,
}) async {
  final packet = await peer.nextPacket(3);
  expect(packet.topic, '${r'$iothub/methods/res/'}$status/?${r'$rid='}$rid');
  expect((packet.header >> 1) & 3, 1);
  expect(
    utf8.decode(packet.body.sublist(utf8.encode(packet.topic).length + 4)),
    body,
  );
  if (acknowledge) await peer.puback(packet.packetId);
  return packet;
}

// A QoS 1 twin notification proves prior incoming bytes were dispatched, without
// relying on sleeps or inventing a service response for a method invocation.
Future<void> barrier(MqttPeer peer) async {
  await peer.publish(r'$iothub/twin/res/200/?$rid=unknown', [], id: 60000);
  expect(controlId(await peer.nextPacket(4)), 60000);
}

void main() {
  for (final transport in MqttTransportType.values) {
    group(transport.name, () => transportTests(transport));
  }
}

void transportTests(MqttTransportType transport) {
  late MqttPeerServer server;
  late ManualTime time;
  late InternalClient client;

  setUp(() async {
    server = await switch (transport) {
      .tcp => MqttPeerServer.startTls(serverContext()),
      .webSocket => MqttPeerServer.startWebSocket(serverContext()),
    };
    time = ManualTime();
    client = InternalClient(
      credentials(),
      transport: transport,
      port: server.port,
      securityContext: clientContext(),
      operationTimeout: const .new(seconds: 10),
      connectionTimeout: const .new(seconds: 5),
      maxPending: 3,
      schedule: time.schedule,
      now: () => epoch.add(time.elapsed),
      randomInt: (_) => 20,
    );
  });

  tearDown(() async {
    await client.close();
    await server.close();
    expect(client.pendingCount, 0);
    expect(client.pendingBytes, 0);
    await until(() => client.methodCallCount == 0);
    expect(client.methodCallBytes, 0);
    expect(time.activeTimers, 0);
  });

  Future<MqttPeer> accept() async {
    final peer = await server.nextConnection();
    await peer.nextPacket(1);
    await peer.connack(twinResponses: true);
    return peer;
  }

  Future<MqttPeer> register(
    MethodCallback handler, {
    bool fallback = false,
  }) async {
    final registering = fallback
        ? client.setMethodDefaultHandler(handler)
        : client.setMethodHandler('test', handler);
    final peer = await accept();
    await peer.suback(await methodControl(peer));
    await registering;
    return peer;
  }

  test(
    'MqttTransportHandlerEnableMethodsAsyncSubscribesSuccessfully',
    () async {
      var called = false;
      var completed = false;
      final registering = client
          .setMethodHandler('test', (_) async {
            called = true;
            return .new(200);
          })
          .then((_) => completed = true);
      final peer = await accept();
      final id = await methodControl(peer);
      await invoke(peer);
      await barrier(peer);
      expect(called, isFalse);
      expect(completed, isFalse);
      await peer.suback(id + 1);
      await barrier(peer);
      expect(completed, isFalse);
      await peer.suback(id);
      await registering;
      await response(peer);
      expect(called, isTrue);
    },
  );

  for (final fallback in [false, true]) {
    test(
      'DeviceClientSetMethodHandlerSetFirst${fallback ? 'MethodDefault' : 'Method'}Handler',
      () async {
        MethodRequest? received;
        final peer = await register((request) async {
          received = request;
          return .new(201, result: utf8.encode('{"name":"ABC"}'));
        }, fallback: fallback);
        await invoke(peer, body: '{"grade":"good"}');
        await response(peer, status: 201, body: '{"name":"ABC"}');
        expect(received?.name, 'test');
        expect(received?.dataAsJson, '{"grade":"good"}');
      },
    );
  }

  test('DeviceClient_OnMethodCalled_MethodRequestHasEmptyBody', () async {
    final peer = await register((request) async {
      expect(request.data, isEmpty);
      expect(request.dataAsJson, isNull);
      return .new(200);
    });
    await invoke(peer, body: '');
    await response(peer);
  });

  test('DeviceClient_OnMethodCalled_MethodRequestHasInvalidJson', () async {
    var called = false;
    final peer = await register((_) async {
      called = true;
      return .new(200);
    });
    await invoke(peer, body: '{secret');
    await response(peer, status: 400);
    expect(called, isFalse);
    expect(client.isConnected, isTrue);
  });

  test('DeviceClient_OnMethodCalled_MethodResponseHasInvalidJson', () async {
    final peer = await register(
      (_) async => .new(200, result: utf8.encode('{secret')),
    );
    await invoke(peer);
    await response(peer, status: 500);
    expect(client.isConnected, isTrue);
  });

  for (final asynchronous in [false, true]) {
    test(
      'handler ${asynchronous ? 'future' : 'synchronous'} failure returns 500',
      () async {
        final peer = await register(
          asynchronous
              ? (_) async => throw StateError('secret')
              : (_) => throw StateError('secret'),
        );
        await invoke(peer);
        await response(peer, status: 500);
        expect(client.isConnected, isTrue);
      },
    );
  }

  test('DeviceClient_OnMethodCalled_MethodRequestHasValidJson_With_SetMethodHandlerAndDefaultHandler', () async {
    final peer = await register((_) async => .new(201));
    await client.setMethodDefaultHandler((_) async => .new(202));
    await invoke(peer);
    await response(peer, status: 201);
    await invoke(peer, name: 'other');
    await response(peer, status: 202);
    await client.setMethodHandler('test', null);
    await invoke(peer);
    await response(peer, status: 202);
  });

  test('DeviceClientOnMethodCalledNoMethodHandler', () async {
    final peer = await register((_) async => .new(200));
    await invoke(peer, name: 'unknown');
    await response(peer, status: 501);
  });

  test('DeviceClientSetMethodHandlerOverwriteExistingDelegate', () async {
    final peer = await register((_) async => .new(200));
    await client.setMethodHandler('test', (_) async => .new(204));
    await invoke(peer);
    await response(peer, status: 204);
  });

  test(
    'DeviceClientSetMethodHandlerOverwriteExistingDefaultDelegate',
    () async {
      final peer = await register((_) async => .new(200), fallback: true);
      await client.setMethodDefaultHandler((_) async => .new(204));
      await invoke(peer);
      await response(peer, status: 204);
    },
  );

  test('DeviceClientSetMethodHandlerUnsetWhenNoMethodHandler', () async {
    await client.setMethodHandler('test', null);
    await client.setMethodDefaultHandler(null);
    expect(server.peers, isEmpty);
    expect(time.activeTimers, 0);
  });

  test(
    'MqttTransportHandlerDisableMethodsAsyncUnsubscribesSuccessfully',
    () async {
      final peer = await register((_) async => .new(200));
      final removing = client.setMethodHandler('test', null);
      final id = await methodControl(peer, subscribe: false);
      await peer.unsuback(id);
      await removing;
      await invoke(peer);
      await response(peer, status: 501);
      final adding = client.setMethodHandler('test', (_) async => .new(201));
      await peer.suback(await methodControl(peer));
      await adding;
      await invoke(peer);
      await response(peer, status: 201);
    },
  );

  test(
    'removing the default retains named handlers until the last removal',
    () async {
      final peer = await register((_) async => .new(200));
      await client.setMethodDefaultHandler((_) async => .new(201));
      await client.setMethodDefaultHandler(null);
      await invoke(peer, name: 'unknown');
      await response(peer, status: 501);
      await invoke(peer);
      await response(peer);
      final removing = client.setMethodHandler('test', null);
      await peer.unsuback(await methodControl(peer, subscribe: false));
      await removing;
    },
  );

  test(
    'MqttTransportHandlerEnableMethodsAsyncTokenCancellationRequested',
    () async {
      final token = (CancellationTokenSource()..cancel()).token;
      await expectLater(
        client.setMethodHandler(
          'test',
          (_) async => .new(200),
          cancellationToken: token,
        ),
        throwsA(failure(.cancelled, .notSubmitted)),
      );
      await expectLater(
        client.setMethodDefaultHandler(
          (_) async => .new(200),
          cancellationToken: token,
        ),
        throwsA(failure(.cancelled, .notSubmitted)),
      );
      expect(server.peers, isEmpty);
    },
  );

  test(
    'MqttTransportHandlerDisableMethodsAsyncTokenCancellationRequested',
    () async {
      final peer = await register((_) async => .new(200));
      await expectLater(
        client.setMethodHandler(
          'test',
          null,
          cancellationToken: (CancellationTokenSource()..cancel()).token,
        ),
        throwsA(failure(.cancelled, .notSubmitted)),
      );
      await invoke(peer);
      await response(peer);
    },
  );

  test('cancelled registration compensates for a late SUBACK', () async {
    final source = CancellationTokenSource();
    final registering = client.setMethodHandler(
      'test',
      (_) async => .new(200),
      cancellationToken: source.token,
    );
    final checked = expectLater(
      registering,
      throwsA(failure(.cancelled, .unknown)),
    );
    final peer = await accept();
    final id = await methodControl(peer);
    source.cancel();
    await checked;
    expect(client.pendingCount, 1);
    await peer.suback(id);
    await peer.unsuback(await methodControl(peer, subscribe: false));
    await invoke(peer);
    await response(peer, status: 501);
  });

  test(
    'queued registration reuses an acknowledged cancelled subscription',
    () async {
      final source = CancellationTokenSource();
      final first = client.setMethodHandler(
        'test',
        (_) async => .new(200),
        cancellationToken: source.token,
      );
      final checked = expectLater(
        first,
        throwsA(failure(.cancelled, .unknown)),
      );
      final peer = await accept();
      final id = await methodControl(peer);
      source.cancel();
      await checked;
      final second = client.setMethodHandler('test', (_) async => .new(201));
      await peer.suback(id);
      await second;
      await invoke(peer);
      await response(peer, status: 201);
    },
  );

  test('cancelled removal keeps the delegate removed as in C#', () async {
    final peer = await register((_) async => .new(200));
    final source = CancellationTokenSource();
    final removing = client.setMethodHandler(
      'test',
      null,
      cancellationToken: source.token,
    );
    final checked = expectLater(
      removing,
      throwsA(failure(.cancelled, .unknown)),
    );
    final id = await methodControl(peer, subscribe: false);
    source.cancel();
    await checked;
    await invoke(peer);
    await response(peer, status: 501);
    await peer.unsuback(id);
    await peer.suback(await methodControl(peer));
    await client.setMethodHandler('test', (_) async => .new(201));
    await invoke(peer);
    await response(peer, status: 201);
  });

  test(
    'registration cancellation does not cancel an accepted handler',
    () async {
      final source = CancellationTokenSource();
      final completion = Completer<MethodResponse>();
      final registering = client.setMethodHandler(
        'test',
        (_) => completion.future,
        cancellationToken: source.token,
      );
      final peer = await accept();
      await peer.suback(await methodControl(peer));
      await registering;
      await invoke(peer);
      await barrier(peer);
      source.cancel();
      time.elapse(const .new(seconds: 20));
      expect(client.methodCallCount, 1);
      completion.complete(.new(200));
      await response(peer);
    },
  );

  test('MqttTransportHandlerEnableMethodsAsyncSubscribeTimesOut', () async {
    final registering = client.setMethodHandler('test', (_) async => .new(200));
    final checked = expectLater(
      registering,
      throwsA(failure(.timeout, .unknown)),
    );
    final peer = await accept();
    await methodControl(peer);
    time.elapse(const .new(seconds: 10));
    await checked;
    await peer.disconnected;
  });

  test(
    'rejected method SUBACK fails registration with a protocol error',
    () async {
      final registering = client.setMethodHandler(
        'test',
        (_) async => .new(200),
      );
      final checked = expectLater(
        registering,
        throwsA(failure(.protocol, .unknown)),
      );
      final peer = await accept();
      await peer.suback(await methodControl(peer), qos: 128);
      await checked;
      await peer.disconnected;
    },
  );

  test('QoS 1 requests are acknowledged after the response PUBACK', () async {
    final peer = await register((_) async => .new(200));
    await invoke(peer, qos: 1);
    final result = await response(peer, acknowledge: false);
    await peer.puback(result.packetId);
    expect(controlId(await peer.nextPacket(4)), 1);
  });

  test('response sending has a finite deadline', () async {
    final peer = await register((_) async => .new(200));
    await invoke(peer);
    await response(peer, acknowledge: false);
    time.elapse(const .new(seconds: 10));
    await peer.disconnected;
    await until(() => client.methodCallCount == 0);
    expect(client.pendingCount, 0);
  });

  test(
    'reconnect restores desired and method subscriptions before ready',
    () async {
      final completion = Completer<MethodResponse>();
      var calls = 0;
      final peer = await register((_) {
        calls++;
        return completion.future;
      });
      final desired = client.setDesiredPropertyUpdateCallback((_) {});
      await peer.suback(controlId(await peer.nextPacket(8)));
      await desired;
      await invoke(peer);
      await barrier(peer);
      await peer.close();
      await until(() => !client.isConnected && time.activeTimers == 1);
      time.elapse(const .new(milliseconds: 100));
      final next = await accept();
      expect(client.isConnected, isFalse);
      final desiredPacket = await next.nextPacket(8);
      expect(
        utf8.decode(
          desiredPacket.body.sublist(4, desiredPacket.body.length - 1),
        ),
        r'$iothub/twin/PATCH/properties/desired/#',
      );
      await next.suback(controlId(desiredPacket));
      final methodId = await methodControl(next);
      expect(client.isConnected, isFalse);
      completion.complete(.new(200));
      await next.suback(methodId);
      await response(next);
      expect(client.isConnected, isTrue);
      expect(calls, 1);
    },
  );

  test(
    'unacknowledged response retries without invoking the handler again',
    () async {
      var calls = 0;
      final peer = await register((_) async {
        calls++;
        return .new(200, result: utf8.encode('{"ok":true}'));
      });
      await invoke(peer);
      await response(peer, body: '{"ok":true}', acknowledge: false);
      time.elapse(const .new(seconds: 4));
      await peer.close();
      await until(() => !client.isConnected && time.activeTimers == 2);
      time.elapse(const .new(milliseconds: 100));
      final next = await accept();
      await next.suback(await methodControl(next));
      await response(next, body: '{"ok":true}', acknowledge: false);
      expect(calls, 1);
      time.elapse(const .new(milliseconds: 5900));
      await next.disconnected;
      await until(() => client.methodCallCount == 0);
      expect(client.pendingCount, 0);
    },
  );

  test('unfinished handlers are bounded and overload returns 503', () async {
    final completions = List.generate(3, (_) => Completer<MethodResponse>());
    var calls = 0;
    final peer = await register((_) => completions[calls++].future);
    for (var i = 0; i < 3; i++) {
      await invoke(peer, rid: '$i');
    }
    await barrier(peer);
    expect(calls, 3);
    await invoke(peer, qos: 1);
    expect(controlId(await peer.nextPacket(4)), 1);
    await response(peer, status: 503);
    await until(() => client.pendingCount == 0);
    time.elapse(const .new(seconds: 20));
    expect(client.methodCallCount, 3);
    expect(calls, 3);
    for (var i = 0; i < 3; i++) {
      completions[i].complete(.new(200));
      await response(peer, rid: '$i');
    }
    await until(() => client.methodCallCount == 0);
    expect(client.methodCallBytes, 0);
  });

  test(
    'overload with a full response queue drops the request without dispatch',
    () async {
      final completion = Completer<MethodResponse>();
      var calls = 0;
      final peer = await register((_) {
        calls++;
        return completion.future;
      });
      for (var i = 0; i < 3; i++) {
        await invoke(peer, rid: '$i');
      }
      await barrier(peer);
      final sending = List.generate(3, (_) => client.sendEvent(.new([])));
      final packets = <Packet>[];
      for (var i = 0; i < 3; i++) {
        packets.add(await peer.nextPacket(3));
      }
      await invoke(peer, qos: 1);
      expect(controlId(await peer.nextPacket(4)), 1);
      await barrier(peer);
      expect(calls, 3);
      expect(client.pendingCount, 3);
      for (final packet in packets) {
        await peer.puback(packet.packetId);
      }
      await Future.wait(sending);
      completion.complete(.new(200));
      for (var i = 0; i < 3; i++) {
        await response(peer, rid: '$i');
      }
    },
  );

  test('incoming byte capacity rejects before invoking the handler', () async {
    await client.close();
    client = InternalClient(
      credentials(),
      transport: transport,
      port: server.port,
      securityContext: clientContext(),
      maxPendingBytes: 128,
      schedule: time.schedule,
      now: () => epoch.add(time.elapsed),
    );
    var called = false;
    final peer = await register((_) async {
      called = true;
      return .new(200);
    });
    await invoke(peer, body: '"${'a' * 128}"');
    await response(peer, status: 503);
    expect(called, isFalse);
    expect(client.methodCallCount, 0);
  });

  test(
    'close does not await a handler and discards its late failure',
    () async {
      final completion = Completer<MethodResponse>();
      final peer = await register((_) => completion.future);
      await invoke(peer);
      await barrier(peer);
      await client.close();
      await peer.disconnected;
      expect(client.methodCallCount, 1);
      expect(time.activeTimers, 0);
      completion.completeError(StateError('secret'));
      await until(() => client.methodCallCount == 0);
      expect(client.pendingCount, 0);
    },
  );

  test('handler can replace itself and close the client', () async {
    final peer = await register((_) async {
      await client.setMethodHandler('test', (_) async {
        await client.close();
        return .new(200);
      });
      return .new(201);
    });
    await invoke(peer);
    await response(peer, status: 201);
    await invoke(peer);
    await peer.disconnected;
    await until(() => client.methodCallCount == 0);
    expect(client.isConnected, isFalse);
  });

  test('queued cancellation does not remove an existing handler', () async {
    final peer = await register((_) async => .new(200));
    final removing = client.setMethodHandler('test', null);
    final id = await methodControl(peer, subscribe: false);
    final adding = client.setMethodHandler('test', (_) async => .new(201));
    final source = CancellationTokenSource();
    final cancelled = client.setMethodHandler(
      'test',
      null,
      cancellationToken: source.token,
    );
    final checked = expectLater(
      cancelled,
      throwsA(failure(.cancelled, .notSubmitted)),
    );
    source.cancel();
    await checked;
    await peer.unsuback(id);
    await removing;
    await peer.suback(await methodControl(peer));
    await adding;
    await invoke(peer);
    await response(peer, status: 201);
  });

  test('removal during subscription recovery survives cancellation', () async {
    final peer = await register((_) async => .new(200));
    await peer.close();
    await until(() => !client.isConnected && time.activeTimers == 1);
    time.elapse(const .new(milliseconds: 100));
    final next = await accept();
    final id = await methodControl(next);
    final source = CancellationTokenSource();
    final removing = client.setMethodHandler(
      'test',
      null,
      cancellationToken: source.token,
    );
    final checked = expectLater(
      removing,
      throwsA(failure(.cancelled, .notSubmitted)),
    );
    source.cancel();
    await checked;
    await next.suback(id);
    await invoke(next);
    await response(next, status: 501);
  });

  test('cancelled wire exchange does not block a local replacement', () async {
    final peer = await register((_) async => .new(200));
    final source = CancellationTokenSource();
    final removing = client.setMethodHandler(
      'test',
      null,
      cancellationToken: source.token,
    );
    final checked = expectLater(
      removing,
      throwsA(failure(.cancelled, .unknown)),
    );
    final id = await methodControl(peer, subscribe: false);
    source.cancel();
    await checked;
    var registered = false;
    final replacing = client
        .setMethodHandler('test', (_) async => .new(201))
        .then((_) => registered = true);
    await barrier(peer);
    expect(registered, isTrue);
    await replacing;
    await invoke(peer);
    await response(peer, status: 201);
    await peer.unsuback(id);
    await peer.suback(await methodControl(peer));
  });

  test('unfinished handler reservations survive reconnect', () async {
    final completion = Completer<MethodResponse>();
    var calls = 0;
    final peer = await register((_) {
      calls++;
      return completion.future;
    });
    for (var i = 0; i < 3; i++) {
      await invoke(peer, rid: '$i');
    }
    await barrier(peer);
    await peer.close();
    await until(() => !client.isConnected && time.activeTimers == 1);
    time.elapse(const .new(milliseconds: 100));
    final next = await accept();
    await next.suback(await methodControl(next));
    await invoke(next);
    await response(next, status: 503);
    await until(() => client.pendingCount == 0);
    expect(calls, 3);
    expect(client.methodCallCount, 3);
    completion.complete(.new(200));
    for (var i = 0; i < 3; i++) {
      await response(next, rid: '$i');
    }
  });

  test(
    'malformed method topic retires the connection without dispatch',
    () async {
      var called = false;
      final peer = await register((_) async {
        called = true;
        return .new(200);
      });
      await peer.publish(r'$iothub/methods/POST/test/?bad=1', [], qos: 0);
      await peer.disconnected;
      expect(called, isFalse);
      expect(client.methodCallCount, 0);
    },
  );

  test('oversized request and response follow the protocol limit', () async {
    final tooLarge = '"${'a' * (128 * 1024)}"';
    var calls = 0;
    final peer = await register((_) async {
      calls++;
      return .new(200, result: utf8.encode(tooLarge));
    });
    await invoke(peer, body: tooLarge);
    await response(peer, status: 400);
    expect(calls, 0);
    await invoke(peer);
    await response(peer, status: 500);
    expect(calls, 1);
  });

  test('local handler replacement does not need outgoing capacity', () async {
    final peer = await register((_) async => .new(200));
    final sending = List.generate(3, (_) => client.sendEvent(.new([])));
    final packets = <Packet>[];
    for (var i = 0; i < 3; i++) {
      packets.add(await peer.nextPacket(3));
    }
    await client.setMethodHandler('test', (_) async => .new(201));
    await client.setMethodDefaultHandler((_) async => .new(202));
    await client.setMethodDefaultHandler(null);
    for (final packet in packets) {
      await peer.puback(packet.packetId);
    }
    await Future.wait(sending);
    await invoke(peer);
    await response(peer, status: 201);
  });

  test(
    'unsubscription timeout preserves C# local removal through reconnect',
    () async {
      final peer = await register((_) async => .new(200));
      final removing = client.setMethodHandler('test', null);
      final checked = expectLater(
        removing,
        throwsA(failure(.timeout, .unknown)),
      );
      await methodControl(peer, subscribe: false);
      time.elapse(const .new(seconds: 10));
      await checked;
      await peer.disconnected;
      await until(() => time.activeTimers == 1);
      time.elapse(const .new(milliseconds: 100));
      final next = await accept();
      await next.suback(await methodControl(next));
      await invoke(next);
      await response(next, status: 501);
    },
  );
}
