part of '../../main.dart';

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
