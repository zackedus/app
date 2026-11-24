/// User-adjustable detection options, stored as JSON on the phone.
class DetectionSettings {
  const DetectionSettings({
    this.minScore = 0.5,
    this.hiddenLabels = const {},
    this.maxFps = 0,
    this.includeLocation = true,
  });

  static const minScoreRange = (0.2, 0.9);
  static const fpsChoices = [0, 15, 10, 5];

  /// Detector boxes below this score are hidden (example matches always show).
  final double minScore;

  /// Labels the user switched off. New classes are visible by default.
  final Set<String> hiddenLabels;

  /// Upper limit for processed frames per second; 0 means no limit.
  final int maxFps;

  /// Whether saved photos carry the last known GPS position.
  final bool includeLocation;

  bool shows(String label) => !hiddenLabels.contains(label);

  Duration? get minFrameGap =>
      maxFps <= 0 ? null : Duration(microseconds: (1000000 / maxFps).round());

  DetectionSettings copyWith({
    double? minScore,
    Set<String>? hiddenLabels,
    int? maxFps,
    bool? includeLocation,
  }) =>
      DetectionSettings(
        minScore: minScore ?? this.minScore,
        hiddenLabels: hiddenLabels ?? this.hiddenLabels,
        maxFps: maxFps ?? this.maxFps,
        includeLocation: includeLocation ?? this.includeLocation,
      );

  Map<String, Object> toJson() => {
        'version': 1,
        'minScore': minScore,
        'hiddenLabels': hiddenLabels.toList()..sort(),
        'maxFps': maxFps,
        'includeLocation': includeLocation,
      };

  /// Reads stored settings; unknown or invalid values fall back to defaults.
  factory DetectionSettings.fromJson(Object? json) {
    if (json is! Map) return const DetectionSettings();
    final score = json['minScore'];
    final fps = json['maxFps'];
    final hidden = json['hiddenLabels'];
    final location = json['includeLocation'];
    return DetectionSettings(
      minScore: score is num && score.isFinite
          ? score.toDouble().clamp(minScoreRange.$1, minScoreRange.$2).toDouble()
          : 0.5,
      hiddenLabels: hidden is List ? hidden.whereType<String>().toSet() : const {},
      maxFps: fps is int && fpsChoices.contains(fps) ? fps : 0,
      includeLocation: location is bool ? location : true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DetectionSettings &&
      other.minScore == minScore &&
      other.maxFps == maxFps &&
      other.includeLocation == includeLocation &&
      other.hiddenLabels.length == hiddenLabels.length &&
      other.hiddenLabels.containsAll(hiddenLabels);

  @override
  int get hashCode => Object.hash(
        minScore,
        maxFps,
        includeLocation,
        Object.hashAllUnordered(hiddenLabels),
      );
}

/// Formats a timestamp as `25-11-2026 14:05:09` without extra packages.
String formatTimestamp(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(time.day)}-${two(time.month)}-${time.year} '
      '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
}
