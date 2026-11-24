import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

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
  CameraController? _camera;
  Future<void> _cameraWork = Future<void>.value();
  bool _active = true;
  bool _busy = false;
  bool _collecting = false;
  String? _exampleLabel;
  static const _defaultOpenRouterModel = 'google/gemini-2.5-flash';
  String? _openRouterKey;
  String _openRouterModel = _defaultOpenRouterModel;

  Future<void> _openRouterSettings() async {
    final configuration = await showDialog<(String, String)>(
      context: context,
      builder: (_) => _OpenRouterSettingsDialog(
        _openRouterKey ?? '',
        _openRouterModel,
        _defaultOpenRouterModel,
      ),
    );
    if (!mounted || configuration == null) return;
    setState(() {
      final (key, model) = configuration;
      _openRouterKey = key.isEmpty ? null : key;
      _openRouterModel = model;
    });
  }
  int _generation = 0;
  String? _error;
  List<_Detection> _detections = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scheduleCamera();
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
          });
      if (_current(generation)) {
        setState(() {
          _detections = (result ?? []).map(_Detection.fromMap).toList();
        });
      }
    } catch (error) {
      if (_current(generation)) {
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
          'max_tokens': 2048,
          'messages': [
            {
              'role': 'user',
              'content': [
                {
                  'type': 'text',
                  'text': 'Find visible instances of the object class "$label". '
                      'A face is a generic class. Never identify a person. '
                      'Return only JSON {"boxes":[[left,top,right,bottom]]}. '
                      'Coordinates are numbers between 0 and 1 relative to the '
                      'full image. If none is visible, return {"boxes":[]}.',
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
      final envelope = jsonDecode(reply) as Map<String, dynamic>;
      final choices = envelope['choices'] as List<dynamic>;
      final content = (choices.first['message']['content'] as String).trim();
      final json = content
          .replaceFirst(RegExp(r'^\s*```(?:json)?\s*'), '')
          .replaceFirst(RegExp(r'\s*```\s*$'), '');
      return _parseBoxes(json, limit: true);
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
            onPressed: _collecting ? null : () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const _DatasetGallery()),
            ),
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
                          child: CustomPaint(painter: _Overlay(_detections)),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      _detections.isEmpty
                          ? 'Arahkan kamera ke objek'
                          : '${_detections.length} objek terdeteksi',
                      style: const TextStyle(color: Colors.white),
                    ),
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

List<Rect> _parseBoxes(String json, {bool limit = false}) {
  final rows = (jsonDecode(json) as Map<String, dynamic>)['boxes'] as List;
  if (limit && rows.length > 50) throw const FormatException('Too many boxes');
  return rows.map((row) {
    if (row is! List || row.length != 4 ||
        row.any((v) => v is! num || !v.isFinite || v < 0 || v > 1)) {
      throw const FormatException('Invalid coordinates');
    }
    final values = row.cast<num>().map((v) => v.toDouble()).toList();
    final box = Rect.fromLTRB(values[0], values[1], values[2], values[3]);
    if (box.isEmpty) throw const FormatException('Empty box');
    return box;
  }).toList();
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

  Future<void> _edit(File photo, String label) async {
    try {
      final annotation = File('${photo.path}.json');
      final boxes = await annotation.exists()
          ? _parseBoxes(await annotation.readAsString())
          : <Rect>[];
      if (!mounted) return;
      final result = await _openEditor(context, photo, label, boxes);
      if (result == null) return;
      await _saveAnnotation(photo, label, result);
      if (mounted) setState(() => _photos = _load());
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Foto atau anotasi gagal dibuka atau disimpan.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Galeri dataset')),
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
                        trailing: const Icon(Icons.edit_outlined),
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
            const Text('Pilih model yang menerima input foto. Pengaturan berlaku selama app terbuka.'),
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
  const _Detection(this.box, this.label, this.score);

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
    );
  }

  final Rect box;
  final String label;
  final double score;
}

class _Overlay extends CustomPainter {
  const _Overlay(this.detections);

  final List<_Detection> detections;
  static const _accent = Color(0xff79ebbb);
  static const _labels = {
    'person': 'Orang',
    'car': 'Mobil',
    'motorcycle': 'Motor',
    'bottle': 'Botol',
    'chair': 'Kursi',
    'cup': 'Cangkir',
    'cell phone': 'Ponsel',
  };

  @override
  void paint(Canvas canvas, Size size) {
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
      final label = _labels[detection.label] ?? detection.label;
      final text = TextPainter(
        text: TextSpan(
          text: '$label ${(100 * detection.score).round()}%',
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
      detections != oldDelegate.detections;
}
