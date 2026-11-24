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
  String? _openRouterKey;
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

  Future<void> _collectExample() async {
    if (_collecting) return;
    setState(() => _collecting = true);
    try {
      final label = await showDialog<String>(
        context: context,
        builder: (context) => const _ExampleLabelDialog(),
      );
      if (!mounted || label == null) return;
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
    var key = _openRouterKey ?? '';
    final send = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Anotasi dengan OpenRouter'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Hanya foto ini yang dikirim ke OpenRouter dan penyedia model. '
              'Gunakan foto orang yang sudah memberi izin. Penggunaan API bisa dikenai biaya.',
            ),
            if (_openRouterKey == null)
              TextField(
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(labelText: 'API key OpenRouter'),
                onChanged: (value) => key = value.trim(),
              ),
          ],
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
    if (key.isEmpty) return 'Foto tersimpan. API key OpenRouter belum diisi.';

    try {
      final boxes = await _requestAiBoxes(photo, label, key);
      if (!mounted) return null;
      _openRouterKey = key;
      if (boxes.isEmpty) return 'Foto tersimpan. AI tidak menemukan objek.';
      final codec = await ui.instantiateImageCodec(await photo.readAsBytes());
      final frame = await codec.getNextFrame();
      final ratio = frame.image.width / frame.image.height;
      frame.image.dispose();
      codec.dispose();
      if (!mounted) return null;

      final approve = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Periksa kotak: $label'),
          content: AspectRatio(
            aspectRatio: ratio,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.file(photo, fit: BoxFit.fill),
                LayoutBuilder(
                  builder: (context, constraints) => Stack(
                    children: [
                      for (final box in boxes)
                        Positioned(
                          left: box.left * constraints.maxWidth,
                          top: box.top * constraints.maxHeight,
                          width: box.width * constraints.maxWidth,
                          height: box.height * constraints.maxHeight,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.greenAccent, width: 3),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Tolak'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Simpan anotasi'),
            ),
          ],
        ),
      );
      if (approve != true) return 'Foto tersimpan tanpa anotasi.';
      final output = File('${photo.path}.json');
      final pending = File('${output.path}.tmp');
      await pending.writeAsString(jsonEncode({
        'label': label,
        'boxes': boxes
            .map((box) => [box.left, box.top, box.right, box.bottom])
            .toList(),
      }), flush: true);
      await pending.rename(output.path);
      return 'Foto dan ${boxes.length} anotasi tersimpan di HP.';
    } on _OpenRouterException catch (error) {
      if (error.status == 401 || error.status == 403) _openRouterKey = null;
      return 'Foto tersimpan. OpenRouter mengembalikan HTTP ${error.status}.';
    } catch (_) {
      return 'Foto tersimpan. Anotasi AI gagal. Periksa koneksi dan coba lagi.';
    }
  }

  Future<List<Rect>> _requestAiBoxes(File photo, String label, String key) async {
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
          'model': 'google/gemini-2.5-flash',
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
      final rows = (jsonDecode(json) as Map<String, dynamic>)['boxes'] as List;
      if (rows.length > 50) throw const FormatException('Too many boxes');
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
            tooltip: 'Ajari objek baru',
            onPressed: _collecting ||
                    error != null ||
                    camera == null ||
                    !camera.value.isInitialized
                ? null
                : _collectExample,
            icon: const Icon(Icons.add_a_photo_outlined),
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
                ],
              ),
      ),
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
      title: const Text('Ajari objek baru'),
      content: TextField(
        autofocus: true,
        maxLength: 40,
        decoration: const InputDecoration(
          labelText: 'Nama objek',
          hintText: 'Contoh: helm proyek',
          helperText: 'Gunakan huruf A–Z dan angka.',
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
