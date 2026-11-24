part of '../../main.dart';

/// Edits [DetectionSettings]; returns the new settings when the page closes.
class _DetectionSettingsPage extends StatefulWidget {
  const _DetectionSettingsPage(this.initial, this.classes);

  final DetectionSettings initial;
  final List<String> classes;

  @override
  State<_DetectionSettingsPage> createState() => _DetectionSettingsPageState();
}

class _DetectionSettingsPageState extends State<_DetectionSettingsPage> {
  late DetectionSettings _settings = widget.initial;
  String _filter = '';

  void _update(DetectionSettings settings) => setState(() => _settings = settings);

  void _setLabel(String label, bool visible) {
    final hidden = {..._settings.hiddenLabels};
    visible ? hidden.remove(label) : hidden.add(label);
    _update(_settings.copyWith(hiddenLabels: hidden));
  }

  @override
  Widget build(BuildContext context) {
    final (low, high) = DetectionSettings.minScoreRange;
    final classes = [...widget.classes]
      ..sort((a, b) => displayLabel(a).toLowerCase().compareTo(displayLabel(b).toLowerCase()));
    final query = _filter.trim().toLowerCase();
    final shown = classes
        .where((label) =>
            query.isEmpty ||
            label.toLowerCase().contains(query) ||
            displayLabel(label).toLowerCase().contains(query))
        .toList();
    return PopScope<DetectionSettings>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_settings);
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Pengaturan deteksi')),
        body: ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            ListTile(
              title: const Text('Ambang keyakinan'),
              subtitle: Text(
                'Kotak dengan skor di bawah ${(100 * _settings.minScore).round()}% disembunyikan. '
                'Kecocokan dengan foto contoh selalu tampil.',
              ),
            ),
            Slider(
              value: _settings.minScore,
              min: low,
              max: high,
              divisions: ((high - low) * 20).round(),
              label: '${(100 * _settings.minScore).round()}%',
              onChanged: (value) => _update(_settings.copyWith(minScore: value)),
            ),
            const ListTile(
              title: Text('Batas frame per detik'),
              subtitle: Text('Lebih rendah = baterai lebih awet dan HP tidak cepat panas.'),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SegmentedButton<int>(
                segments: [
                  for (final fps in DetectionSettings.fpsChoices)
                    ButtonSegment(value: fps, label: Text(fps == 0 ? 'Maks' : '$fps')),
                ],
                selected: {_settings.maxFps},
                onSelectionChanged: (choice) =>
                    _update(_settings.copyWith(maxFps: choice.single)),
              ),
            ),
            SwitchListTile(
              title: const Text('Sertakan lokasi GPS di foto'),
              subtitle: const Text(
                'Memakai lokasi terakhir yang diketahui HP. Izin lokasi diminta saat pertama menyimpan foto.',
              ),
              value: _settings.includeLocation,
              onChanged: (value) => _update(_settings.copyWith(includeLocation: value)),
            ),
            const Divider(),
            ListTile(
              title: const Text('Kelas yang ditampilkan'),
              subtitle: Text(
                '${classes.where(_settings.shows).length} dari ${classes.length} kelas aktif',
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: 'Cari kelas',
                      ),
                      onChanged: (value) => setState(() => _filter = value),
                    ),
                  ),
                  TextButton(
                    onPressed: () => _update(_settings.copyWith(hiddenLabels: {})),
                    child: const Text('Semua'),
                  ),
                  TextButton(
                    onPressed: () =>
                        _update(_settings.copyWith(hiddenLabels: {...classes})),
                    child: const Text('Tidak ada'),
                  ),
                ],
              ),
            ),
            for (final label in shown)
              CheckboxListTile(
                dense: true,
                title: Text(displayLabel(label)),
                subtitle: displayLabel(label) == label ? null : Text(label),
                value: _settings.shows(label),
                onChanged: (value) => _setLabel(label, value ?? true),
              ),
          ],
        ),
      ),
    );
  }
}
