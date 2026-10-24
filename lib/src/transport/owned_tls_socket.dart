import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'connection_diagnostics.dart';

/// A bounded TLS socket that retains its TCP socket throughout the handshake.
final class OwnedTlsSocket extends Stream<Uint8List> implements Socket {
  OwnedTlsSocket({
    required this.maxBufferedBytes,
    this.securityContext,
    this.limitReadsUntilReset = false,
    this.diagnostics,
    Future<ConnectionTask<RawSocket>> Function(String, int)? startConnect,
  }) : _startConnect =
           startConnect ??
           ((host, port) => RawSocket.startConnect(host, port)) {
    _input
      ..onPause = () {
        _secure?.readEventsEnabled = false;
      }
      ..onResume = () {
        _secure?.readEventsEnabled = true;
      }
      ..onListen = () {
        _secure?.readEventsEnabled = true;
      }
      ..onCancel = destroy;
  }

  final int maxBufferedBytes;
  final SecurityContext? securityContext;
  final bool limitReadsUntilReset;
  final ConnectionDiagnostics? diagnostics;
  final Future<ConnectionTask<RawSocket>> Function(String, int) _startConnect;
  final _input = StreamController<Uint8List>(sync: true);
  final _outgoing = Queue<Uint8List>();
  final _retired = Completer<void>();
  final _done = Completer<void>();
  ConnectionTask<RawSocket>? _task;
  RawSocket? _raw;
  RawSecureSocket? _secure;
  StreamSubscription<RawSocketEvent>? _subscription;
  Completer<void>? _drained;
  int _queuedBytes = 0;
  int _writeOffset = 0;
  int _readBytes = 0;
  bool _closed = false;

  /// Connects once, retaining ownership during DNS, TCP and TLS setup.
  Future<OwnedTlsSocket> connect(String host, int port) async {
    diagnostics?.stage = ConnectionStage.tcp;
    final task = await _startConnect(host, port);
    _task = task;
    if (_closed) task.cancel();
    final raw = await task.socket;
    _raw = raw;
    if (_closed) {
      await raw.close();
      throw const SocketException('Connection retired.');
    }
    raw.setOption(SocketOption.tcpNoDelay, true);
    diagnostics?.stage = ConnectionStage.tls;
    final handshake =
        RawSecureSocket.secure(raw, host: host, context: securityContext).then((
          secure,
        ) {
          if (_closed) unawaited(secure.close());
          return secure;
        });
    // Closing RawSocket releases the native handle but may not settle the TLS
    // future. Retirement releases its waiter and consumes any late completion.
    final secure = await Future.any([
      handshake,
      _retired.future.then<RawSecureSocket>((_) {
        throw const SocketException('Connection retired.');
      }),
    ]);
    if (_closed) {
      await secure.close();
      throw const SocketException('Connection retired.');
    }
    _secure = secure;
    secure
      ..readEventsEnabled = _input.hasListener
      ..writeEventsEnabled = false;
    _subscription = secure.listen(
      _event,
      onError: (Object error) => _fail(error),
      onDone: destroy,
    );
    return this;
  }

  /// Resets the read budget after an HTTP upgrade or complete WebSocket message.
  void resetReadBudget() => _readBytes = 0;

  void _event(RawSocketEvent event) {
    if (_closed) return;
    try {
      if (event == RawSocketEvent.read) {
        final bytes = _secure!.read(8192);
        if (bytes != null) {
          if (limitReadsUntilReset) {
            _readBytes += bytes.length;
            if (_readBytes > maxBufferedBytes) {
              throw const FormatException('Connection read buffer exceeded.');
            }
          }
          _input.add(bytes);
        }
      } else if (event == RawSocketEvent.write) {
        _drain();
      } else {
        destroy();
      }
    } catch (error) {
      _fail(error);
    }
  }

  void _fail(Object error) {
    if (_closed) return;
    _input.addError(error);
    destroy();
  }

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _input.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  void add(List<int> data) {
    if (_closed || _secure == null) {
      throw const SocketException('Connection is not open.');
    }
    if (_queuedBytes + data.length > maxBufferedBytes) {
      throw StateError('Connection write buffer exceeded.');
    }
    if (data.isEmpty) return;
    _queuedBytes += data.length;
    _outgoing.add(Uint8List.fromList(data));
    _drained ??= Completer<void>()..future.ignore();
    _drain();
  }

  void _drain() {
    while (!_closed && _outgoing.isNotEmpty) {
      final bytes = _outgoing.first;
      final written = _secure!.write(bytes, _writeOffset);
      _queuedBytes -= written;
      _writeOffset += written;
      if (_writeOffset < bytes.length) {
        _secure!.writeEventsEnabled = true;
        return;
      }
      _outgoing.removeFirst();
      _writeOffset = 0;
    }
    _secure?.writeEventsEnabled = false;
    _drained?.complete();
    _drained = null;
  }

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final bytes in stream) {
      add(bytes);
      await flush();
    }
  }

  @override
  Future<void> flush() => _closed
      ? Future.error(const SocketException('Connection retired.'))
      : _drained?.future ?? Future.value();

  @override
  Future<void> close() async {
    if (_closed) return;
    try {
      await flush();
    } finally {
      destroy();
    }
  }

  @override
  Future<void> get done => _done.future;

  @override
  void destroy() {
    if (_closed) return;
    _closed = true;
    _retired.complete();
    _task?.cancel();
    unawaited(_subscription?.cancel());
    unawaited(_raw?.close());
    unawaited(_secure?.close());
    _outgoing.clear();
    _queuedBytes = 0;
    _drained?.completeError(const SocketException('Connection retired.'));
    _drained = null;
    unawaited(_input.close());
    _done.complete();
  }

  @override
  Encoding encoding = utf8;
  @override
  void write(Object? object) => add(encoding.encode('$object'));
  @override
  void writeln([Object? object = '']) => write('$object\n');
  @override
  void writeAll(Iterable objects, [String separator = '']) =>
      write(objects.join(separator));
  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      throw UnsupportedError('Socket errors cannot be sent.');
  @override
  bool setOption(SocketOption option, bool enabled) =>
      _secure!.setOption(option, enabled);
  @override
  void setRawOption(RawSocketOption option) => _secure!.setRawOption(option);
  @override
  Uint8List getRawOption(RawSocketOption option) =>
      _secure!.getRawOption(option);
  @override
  InternetAddress get address => _secure!.address;
  @override
  InternetAddress get remoteAddress => _secure!.remoteAddress;
  @override
  int get port => _secure!.port;
  @override
  int get remotePort => _secure!.remotePort;
}
