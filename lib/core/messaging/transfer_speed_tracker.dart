/// A sliding-window transfer speed and ETA calculator.
///
/// Records byte-delivery samples over time and exposes a moving-average
/// speed and estimated time to completion. The window is bounded to the
/// last [maxSamples] entries or the last [windowSeconds] of real time,
/// whichever is narrower.
class TransferSpeedTracker {
  final int totalBytes;
  final int maxSamples;
  final int windowSeconds;

  final List<_Sample> _samples = [];
  int _deliveredBytes = 0;

  TransferSpeedTracker({
    required this.totalBytes,
    this.maxSamples = 20,
    this.windowSeconds = 5,
  });

  /// Record how many bytes have been delivered so far (cumulative total).
  void record(int deliveredBytes) {
    _deliveredBytes = deliveredBytes;
    _samples.add(_Sample(
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      deliveredBytes: deliveredBytes,
    ));

    // Prune by count
    if (_samples.length > maxSamples) {
      _samples.removeAt(0);
    }

    // Prune by age
    final cutoffMs = DateTime.now().millisecondsSinceEpoch - windowSeconds * 1000;
    _samples.removeWhere((s) => s.timestampMs < cutoffMs);
  }

  /// Current transfer speed in bytes per second (moving window average).
  double get speedBytesPerSecond {
    if (_samples.length < 2) return 0.0;
    final oldest = _samples.first;
    final newest = _samples.last;
    final deltaBytes = (newest.deliveredBytes - oldest.deliveredBytes).toDouble();
    final deltaMs = (newest.timestampMs - oldest.timestampMs).toDouble();
    if (deltaMs <= 0) return 0.0;
    return deltaBytes / (deltaMs / 1000.0);
  }

  /// Remaining bytes yet to be delivered.
  int get remainingBytes => (totalBytes - _deliveredBytes).clamp(0, totalBytes);

  /// Estimated time to completion, or null if speed is not yet known.
  Duration? get eta {
    final speed = speedBytesPerSecond;
    if (speed <= 0) return null;
    final seconds = remainingBytes / speed;
    return Duration(milliseconds: (seconds * 1000).round());
  }

  /// Human-readable speed label, e.g. `"1.4 MB/s"` or `"320 KB/s"`.
  String get speedLabel {
    final bps = speedBytesPerSecond;
    if (bps <= 0) return '';
    if (bps >= 1024 * 1024) {
      return '${(bps / (1024 * 1024)).toStringAsFixed(1)} MB/s';
    }
    if (bps >= 1024) {
      return '${(bps / 1024).toStringAsFixed(0)} KB/s';
    }
    return '${bps.toStringAsFixed(0)} B/s';
  }

  /// Human-readable ETA label, e.g. `"~8s"`, `"~2m"`, or `""` if unknown.
  String get etaLabel {
    final d = eta;
    if (d == null) return '';
    if (d.inSeconds < 60) return '~${d.inSeconds}s';
    final mins = d.inMinutes;
    final secs = d.inSeconds % 60;
    if (secs == 0) return '~${mins}m';
    return '~${mins}m ${secs}s';
  }

  void reset() {
    _samples.clear();
    _deliveredBytes = 0;
  }
}

class _Sample {
  final int timestampMs;
  final int deliveredBytes;

  const _Sample({required this.timestampMs, required this.deliveredBytes});
}
