import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'src/annotations.dart';
import 'src/labels.dart';
import 'src/matching.dart';

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
  Map<String, List<List<List<double>>>> _examples = {};
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

  _Detection _matchLocal(_Detection detection) {
    final appearance = detection.appearance;
    if (!hasShape(appearance) || _examples.isEmpty) return detection;
    final bestLabel = selectLocalObjectLabel(
      distancesByClass(appearance, _examples),
      maximumDistance: detection.score < 0.5 ? 0.19 : 0.25,
    );
    if (bestLabel == null) return detection;
    return _Detection(detection.box, bestLabel, detection.score, appearance, local: true);
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
      if (_current(generation) && focus == _focusMode) {
        setState(() {
          final candidates = (result ?? [])
              .map(_Detection.fromMap)
              .map(_matchLocal)
              .where((detection) => detection.local || detection.score >= 0.5)
              .take(8)
              .toList();
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

  Future<List<Rect>> _requestAiBoxes(
    File photo, String label, String key, String model,
  ) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final data = base64Encode(await photo.readAsBytes());
      final reply = await (() async {
        final request = await client.postUrl(
          Uri.https('openrouter.ai', '/api/v1/chat/completions'),
        );
        request.followRedirects = false;
        request.headers.contentType = ContentType.json;
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $key');
        request.write(jsonEncode({
          'model': model,
          'max_tokens': 8192, // Room for reasoning tokens of newer models.
          'messages': [
            {
              'role': 'user',
              'content': [
                {
                  'type': 'text',
                  'text': aiBoxPrompt(label),
                },
                {
                  'type': 'image_url',
                  'image_url': {'url': 'data:image/jpeg;base64,$data'},
                },
              ],
            },
          ],
        }));
        final response = await request.close();
        if (response.statusCode != 200) {
          throw _OpenRouterException(response.statusCode);
        }
        return utf8.decoder.bind(response).join();
      })().timeout(const Duration(seconds: 45));
      return parseAiBoxes(completionText(reply));
    } finally {
      client.close(force: true);
    }
  }

  @override
  void dispose() {
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

class _DatasetGallery extends StatefulWidget {
  const _DatasetGallery();

  @override
  State<_DatasetGallery> createState() => _DatasetGalleryState();
}

class _DatasetGalleryState extends State<_DatasetGallery> {
  late Future<List<File>> _photos = _load();

  Future<List<File>> _load() async {
    final root = await getApplicationDocumentsDirectory();
    final dataset = Directory('${root.path}/training_examples');
    if (!await dataset.exists()) return [];
    final photos = await dataset
        .list(recursive: true, followLinks: false)
        .where((entry) => entry is File && entry.path.endsWith('.jpg'))
        .cast<File>()
        .toList();
    photos.sort((a, b) => a.path.compareTo(b.path));
    return photos;
  }

  bool _editing = false;
  bool _exporting = false;

  Future<bool> _confirm(String title, String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Batal'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Hapus'),
            ),
          ],
        ),
      ) ==
      true;

  Future<void> _deletePhoto(File photo) async {
    if (_editing || _exporting) return;
    if (!await _confirm('Hapus foto?', 'Foto dan anotasinya dihapus dari HP.')) return;
    try {
      for (final suffix in ['', '.json', '.vec.json']) {
        final file = File('${photo.path}$suffix');
        if (await file.exists()) await file.delete();
      }
    } catch (_) {
      _notify('Foto gagal dihapus.');
    }
    if (mounted) setState(() => _photos = _load());
  }

  Future<void> _deleteClass(String label, Directory directory) async {
    if (_editing || _exporting) return;
    if (!await _confirm('Hapus kelas "$label"?',
        'Semua foto dan anotasi kelas ini dihapus dari HP.')) {
      return;
    }
    try {
      await directory.delete(recursive: true);
    } catch (_) {
      _notify('Kelas gagal dihapus.');
    }
    if (mounted) setState(() => _photos = _load());
  }

  /// Exports annotated photos as a ZIP with YOLO labels and a COCO JSON file.
  Future<void> _export() async {
    if (_editing || _exporting) return;
    setState(() => _exporting = true);
    try {
      final photos = await _load();
      final annotated = <(File, String, List<Rect>)>[];
      for (final photo in photos) {
        final annotation = File('${photo.path}.json');
        if (!await annotation.exists()) continue;
        try {
          final label = photo.parent.uri.pathSegments.reversed
              .firstWhere((segment) => segment.isNotEmpty);
          annotated.add((photo, label, parseBoxes(await annotation.readAsString())));
        } catch (_) {
          // Damaged annotations are left out of the export.
        }
      }
      if (annotated.isEmpty) {
        _notify('Belum ada foto beranotasi untuk diekspor.');
        return;
      }
      final classes = annotated.map((item) => item.$2).toSet().toList()..sort();
      final texts = <String, String>{'data.yaml': yoloDataYaml(classes)};
      final items = <Map<String, Object>>[];
      for (final (photo, label, boxes) in annotated) {
        final base = '${label.replaceAll(' ', '_')}__'
            '${photo.uri.pathSegments.last.replaceAll('.jpg', '')}';
        final classIndex = classes.indexOf(label);
        texts['labels/$base.txt'] = yoloLabel(classIndex, boxes);
        items.add({
          'path': photo.path,
          'name': '$base.jpg',
          'classIndex': classIndex,
          'boxes': boxes.map((b) => [b.left, b.top, b.right, b.bottom]).toList(),
        });
      }
      final location = await const MethodChannel('object_detection/detector')
          .invokeMethod<String>('exportDataset', {
        'classes': classes,
        'items': items,
        'texts': texts,
        'fileName': 'dataset_${DateTime.now().millisecondsSinceEpoch}.zip',
      });
      _notify('${items.length} foto diekspor ke $location '
          '(format YOLO + COCO).');
    } catch (_) {
      _notify('Ekspor gagal. Coba lagi.');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _edit(File photo, String label) async {
    if (_editing) return;
    _editing = true;
    try {
      final annotation = File('${photo.path}.json');
      final List<Rect> boxes;
      try {
        boxes = await annotation.exists()
            ? parseBoxes(await annotation.readAsString())
            : <Rect>[];
      } catch (_) {
        _notify('Anotasi lama gagal dibaca. File asli tetap tersimpan.');
        return;
      }
      if (!mounted) return;
      final List<Rect>? result;
      try {
        result = await _openEditor(context, photo, label, boxes);
      } catch (_) {
        _notify('Foto gagal dibuka di editor.');
        return;
      }
      if (result == null) return;
      try {
        await _saveAnnotation(photo, label, result);
        if (mounted) setState(() => _photos = _load());
      } catch (_) {
        _notify('Perubahan anotasi gagal disimpan.');
      }
    } finally {
      _editing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Galeri dataset'),
        actions: [
          IconButton(
            tooltip: 'Ekspor dataset (ZIP YOLO + COCO)',
            onPressed: _exporting ? null : _export,
            icon: _exporting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.ios_share),
          ),
        ],
      ),
      body: FutureBuilder<List<File>>(
        future: _photos,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: FilledButton(
                onPressed: () => setState(() => _photos = _load()),
                child: const Text('Gagal memuat. Coba lagi'),
              ),
            );
          }
          final photos = snapshot.data;
          if (photos == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (photos.isEmpty) {
            return const Center(child: Text('Belum ada foto contoh.'));
          }
          final groups = <String, List<File>>{};
          for (final photo in photos) {
            final label = photo.parent.uri.pathSegments.reversed
                .firstWhere((segment) => segment.isNotEmpty);
            (groups[label] ??= []).add(photo);
          }
          return ListView(
            children: [
              for (final group in groups.entries)
                ExpansionTile(
                  title: Text(group.key),
                  subtitle: Text('${group.value.length} foto'),
                  trailing: IconButton(
                    tooltip: 'Hapus kelas',
                    onPressed: () => _deleteClass(group.key, group.value.first.parent),
                    icon: const Icon(Icons.delete_outline),
                  ),
                  children: [
                    for (final photo in group.value)
                      ListTile(
                        leading: Image.file(
                          photo,
                          width: 52,
                          height: 52,
                          cacheWidth: 104,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const Icon(Icons.broken_image),
                        ),
                        title: Text(photo.uri.pathSegments.last),
                        subtitle: Text(File('${photo.path}.json').existsSync()
                            ? 'Sudah dianotasi'
                            : 'Belum dianotasi'),
                        trailing: IconButton(
                          tooltip: 'Hapus foto',
                          onPressed: () => _deletePhoto(photo),
                          icon: const Icon(Icons.delete_outline),
                        ),
                        onTap: () => _edit(photo, group.key),
                      ),
                  ],
                ),
            ],
          );
        },
      ),
    );
  }
}

Future<List<Rect>?> _openEditor(
  BuildContext context, File photo, String label, List<Rect> boxes,
) async {
  final codec = await ui.instantiateImageCodec(await photo.readAsBytes());
  late final double ratio;
  try {
    final frame = await codec.getNextFrame();
    ratio = frame.image.width / frame.image.height;
    frame.image.dispose();
  } finally {
    codec.dispose();
  }
  if (!context.mounted) return null;
  return Navigator.of(context).push<List<Rect>>(
    MaterialPageRoute(
      builder: (_) => _AnnotationEditor(photo, label, boxes, ratio),
    ),
  );
}

Future<void> _saveAnnotation(File photo, String label, List<Rect> boxes) async {
  final output = File('${photo.path}.json');
  final pending = File('${output.path}.tmp');
  await pending.writeAsString(jsonEncode({
    'label': label,
    'boxes': boxes.map((r) => [r.left, r.top, r.right, r.bottom]).toList(),
  }), flush: true);
  await pending.rename(output.path);
}

class _AnnotationEditor extends StatefulWidget {
  const _AnnotationEditor(this.photo, this.label, this.boxes, this.ratio);

  final File photo;
  final String label;
  final List<Rect> boxes;
  final double ratio;

  @override
  State<_AnnotationEditor> createState() => _AnnotationEditorState();
}

class _AnnotationEditorState extends State<_AnnotationEditor> {
  late final List<Rect> _boxes = List.of(widget.boxes);
  int? _selected;
  Offset? _start;
  Rect? _original;
  Rect? _draft;
  bool _resize = false;
  bool _newBox = false;

  Offset _point(Offset p, Size size) => Offset(
    (p.dx / size.width).clamp(0.0, 1.0).toDouble(),
    (p.dy / size.height).clamp(0.0, 1.0).toDouble(),
  );

  void _begin(Offset position, Size size) {
    final p = _point(position, size);
    final selected = _selected;
    if (!_newBox && selected != null) {
      final end = _boxes[selected].bottomRight;
      final handle = Offset(end.dx * size.width, end.dy * size.height);
      if ((handle - position).distance <= 24) {
        _start = p;
        _original = _boxes[selected];
        _resize = true;
        return;
      }
    }
    final index = _newBox ? -1 : _boxes.lastIndexWhere((box) => box.contains(p));
    setState(() {
      _selected = index < 0 ? null : index;
      _original = index < 0 ? null : _boxes[index];
      _start = p;
      _resize = false;
    });
  }

  void _drag(Offset position, Size size) {
    final start = _start;
    if (start == null) return;
    final p = _point(position, size);
    final box = _original;
    setState(() {
      if (box == null) {
        _draft = Rect.fromPoints(start, p);
      } else if (_resize) {
        final x = p.dx.clamp((box.left + 0.001).clamp(0.0, 1.0), 1.0).toDouble();
        final y = p.dy.clamp((box.top + 0.001).clamp(0.0, 1.0), 1.0).toDouble();
        _draft = Rect.fromLTRB(box.left, box.top, x, y);
      } else {
        final x = (p.dx - start.dx).clamp(-box.left, 1 - box.right).toDouble();
        final y = (p.dy - start.dy).clamp(-box.top, 1 - box.bottom).toDouble();
        _draft = box.shift(Offset(x, y));
      }
    });
  }

  void _finish({bool commit = true}) {
    setState(() {
      final draft = _draft;
      final index = _selected;
      if (commit && draft != null && draft.width >= 0.001 && draft.height >= 0.001) {
        if (index == null) {
          _boxes.add(draft);
          _selected = _boxes.length - 1;
        } else {
          _boxes[index] = draft;
        }
      }
      _draft = null;
      _start = null;
      _original = null;
      _resize = false;
      _newBox = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Anotasi ${widget.label}')),
      body: SafeArea(
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('Tarik untuk menggambar atau menggeser kotak. Tarik pegangan pojok untuk mengubah ukuran.'),
            ),
            Expanded(
              child: Center(
                child: AspectRatio(
                  aspectRatio: widget.ratio,
                  child: LayoutBuilder(
                    builder: (context, limits) {
                      final size = limits.biggest;
                      final visible = List<Rect>.of(_boxes);
                      final draft = _draft;
                      final index = _selected;
                      if (draft != null) {
                        if (index == null) {
                          visible.add(draft);
                        } else {
                          visible[index] = draft;
                        }
                      }
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapUp: (e) {
                          _begin(e.localPosition, size);
                          _finish();
                        },
                        onPanStart: (e) => _begin(e.localPosition, size),
                        onPanUpdate: (e) => _drag(e.localPosition, size),
                        onPanEnd: (_) => _finish(),
                        onPanCancel: () => _finish(commit: false),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Image.file(widget.photo, fit: BoxFit.fill),
                            for (var i = 0; i < visible.length; i++)
                              Positioned.fromRect(
                                rect: Rect.fromLTRB(
                                  visible[i].left * size.width,
                                  visible[i].top * size.height,
                                  visible[i].right * size.width,
                                  visible[i].bottom * size.height,
                                ),
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                      color: i == index ? Colors.amber : Colors.greenAccent,
                                      width: 2,
                                    ),
                                  ),
                                  child: i == index
                                      ? const Align(
                                          alignment: Alignment.bottomRight,
                                          child: SizedBox(
                                            width: 10, height: 10,
                                            child: ColoredBox(color: Colors.amber),
                                          ),
                                        )
                                      : null,
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: () => setState(() {
                    _newBox = true;
                    _selected = null;
                  }),
                  child: Text(_newBox ? 'Tarik kotak baru' : 'Tambah kotak'),
                ),
                TextButton(
                  onPressed: _selected == null ? null : () => setState(() {
                    _boxes.removeAt(_selected!);
                    _selected = null;
                  }),
                  child: const Text('Hapus kotak'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, _boxes),
                  child: Text('Simpan (${_boxes.length})'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _OpenRouterSettingsDialog extends StatefulWidget {
  const _OpenRouterSettingsDialog(this.keyValue, this.model, this.defaultModel);

  final String keyValue;
  final String model;
  final String defaultModel;

  @override
  State<_OpenRouterSettingsDialog> createState() => _OpenRouterSettingsDialogState();
}

class _OpenRouterSettingsDialogState extends State<_OpenRouterSettingsDialog> {
  late final _key = TextEditingController(text: widget.keyValue);
  late final _model = TextEditingController(text: widget.model);
  final _form = GlobalKey<FormState>();

  @override
  void dispose() {
    _key.dispose();
    _model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Pengaturan OpenRouter'),
      scrollable: true,
      content: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _key,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'API key',
                suffixIcon: IconButton(
                  tooltip: 'Kosongkan API key',
                  onPressed: _key.clear,
                  icon: const Icon(Icons.clear),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _model,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'ID model vision'),
              validator: (value) {
                final id = value?.trim() ?? '';
                if (!RegExp(r'^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.:-]+$').hasMatch(id)) {
                  return 'Gunakan format penyedia/nama-model.';
                }
                return null;
              },
            ),
            TextButton(
              onPressed: () => _model.text = widget.defaultModel,
              child: const Text('Gunakan model bawaan'),
            ),
            const Text('Pilih model yang menerima input foto, sebaiknya keluarga Gemini atau Qwen-VL. Pengaturan disimpan di HP.'),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Batal'),
        ),
        FilledButton(
          onPressed: () {
            if (!_form.currentState!.validate()) return;
            Navigator.pop(context, (_key.text.trim(), _model.text.trim()));
          },
          child: const Text('Simpan'),
        ),
      ],
    );
  }
}

class _OpenRouterException implements Exception {
  const _OpenRouterException(this.status);

  final int status;
}

class _ExampleLabelDialog extends StatefulWidget {
  const _ExampleLabelDialog();

  @override
  State<_ExampleLabelDialog> createState() => _ExampleLabelDialogState();
}

class _ExampleLabelDialogState extends State<_ExampleLabelDialog> {
  String _label = '';

  bool get _valid =>
      RegExp(r'^[a-z0-9]+([ _-][a-z0-9]+)*$').hasMatch(_label);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Pilih nama objek'),
      content: TextField(
        autofocus: true,
        maxLength: 40,
        decoration: const InputDecoration(
          labelText: 'Nama objek',
          hintText: 'Contoh: helm proyek',
          helperText: 'Arahkan kamera ke objek sebelum mengambil foto.',
        ),
        onChanged: (value) {
          setState(() => _label = value.trim().toLowerCase());
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Batal'),
        ),
        FilledButton(
          onPressed: _valid ? () => Navigator.pop(context, _label) : null,
          child: const Text('Ambil foto'),
        ),
      ],
    );
  }
}

class _Detection {
  const _Detection(this.box, this.label, this.score, this.appearance, {this.local = false});

  factory _Detection.fromMap(Map<Object?, Object?> map) {
    double number(String key) => (map[key] as num).toDouble();
    return _Detection(
      Rect.fromLTRB(
        number('left'),
        number('top'),
        number('right'),
        number('bottom'),
      ),
      map['label'] as String,
      number('score'),
      ((map['appearance'] as List?) ?? const [])
          .cast<num>()
          .map((value) => value.toDouble())
          .toList(),
    );
  }

  final Rect box;
  final String label;
  final double score;
  final List<double> appearance;
  final bool local;
}

class _Overlay extends CustomPainter {
  const _Overlay(this.detections, {this.focus = false});

  final bool focus;

  final List<_Detection> detections;
  static const _accent = Color(0xff79ebbb);

  @override
  void paint(Canvas canvas, Size size) {
    if (focus && detections.isEmpty) {
      canvas.drawRect(
        Rect.fromLTRB(size.width * .2, size.height * .3, size.width * .8, size.height * .7),
        Paint()
          ..color = Colors.white70
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
    if (size.isEmpty) return;
    final border = Paint()
      ..color = _accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final fill = Paint()..color = _accent;
    for (final detection in detections) {
      final box = detection.box;
      final rect = Rect.fromLTRB(
        box.left * size.width,
        box.top * size.height,
        box.right * size.width,
        box.bottom * size.height,
      ).intersect(Offset.zero & size);
      if (rect.isEmpty) continue;
      canvas.drawRect(rect, border);
      final label = cocoLabelsId[detection.label] ?? detection.label;
      final text = TextPainter(
        text: TextSpan(
          text: detection.local ? '$label · contoh' : '$label ${(100 * detection.score).round()}%',
          style: const TextStyle(color: Colors.black, fontSize: 13),
        ),
        maxLines: 1,
        ellipsis: '…',
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: (size.width - 8).clamp(0.0, size.width).toDouble());
      final tagWidth = text.width + 8;
      final x = rect.left
          .clamp(0.0, (size.width - tagWidth).clamp(0.0, size.width))
          .toDouble();
      final y = (rect.top - text.height - 4).clamp(0.0, size.height).toDouble();
      canvas.drawRect(Rect.fromLTWH(x, y, tagWidth, text.height + 4), fill);
      text.paint(canvas, Offset(x + 4, y + 2));
      text.dispose();
    }
  }

  @override
  bool shouldRepaint(_Overlay oldDelegate) =>
      detections != oldDelegate.detections || focus != oldDelegate.focus;
}
