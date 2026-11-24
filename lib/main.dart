import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
