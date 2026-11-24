part of '../../main.dart';

/// Runs detection on a photo picked from the phone's gallery. The photo can
/// be saved with its boxes or added to the dataset with the boxes as a start.
class _PhotoDetectionPage extends StatefulWidget {
  const _PhotoDetectionPage({
    required this.path,
    required this.width,
    required this.height,
    required this.settings,
    required this.examples,
    required this.saveSnapshot,
  });

  final String path;
  final double width;
  final double height;
  final DetectionSettings settings;
  final ExampleSet examples;
  final Future<void> Function(List<_Detection> detections, String path) saveSnapshot;

  @override
  State<_PhotoDetectionPage> createState() => _PhotoDetectionPageState();
}

class _PhotoDetectionPageState extends State<_PhotoDetectionPage> {
  static const _detector = MethodChannel('object_detection/detector');
  List<_Detection>? _detections;
  String? _error;
  bool _working = false;
  bool _datasetChanged = false;

  @override
  void initState() {
    super.initState();
    _detect();
  }

  Future<void> _detect() async {
    try {
      final result = await _detector.invokeMapMethod<String, Object?>('detectPhoto', {
        'path': widget.path,
        'compareExamples': widget.examples.isNotEmpty,
      });
      final raw = ((result?['detections'] as List?) ?? const [])
          .cast<Map<Object?, Object?>>()
          .map(_Detection.fromMap)
          .toList();
      final labels = matchLabels(
        [for (final d in raw) d.appearance],
        [for (final d in raw) d.score],
        widget.examples,
      );
      if (mounted) {
        setState(() => _detections = _visibleDetections(raw, labels, widget.settings));
      }
    } catch (error) {
      if (mounted) setState(() => _error = 'Deteksi gagal. $error');
    }
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _save() async {
    final detections = _detections;
    if (detections == null || _working) return;
    setState(() => _working = true);
    try {
      await widget.saveSnapshot(detections, widget.path);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _addToDataset() async {
    final detections = _detections;
    if (detections == null || _working) return;
    final label = await showDialog<String>(
      context: context,
      builder: (_) => const _ExampleLabelDialog(),
    );
    if (!mounted || label == null) return;
    setState(() => _working = true);
    try {
      final root = await getApplicationDocumentsDirectory();
      final directory = Directory('${root.path}/training_examples/$label');
      await directory.create(recursive: true);
      final photo = await File(widget.path)
          .copy('${directory.path}/${DateTime.now().microsecondsSinceEpoch}.jpg');
      // Boxes of the same class are a starting point; otherwise every box is offered.
      final sameClass = [
        for (final d in detections)
          if (d.label == label || displayLabel(d.label).toLowerCase() == label) d.box,
      ];
      final boxes = sameClass.isNotEmpty ? sameClass : [for (final d in detections) d.box];
      if (!mounted) return;
      final reviewed = await _openEditor(context, photo, label, boxes);
      if (reviewed == null) {
        _datasetChanged = true;
        _message('Foto masuk dataset "$label" tanpa anotasi.');
        return;
      }
      await _saveAnnotation(photo, label, reviewed);
      _datasetChanged = true;
      _message('Foto dan ${reviewed.length} kotak masuk dataset "$label".');
    } catch (_) {
      _message('Foto gagal ditambahkan ke dataset.');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final detections = _detections;
    final error = _error;
    final perLabel = <String, int>{};
    for (final d in detections ?? const <_Detection>[]) {
      perLabel[d.label] = (perLabel[d.label] ?? 0) + 1;
    }
    return PopScope<bool>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_datasetChanged);
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Deteksi dari foto')),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: Center(
                  child: AspectRatio(
                    aspectRatio: widget.width / widget.height,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.file(File(widget.path), fit: BoxFit.fill),
                        if (detections != null)
                          CustomPaint(painter: _Overlay(detections)),
                      ],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: error != null
                    ? Text(error)
                    : detections == null
                        ? const LinearProgressIndicator()
                        : Text(
                            detections.isEmpty
                                ? 'Tidak ada objek di atas ambang ${(100 * widget.settings.minScore).round()}%.'
                                : '${detections.length} objek: ' +
                                    perLabel.entries
                                        .map((e) => '${displayLabel(e.key)} ${e.value}')
                                        .join(', '),
                            textAlign: TextAlign.center,
                          ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: detections == null || _working ? null : _addToDataset,
                        icon: const Icon(Icons.add_photo_alternate_outlined),
                        label: const Text('Jadikan contoh'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: detections == null || _working ? null : _save,
                        icon: const Icon(Icons.save_alt),
                        label: const Text('Simpan hasil'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
