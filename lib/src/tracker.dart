import 'dart:ui';

/// Intersection over union of two boxes.
double iou(Rect a, Rect b) {
  final overlap = a.intersect(b);
  if (overlap.width <= 0 || overlap.height <= 0) return 0;
  final shared = overlap.width * overlap.height;
  final union = a.width * a.height + b.width * b.height - shared;
  return union <= 0 ? 0 : shared / union;
}

class _Track {
  _Track(this.id, this.label, this.box);

  final int id;
  final String label;
  Rect box;
  int hits = 1;
  int missed = 0;
}

/// Follows boxes across frames by overlap so each object is counted once.
///
/// A track is confirmed after [minHits] matched frames (filters one-frame
/// false positives) and dropped after [maxMissed] frames without a match
/// (bridges short dropouts without creating a new object).
class ObjectTracker {
  ObjectTracker({this.iouThreshold = 0.3, this.minHits = 3, this.maxMissed = 5});

  final double iouThreshold;
  final int minHits;
  final int maxMissed;

  final _tracks = <_Track>[];
  final _totals = <String, int>{};
  var _visible = <String, int>{};
  int _nextId = 1;

  /// Confirmed objects per label since the last [reset].
  Map<String, int> get totals => Map.unmodifiable(_totals);

  /// Confirmed objects per label in the latest frame.
  Map<String, int> get visible => Map.unmodifiable(_visible);

  /// Matches this frame's detections to tracks. Returns, for each detection,
  /// its track id once that track is confirmed, otherwise null.
  List<int?> update(List<(String, Rect)> detections) {
    final pairs = <(double, _Track, int)>[];
    for (final track in _tracks) {
      for (var i = 0; i < detections.length; i++) {
        final (label, box) = detections[i];
        if (label != track.label) continue;
        final overlap = iou(track.box, box);
        if (overlap >= iouThreshold) pairs.add((overlap, track, i));
      }
    }
    pairs.sort((a, b) => b.$1.compareTo(a.$1));

    final assigned = List<_Track?>.filled(detections.length, null);
    final matched = <_Track>{};
    for (final (_, track, index) in pairs) {
      if (assigned[index] != null || matched.contains(track)) continue;
      assigned[index] = track;
      matched.add(track);
      track
        ..box = detections[index].$2
        ..hits += 1
        ..missed = 0;
      if (track.hits == minHits) {
        _totals[track.label] = (_totals[track.label] ?? 0) + 1;
      }
    }
    for (final track in _tracks) {
      if (!matched.contains(track)) track.missed += 1;
    }
    _tracks.removeWhere((track) => track.missed > maxMissed);
    for (var i = 0; i < detections.length; i++) {
      if (assigned[i] != null) continue;
      final (label, box) = detections[i];
      final track = _Track(_nextId++, label, box);
      _tracks.add(track);
      assigned[i] = track;
      if (minHits <= 1) _totals[label] = (_totals[label] ?? 0) + 1;
    }

    final visible = <String, int>{};
    final ids = <int?>[];
    for (final track in assigned) {
      final confirmed = track!.hits >= minHits;
      ids.add(confirmed ? track.id : null);
      if (confirmed) visible[track.label] = (visible[track.label] ?? 0) + 1;
    }
    _visible = visible;
    return ids;
  }

  void reset() {
    _tracks.clear();
    _totals.clear();
    _visible = {};
    _nextId = 1;
  }
}
