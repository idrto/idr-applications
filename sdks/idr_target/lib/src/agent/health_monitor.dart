import 'dart:async';

import '../internal/backoff.dart';
import 'process_manager.dart';

typedef AgentStartFn = Future<void> Function();

/// Watches process exits and restarts with bounded backoff.
class HealthMonitor {
  HealthMonitor({
    required this.process,
    required this.onRestart,
    required this.maxRestarts,
    required this.backoff,
    required this.onBudgetExceeded,
  });

  final ProcessManager process;
  final AgentStartFn onRestart;
  final int maxRestarts;
  final Backoff backoff;
  final void Function() onBudgetExceeded;

  StreamSubscription<int>? _sub;
  bool _stopping = false;
  int _restarts = 0;

  void start() {
    _sub?.cancel();
    _sub = process.exits.listen((code) async {
      if (_stopping) return;
      if (code == 0) return;
      if (_restarts >= maxRestarts) {
        onBudgetExceeded();
        return;
      }
      final delay = backoff.next();
      _restarts++;
      await Future<void>.delayed(delay);
      if (_stopping) return;
      await onRestart();
    });
  }

  void noteHealthyStart() {
    // Reset budget after sustained run could be added later.
  }

  Future<void> stop() async {
    _stopping = true;
    await _sub?.cancel();
    _sub = null;
  }
}
