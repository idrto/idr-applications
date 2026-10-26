import 'dart:math';

/// Exponential backoff with jitter and a hard attempt budget.
class Backoff {
  Backoff({
    required this.initial,
    required this.max,
    this.factor = 2.0,
    Random? random,
  }) : _random = random ?? Random();

  final Duration initial;
  final Duration max;
  final double factor;
  final Random _random;
  int _attempt = 0;

  int get attempt => _attempt;

  void reset() => _attempt = 0;

  Duration next() {
    final exp = initial.inMilliseconds * pow(factor, _attempt);
    _attempt++;
    final capped = min(exp, max.inMilliseconds.toDouble());
    final jitter = capped * (0.8 + _random.nextDouble() * 0.4);
    return Duration(milliseconds: jitter.round());
  }
}
