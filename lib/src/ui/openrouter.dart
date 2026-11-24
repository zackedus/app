part of '../../main.dart';

/// Asks an OpenRouter vision model for boxes of [label] in [photo].
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
