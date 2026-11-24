/// Length of the hand-made part of an appearance vector:
/// 32 edge-orientation bins followed by 24 colour bins.
const basicFeatureLength = 56;

bool hasShape(List<double> values) =>
    values.length >= basicFeatureLength &&
    values.every((value) => value.isFinite) &&
    (values.length > basicFeatureLength ||
        values.take(32).any((value) => value > 0));

/// Distance between two appearance vectors, or null when they cannot be compared.
///
/// When both carry an image embedding, cosine distance dominates (80%) and the
/// edge/colour histogram distance refines it (20%).
double? appearanceDistance(List<double> appearance, List<double> reference) {
  if (appearance.length != reference.length ||
      appearance.length < basicFeatureLength) {
    // A missing embedding cannot overrule evidence from the model.
    return null;
  }
  var shape = 0.0;
  var color = 0.0;
  for (var i = 0; i < basicFeatureLength; i++) {
    final difference = (appearance[i] - reference[i]).abs();
    if (i < 32) {
      shape += difference;
    } else {
      color += difference;
    }
  }
  final basic = (0.85 * shape + 0.15 * color) / 2;
  if (appearance.length == basicFeatureLength) return basic;
  var cosine = 0.0;
  for (var i = basicFeatureLength; i < appearance.length; i++) {
    cosine += appearance[i] * reference[i];
  }
  final embeddingDistance = (1 - cosine.clamp(-1.0, 1.0)) / 2;
  return 0.8 * embeddingDistance + 0.2 * basic;
}

/// For each class, the distance to the closest annotated box in each photo.
Map<String, List<double>> distancesByClass(
  List<double> appearance,
  Map<String, List<List<List<double>>>> examples,
) {
  final result = <String, List<double>>{};
  for (final entry in examples.entries) {
    result[entry.key] = entry.value.map((photo) {
      var nearest = double.infinity;
      for (final reference in photo) {
        final distance = appearanceDistance(appearance, reference);
        if (distance != null && distance < nearest) nearest = distance;
      }
      return nearest;
    }).toList();
  }
  return result;
}

// Each distance represents the closest annotated box in one distinct photo.
String? selectLocalObjectLabel(
  Map<String, List<double>> distancesByClass, {
  required double maximumDistance,
}) {
  final ranked = <({String label, double score, double secondPhoto})>[];
  for (final entry in distancesByClass.entries) {
    final distances = entry.value
        .where((value) => value.isFinite && value >= 0)
        .toList()
      ..sort();
    if (distances.length < 3) continue;
    ranked.add((
      label: entry.key,
      score: .3 * distances[0] + .5 * distances[1] + .2 * distances[2],
      secondPhoto: distances[1],
    ));
  }
  if (ranked.isEmpty) return null;
  ranked.sort((a, b) => a.score.compareTo(b.score));
  final best = ranked.first;
  if (best.score > maximumDistance || best.secondPhoto > maximumDistance) {
    return null;
  }
  if (ranked.length > 1) {
    final runnerUp = ranked[1];
    if (runnerUp.score - best.score < 0.05 ||
        best.score > runnerUp.score * 0.8) {
      return null;
    }
  }
  return best.label;
}

/// Counts consecutive frame failures so one bad frame does not stop the camera.
class FailureGate {
  FailureGate({this.limit = 5});

  final int limit;
  int _count = 0;

  /// Records a failure and returns true once the limit is reached.
  bool fail() => ++_count >= limit;

  void succeed() => _count = 0;
}
