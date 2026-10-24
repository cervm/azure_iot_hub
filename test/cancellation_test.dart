import 'package:azure_iot_hub/azure_iot_hub.dart';
import 'package:test/test.dart';

void main() {
  test('one stable token observes permanent, idempotent cancellation', () {
    final source = CancellationTokenSource();
    final CancellationToken token = source.token;
    expect(token.isCancellationRequested, isFalse);
    expect(source.token, same(token));

    source.cancel();
    source.cancel();
    expect(source.token, same(token));
    expect(token.isCancellationRequested, isTrue);
    expect(CancellationTokenSource().token.isCancellationRequested, isFalse);
  });

  test('cancellation before the token is read is preserved', () {
    final source = CancellationTokenSource()..cancel();
    expect(source.token.isCancellationRequested, isTrue);
  });
}
