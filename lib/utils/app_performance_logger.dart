import 'package:flutter/foundation.dart';

class AppPerformanceLogger {
  static final Stopwatch _stopwatch = Stopwatch();
  static bool _isTracking = false;

  static void startTracking() {
    _stopwatch.reset();
    _stopwatch.start();
    _isTracking = true;
    log('App start tracking initiated');
  }

  static void log(String message) {
    if (!kDebugMode && !_isTracking) return;
    final elapsedMs = _stopwatch.elapsedMilliseconds;
    debugPrint('[PERF] +${elapsedMs}ms | $message');
  }

  static int get elapsedMs => _stopwatch.elapsedMilliseconds;
}
