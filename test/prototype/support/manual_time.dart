import 'dart:async';

// Advances only the prototype's deadlines and backoff, not socket I/O.
final class ManualTime {
  var elapsed = Duration.zero;
  final _timers = <_Timer>{};
  int get activeTimers => _timers.length;

  Timer schedule(Duration delay, void Function() callback) {
    final timer = _Timer(this, elapsed + delay, callback);
    _timers.add(timer);
    return timer;
  }

  void elapse(Duration duration) {
    final end = elapsed + duration;
    while (true) {
      final due = _timers.where((timer) => timer.at <= end).toList()
        ..sort((a, b) => a.at.compareTo(b.at));
      if (due.isEmpty) break;
      final timer = due.first;
      elapsed = timer.at;
      timer.cancel();
      timer._tick = 1;
      timer.callback();
    }
    elapsed = end;
  }
}

final class _Timer(
  final ManualTime clock,
  final Duration at,
  final void Function() callback,
) implements Timer {
  bool _active = true;
  int _tick = 0;
  @override
  bool get isActive => _active;
  @override
  int get tick => _tick;
  @override
  void cancel() {
    _active = false;
    clock._timers.remove(this);
  }
}
