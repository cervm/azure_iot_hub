import 'package:cancellation_token/cancellation_token.dart' as backend;

/// The owner of a cancellation request shared by one or more SDK operations.
///
/// Pass [token] to operations and call [cancel] when cancellation is needed.
/// Cancellation is permanent; create a new source for a new cancellation scope.
final class CancellationTokenSource() {
  /// The token through which operations observe this source's cancellation.
  final CancellationToken token = ._(backend.CancellationToken());

  /// Requests cancellation of all operations using [token].
  ///
  /// Subsequent calls have no effect. Cancelling an operation does not stop
  /// client recovery or imply that a submitted message was not delivered.
  void cancel() => token._delegate.cancel();
}

/// A read-only cancellation signal obtained from [CancellationTokenSource.token].
///
/// A token may be shared by multiple operations. Completing, timing out or closing
/// an operation's client does not cancel its token. Operation deadlines still
/// apply when a token is supplied.
final class CancellationToken._(final backend.CancellationToken _delegate) {
  /// Whether cancellation has been requested by this token's source.
  bool get isCancellationRequested => _delegate.isCancelled;
}

// Internal bridge; deliberately excluded from the package's exports.
backend.CancellationToken? unwrapCancellationToken(CancellationToken? token) =>
    token?._delegate;
