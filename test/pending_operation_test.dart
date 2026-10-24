import 'package:azure_iot_hub/src/pending_operation.dart';
import 'package:cancellation_token/cancellation_token.dart';
import 'package:test/test.dart';

import 'prototype/support/manual_time.dart';

Matcher failure(OperationFailureReason reason, DeliveryState delivery) =>
    isA<OperationFailure>()
        .having((error) => error.reason, 'reason', reason)
        .having((error) => error.delivery, 'delivery', delivery);

void main() {
  late ManualTime time;
  late CancellationToken shutdown;
  late CancellationToken caller;
  late List<PendingOperation<int>> operations;
  late int cancellations;
  late int expirations;

  PendingOperation<int> create({
    Duration timeout = const Duration(minutes: 4),
    bool releaseOnCancellation = true,
  }) {
    late final PendingOperation<int> operation;
    operation = PendingOperation<int>(
      timeout: timeout,
      schedule: time.schedule,
      onCancelled: () {
        cancellations++;
        if (releaseOnCancellation) operation.release();
      },
      onTimeout: () {
        expirations++;
        operation.release();
      },
    );
    operations.add(operation);
    return operation;
  }

  setUp(() {
    time = ManualTime();
    shutdown = CancellationToken();
    caller = CancellationToken();
    operations = [];
    cancellations = 0;
    expirations = 0;
  });

  tearDown(() {
    for (final operation in operations) {
      expect(operation.isCompleted, isTrue);
    }
    expect(shutdown.hasCancellables, isFalse);
    expect(caller.hasCancellables, isFalse);
    expect(time.activeTimers, 0);
  });

  for (final withCaller in [false, true]) {
    test(
      'four-minute deadline applies with caller token: $withCaller',
      () async {
        final operation = create();
        final result = expectLater(
          operation.future,
          throwsA(
            failure(OperationFailureReason.timeout, DeliveryState.notSubmitted),
          ),
        );
        expect(
          operation.start(
            shutdown: shutdown,
            cancellationToken: withCaller ? caller : null,
          ),
          isTrue,
        );
        time.elapse(const Duration(minutes: 3, seconds: 59));
        expect(operation.isCompleted, isFalse);
        time.elapse(const Duration(seconds: 1));
        await result;
        expect(expirations, 1);
        expect(caller.isCancelled, isFalse);
        expect(shutdown.isCancelled, isFalse);
      },
    );
  }

  for (final cancelShutdown in [false, true]) {
    test(
      'pre-cancelled ${cancelShutdown ? 'shutdown' : 'caller'} cannot start work',
      () async {
        (cancelShutdown ? shutdown : caller).cancel();
        final operation = create();
        final result = expectLater(
          operation.future,
          throwsA(
            failure(
              cancelShutdown
                  ? OperationFailureReason.closed
                  : OperationFailureReason.cancelled,
              DeliveryState.notSubmitted,
            ),
          ),
        );
        expect(
          operation.start(shutdown: shutdown, cancellationToken: caller),
          isFalse,
        );
        expect(() => operation.markSubmitted(), throwsStateError);
        await result;
        expect(cancellations, 1);
        expect(time.activeTimers, 0);
      },
    );
  }

  test(
    'one caller token cancels multiple operations without cancelling shutdown',
    () async {
      final first = create();
      final second = create();
      final results = [
        for (final operation in [first, second])
          expectLater(
            operation.future,
            throwsA(
              failure(
                OperationFailureReason.cancelled,
                DeliveryState.notSubmitted,
              ),
            ),
          ),
      ];
      first.start(shutdown: shutdown, cancellationToken: caller);
      second.start(shutdown: shutdown, cancellationToken: caller);
      caller.cancel();
      await Future.wait(results);
      expect(cancellations, 2);
      expect(shutdown.isCancelled, isFalse);
    },
  );

  test('shutdown settles a submitted operation without cancelling its caller token', () async {
    final operation = create();
    final result = expectLater(
      operation.future,
      throwsA(failure(OperationFailureReason.closed, DeliveryState.unknown)),
    );
    operation.start(shutdown: shutdown, cancellationToken: caller);
    operation.markSubmitted();
    shutdown.cancel();
    await result;
    expect(caller.isCancelled, isFalse);
    expect(cancellations, 1);
  });

  test(
    'cancelled in-flight work retains its original cleanup deadline',
    () async {
      final operation = create(releaseOnCancellation: false);
      final result = expectLater(
        operation.future,
        throwsA(
          failure(OperationFailureReason.cancelled, DeliveryState.unknown),
        ),
      );
      operation.start(shutdown: shutdown, cancellationToken: caller);
      operation.markSubmitted();
      time.elapse(const Duration(minutes: 1));
      caller.cancel();
      await result;
      expect(time.activeTimers, 1);
      expect(caller.hasCancellables, isFalse);
      expect(shutdown.hasCancellables, isFalse);
      expect(() => operation.markSubmitted(), throwsStateError);
      time.elapse(const Duration(minutes: 3));
      expect(expirations, 1);
      expect(cancellations, 1);
      operation.complete(
        42,
      ); // Late completion cannot replace the cancellation.
      await result;
    },
  );

  test('acknowledgement after cancellation releases the deadline', () async {
    final operation = create(releaseOnCancellation: false);
    final result = expectLater(
      operation.future,
      throwsA(failure(OperationFailureReason.cancelled, DeliveryState.unknown)),
    );
    operation.start(shutdown: shutdown, cancellationToken: caller);
    operation.markSubmitted();
    caller.cancel();
    await result;
    operation.complete(42);
    operation.release();
    time.elapse(const Duration(minutes: 4));
    expect(expirations, 0);
  });

  test(
    'success wins over late cancellation, timeout and duplicate completion',
    () async {
      final operation = create();
      operation.start(shutdown: shutdown, cancellationToken: caller);
      operation.markSubmitted();
      operation.complete(42);
      operation.release();
      caller.cancel();
      shutdown.cancel();
      operation.complete(99);
      time.elapse(const Duration(minutes: 4));
      expect(await operation.future, 42);
      expect(cancellations, 0);
      expect(expirations, 0);
    },
  );

  test('timeout wins over late cancellation and completion', () async {
    final operation = create();
    final result = expectLater(
      operation.future,
      throwsA(failure(OperationFailureReason.timeout, DeliveryState.unknown)),
    );
    operation.start(shutdown: shutdown, cancellationToken: caller);
    operation.markSubmitted();
    time.elapse(const Duration(minutes: 4));
    caller.cancel();
    shutdown.cancel();
    operation.complete(42);
    await result;
    expect(expirations, 1);
    expect(cancellations, 0);
  });

  test(
    'one deadline does not cancel another operation sharing its tokens',
    () async {
      final first = create(timeout: const Duration(seconds: 10));
      final second = create(timeout: const Duration(seconds: 20));
      final result = expectLater(
        first.future,
        throwsA(
          failure(OperationFailureReason.timeout, DeliveryState.notSubmitted),
        ),
      );
      first.start(shutdown: shutdown, cancellationToken: caller);
      second.start(shutdown: shutdown, cancellationToken: caller);
      time.elapse(const Duration(seconds: 10));
      await result;
      expect(second.isCompleted, isFalse);
      expect(caller.isCancelled, isFalse);
      expect(shutdown.isCancelled, isFalse);
      second.complete(42);
      second.release();
      expect(await second.future, 42);
    },
  );

  test('retry submission cannot reset the operation deadline', () async {
    final operation = create();
    final result = expectLater(
      operation.future,
      throwsA(failure(OperationFailureReason.timeout, DeliveryState.unknown)),
    );
    operation.start(shutdown: shutdown, cancellationToken: caller);
    operation.markSubmitted();
    time.elapse(const Duration(minutes: 3));
    expect(() => operation.start(shutdown: shutdown), throwsStateError);
    operation.markSubmitted();
    time.elapse(const Duration(minutes: 1));
    await result;
    expect(expirations, 1);
  });

  test('nonpositive timeouts are rejected before allocating resources', () {
    for (final timeout in [Duration.zero, const Duration(seconds: -1)]) {
      expect(() => create(timeout: timeout), throwsArgumentError);
    }
  });
}
