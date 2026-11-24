part of '../../main.dart';

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
