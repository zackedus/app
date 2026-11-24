import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'src/annotations.dart';
import 'src/labels.dart';
import 'src/match_worker.dart';
import 'src/matching.dart';

part 'src/ui/dataset_gallery.dart';
part 'src/ui/annotation_editor.dart';
part 'src/ui/openrouter.dart';
part 'src/ui/example_label_dialog.dart';
part 'src/ui/overlay.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(
    const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: DetectionScreen(),
    ),
  );
}

class DetectionScreen extends StatefulWidget {
  const DetectionScreen({super.key, this.listCameras = availableCameras});

  final Future<List<CameraDescription>> Function() listCameras;

  @override
  State<DetectionScreen> createState() => _DetectionScreenState();
}

class _DetectionScreenState extends State<DetectionScreen>
    with WidgetsBindingObserver {
  static const _detector = MethodChannel('object_detection/detector');
  static const _settings = MethodChannel('object_detection/openrouter_settings');
  late final Future<void> _settingsReady;
  CameraController? _camera;
  Future<void> _cameraWork = Future<void>.value();
  bool _active = true;
  bool _busy = false;
  bool _collecting = false;
  String? _exampleLabel;
  static const _defaultOpenRouterModel = 'google/gemini-3.8-flash';
  // Gemini 2.5 Flash is deprecated; settings saved with the old default move on.
  static const _retiredDefaultModels = {'google/gemini-2.5-flash'};
  String? _openRouterKey;
  String _openRouterModel = _defaultOpenRouterModel;

  Future<void> _loadOpenRouterSettings() async {
    try {
      final values = await _settings.invokeMapMethod<String, String>('load');
      if (!mounted || values == null) return;
      final token = values['token'];
      final model = values['model'];
      _openRouterKey = (token == null || token.isEmpty) ? null : token;
      if (model != null &&
          model.isNotEmpty &&
          !_retiredDefaultModels.contains(model)) {
        _openRouterModel = model;
      }
    } on PlatformException {
      // Defaults allow offline use while settings storage is unavailable.
    } on MissingPluginException {
      // Android owns secure settings storage.
    }
  }

  Future<void> _openRouterSettings() async {
    await _settingsReady;
    if (!mounted) return;
    final configuration = await showDialog<(String, String)>(
      context: context,
      builder: (_) => _OpenRouterSettingsDialog(
        _openRouterKey ?? '',
        _openRouterModel,
        _defaultOpenRouterModel,
      ),
    );
    if (!mounted || configuration == null) return;
    final (key, model) = configuration;
    try {
      await _settings.invokeMethod<void>('save', {'token': key, 'model': model});
      if (!mounted) return;
      setState(() {
        _openRouterKey = key.isEmpty ? null : key;
        _openRouterModel = model;
      });
    } on PlatformException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pengaturan gagal disimpan. Coba lagi.')),
      );
    }
  }
  int _generation = 0;
  String? _error;
  final _frameFailures = FailureGate();
  List<_Detection> _detections = [];
  ExampleSet _examples = {};
  final _matcher = MatchWorker();
  int _learningRevision = 0;
  bool _focusMode = false;
  String? _focusLabel;
  int _focusFrames = 0;
  bool _focusMissedOnce = false;

  void _toggleFocus() {
    setState(() {
      _focusMode = !_focusMode;
      _focusLabel = null;
      _focusFrames = 0;
      _focusMissedOnce = false;
      _detections = [];
    });
  }

  List<_Detection> _confirmedFocus(List<_Detection> candidates) {
    final candidate = candidates.isEmpty ? null : candidates.first;
    if (candidate == null || !candidate.local) {
      if (_focusFrames >= 3 && !_focusMissedOnce) {
        _focusMissedOnce = true;
        return _detections;
      }
      _focusMissedOnce = false;
      _focusLabel = null;
      _focusFrames = 0;
      return [];
    }
    if (_focusLabel != candidate.label) {
      _focusLabel = candidate.label;
      _focusFrames = 0;
    }
    _focusMissedOnce = false;
    _focusFrames++;
    return _focusFrames >= 3 ? [candidate] : [];
  }

  Future<void> _learnApprovedExamples() async {
    final revision = ++_learningRevision;
    final examples = <String, List<List<List<double>>>>{};
    try {
      final root = await getApplicationDocumentsDirectory();
      final dataset = Directory('${root.path}/training_examples');
      if (await dataset.exists()) {
        await for (final entry in dataset.list(recursive: true, followLinks: false)) {
          if (!mounted || revision != _learningRevision) return;
          if (entry is! File || !entry.path.endsWith('.jpg.json')) continue;
          try {
            final annotation = await entry.readAsString();
            final boxes = parseBoxes(annotation);
            if (boxes.isEmpty) continue;
            final label = entry.parent.uri.pathSegments.lastWhere(
              (segment) => segment.isNotEmpty,
            );
            final photoPath = entry.path.substring(0, entry.path.length - 5);
            final photoSamples = await _cachedSamples(photoPath, annotation, boxes);
            if (photoSamples.isNotEmpty) (examples[label] ??= []).add(photoSamples);
          } catch (_) {
            // A damaged photo or annotation does not block other examples.
          }
        }
      }
      if (!mounted || revision != _learningRevision) return;
      setState(() {
        _examples = Map.fromEntries(examples.entries.where((e) => e.value.length >= 3));
        _matcher.setExamples(_examples);
        if (_examples.isEmpty) {
          _focusMode = false;
          _focusLabel = null;
          _focusFrames = 0;
        }
      });
    } catch (_) {
      // The built-in detector remains available when dataset storage is unavailable.
    }
  }

  static const _featureCacheVersion = 1;

  /// Feature vectors are cached next to the photo and reused while the
  /// annotation is unchanged, so only new or edited photos are processed.
  Future<List<List<double>>> _cachedSamples(
    String photoPath, String annotation, List<Rect> boxes,
  ) async {
    final cache = File('$photoPath.vec.json');
    try {
      if (await cache.exists()) {
        final stored = jsonDecode(await cache.readAsString()) as Map<String, dynamic>;
        if (stored['version'] == _featureCacheVersion &&
            stored['annotation'] == annotation) {
          final samples = (stored['samples'] as List)
              .map((sample) => (sample as List).cast<num>().map((v) => v.toDouble()).toList())
              .where(hasShape)
              .toList();
          if (samples.isNotEmpty) return samples;
        }
      }
    } catch (_) {
      // A damaged cache is rebuilt below.
    }
    final samples = await _detector.invokeListMethod<List<Object?>>(
      'learnPhoto',
      {
        'path': photoPath,
        'boxes': boxes.map((box) => [box.left, box.top, box.right, box.bottom]).toList(),
      },
    );
    final photoSamples = (samples ?? const <List<Object?>>[])
        .map((sample) => sample.cast<num>().map((v) => v.toDouble()).toList())
        .where(hasShape)
        .toList();
    // Only complete vectors are cached; without an embedding it is retried next time.
    if (photoSamples.isNotEmpty &&
        photoSamples.every((sample) => sample.length > basicFeatureLength)) {
      try {
        final pending = File('${cache.path}.tmp');
        await pending.writeAsString(jsonEncode({
          'version': _featureCacheVersion,
          'annotation': annotation,
          'samples': photoSamples,
        }), flush: true);
        await pending.rename(cache.path);
      } catch (_) {
        // The cache is only an optimisation.
      }
    }
    return photoSamples;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _settingsReady = _loadOpenRouterSettings();
    _scheduleCamera();
    _learnApprovedExamples();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final active = state == AppLifecycleState.resumed;
    if (active == _active) return;
    _active = active;
    _scheduleCamera();
  }

  void _scheduleCamera() {
    final generation = ++_generation;
    _cameraWork = _cameraWork.then((_) => _updateCamera(generation));
  }

  bool _current(int generation) =>
      mounted && _active && generation == _generation;

  Future<void> _updateCamera(int generation) async {
    final previous = _camera;
    _camera = null;
    try {
      if (mounted) {
        setState(() {
          _detections = [];
          _focusLabel = null;
          _focusFrames = 0;
          _error = null;
        });
      }
      await previous?.dispose();
      if (!_current(generation)) return;
      final cameras = await widget.listCameras();
      final rear = cameras.where(
        (c) => c.lensDirection == CameraLensDirection.back,
      );
      if (rear.isEmpty) throw StateError('Kamera belakang tidak tersedia.');
      if (!_current(generation)) return;
      final camera = CameraController(
        rear.first,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.nv21,
      );
      _camera = camera;
      await camera.initialize();
      if (!_current(generation)) return;
      await camera.lockCaptureOrientation(DeviceOrientation.portraitUp);
      if (!_current(generation)) return;
      await camera.startImageStream(
        (image) => _detect(image, camera, generation),
      );
      if (_current(generation)) setState(() {});
    } catch (error) {
      if (_current(generation)) {
        setState(() {
          _error =
              error is CameraException &&
                  error.code.startsWith('CameraAccessDenied')
              ? 'Izinkan akses kamera di pengaturan Android, lalu coba lagi.'
              : 'Kamera gagal dimulai. $error';
        });
      }
    }
  }

  Future<void> _detect(
    CameraImage image,
    CameraController camera,
    int generation,
  ) async {
    if (_busy || _error != null || !_current(generation)) return;
    _busy = true;
    final focus = _focusMode;
    try {
      if (image.planes.length != 1 ||
          image.planes.single.bytes.length !=
              image.width * image.height * 3 ~/ 2) {
        throw StateError('Format frame kamera tidak didukung.');
      }
      final result = await _detector
          .invokeListMethod<Map<Object?, Object?>>('detect', {
            'bytes': image.planes.single.bytes,
            'width': image.width,
            'height': image.height,
            'rotation': camera.description.sensorOrientation,
            'focus': focus,
            'compareExamples': _examples.isNotEmpty,
          });
      final raw = (result ?? []).map(_Detection.fromMap).toList();
      // Comparison with example photos runs on a background isolate.
      final labels = await _matcher.match(
        [for (final detection in raw) detection.appearance],
        [for (final detection in raw) detection.score],
      );
      if (_current(generation) && focus == _focusMode) {
        setState(() {
          final candidates = [
            for (var i = 0; i < raw.length; i++)
              if (i < labels.length && labels[i] != null)
                raw[i].asLocal(labels[i]!)
              else
                raw[i],
          ].where((detection) => detection.local || detection.score >= 0.5).take(8).toList();
          _detections = focus ? _confirmedFocus(candidates) : candidates;
        });
      }
      _frameFailures.succeed();
    } catch (error) {
      // A single bad frame is skipped; only repeated failures stop the camera.
      if (_frameFailures.fail() && _current(generation)) {
        _frameFailures.succeed();
        setState(() => _error = 'Deteksi gagal. $error');
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _collectExample({bool chooseLabel = false}) async {
    if (_collecting) return;
    setState(() => _collecting = true);
    try {
      final label = (chooseLabel ? null : _exampleLabel) ?? await showDialog<String>(
        context: context,
        builder: (context) => const _ExampleLabelDialog(),
      );
      if (!mounted || label == null) return;
      setState(() => _exampleLabel = label);
      final generation = _generation;
      final camera = _camera;
      if (camera == null || !camera.value.isInitialized || !_current(generation)) {
        throw StateError('Kamera belum siap.');
      }
      String? message;
      File? savedPhoto;
      _cameraWork = _cameraWork.then((_) async {
        if (!_current(generation)) return;
        try {
          if (camera.value.isStreamingImages) await camera.stopImageStream();
          if (!_current(generation)) return;
          final photo = await camera.takePicture();
          try {
            final root = await getApplicationDocumentsDirectory();
            final directory = Directory(
              '${root.path}/training_examples/$label',
            );
            await directory.create(recursive: true);
            final filename = DateTime.now().microsecondsSinceEpoch;
            final file = File('${directory.path}/$filename.jpg');
            await photo.saveTo(file.path);
            savedPhoto = file;
            final count = await directory
                .list()
                .where((entry) => entry is File && entry.path.endsWith('.jpg'))
                .length;
            message = '$label: $count foto contoh tersimpan di HP.';
          } finally {
            try {
              await File(photo.path).delete();
            } on FileSystemException {
              // The camera cache can be cleared independently.
            }
          }
        } catch (_) {
          message = 'Foto contoh gagal disimpan. Coba ambil ulang.';
        } finally {
          if (_current(generation)) {
            try {
              await camera.startImageStream(
                (image) => _detect(image, camera, generation),
              );
            } catch (_) {
              _scheduleCamera();
            }
          }
        }
      });
      await _cameraWork;
      final photo = savedPhoto;
      if (mounted && photo != null) {
        message = await _reviewPhotoWithAi(photo, label) ?? message;
      }
      if (mounted && message != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message!)),
        );
      }
    } on StateError {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Kamera belum siap. Coba lagi.')),
        );
      }
    } finally {
      if (mounted) setState(() => _collecting = false);
    }
  }

  Future<String?> _reviewPhotoWithAi(File photo, String label) async {
    await _settingsReady;
    if (!mounted) return null;
    final key = _openRouterKey;
    final model = _openRouterModel;
    if (key == null) {
      return 'Foto tersimpan. Isi API key di Pengaturan OpenRouter untuk anotasi AI.';
    }
    final send = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Anotasi dengan OpenRouter'),
        content: Text(
          'Foto ini akan dikirim ke OpenRouter dan penyedia model $model. '
          'Gunakan foto orang yang sudah memberi izin. API bisa dikenai biaya.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Lewati'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Kirim foto'),
          ),
        ],
      ),
    );
    if (!mounted || send != true) return null;

    try {
      final boxes = await _requestAiBoxes(photo, label, key, model);
      if (!mounted) return null;
      final reviewed = await _openEditor(context, photo, label, boxes);
      if (reviewed == null) return 'Foto tersimpan tanpa anotasi.';
      await _saveAnnotation(photo, label, reviewed);
      await _learnApprovedExamples();
      return 'Foto dan ${reviewed.length} anotasi tersimpan di HP.';
    } on _OpenRouterException catch (error) {
      if (error.status == 401 || error.status == 403) {
        return 'Foto tersimpan. Periksa API key dan akses model di Pengaturan OpenRouter.';
      }
      return 'Foto tersimpan. OpenRouter mengembalikan HTTP ${error.status}.';
    } catch (_) {
      return 'Foto tersimpan. Anotasi AI gagal. Periksa koneksi dan coba lagi.';
    }
  }

  @override
  void dispose() {
    _matcher.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _active = false;
    _scheduleCamera();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final camera = _camera;
    final error = _error;
    return Scaffold(
      backgroundColor: const Color(0xff121718),
      appBar: AppBar(
        backgroundColor: const Color(0xff121718),
        foregroundColor: Colors.white,
        title: const Text('Deteksi Objek'),
        actions: [
          IconButton(
            tooltip: 'Pengaturan OpenRouter',
            onPressed: _collecting ? null : _openRouterSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
          IconButton(
            tooltip: 'Galeri dataset',
            onPressed: _collecting ? null : () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const _DatasetGallery()),
              );
              if (mounted) await _learnApprovedExamples();
            },
            icon: const Icon(Icons.photo_library_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: error != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(error, style: const TextStyle(color: Colors.white)),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: _scheduleCamera,
                        child: const Text('Coba lagi'),
                      ),
                    ],
                  ),
                ),
              )
            : camera == null || !camera.value.isInitialized
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  Expanded(
                    child: Center(
                      child: CameraPreview(
                        camera,
                        child: ClipRect(
                          child: CustomPaint(painter: _Overlay(_detections, focus: _focusMode)),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      _detections.isEmpty
                          ? (_focusMode ? 'Penuhi bingkai dengan objek. Belum cocok.' : 'Arahkan kamera ke objek')
                          : '${_detections.length} objek terdeteksi',
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                  if (_examples.isNotEmpty)
                    Text(
                      '${_examples.length} kelas contoh aktif',
                      style: const TextStyle(color: Colors.white70),
                    ),
                  if (_examples.isNotEmpty)
                    TextButton.icon(
                      onPressed: _collecting ? null : _toggleFocus,
                      icon: const Icon(Icons.center_focus_strong),
                      label: Text(_focusMode ? 'Kembali ke deteksi umum' : 'Kenali objek di tengah'),
                      style: TextButton.styleFrom(foregroundColor: Colors.white),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        FilledButton.icon(
                          onPressed: _collecting ? null : () => _collectExample(),
                          icon: const Icon(Icons.add_a_photo_outlined),
                          label: Text(
                            _collecting
                                ? 'Sedang memproses foto…'
                                : _exampleLabel == null
                                    ? 'Tambahkan objek baru'
                                    : 'Ambil foto contoh · $_exampleLabel',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (_exampleLabel != null)
                          TextButton(
                            onPressed: _collecting
                                ? null
                                : () => _collectExample(chooseLabel: true),
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.white,
                            ),
                            child: const Text('Ganti atau tambah jenis objek'),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
