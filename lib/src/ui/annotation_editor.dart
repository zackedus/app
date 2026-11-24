part of '../../main.dart';

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
