import 'package:flutter_secure_storage/flutter_secure_storage.dart';

enum AiProvider { chatgpt, openai, anthropic }

/// AI connection settings. API keys live in the phone's encrypted storage
/// (Android Keystore), never in project files.
class AiSettings {
  static const _store = FlutterSecureStorage();

  AiProvider provider = AiProvider.openai;
  String openaiKey = '';
  String anthropicKey = '';
  String openaiModel = defaultOpenaiModel;
  String anthropicModel = defaultAnthropicModel;
  bool shareMedia = true;
  String captionLanguage = 'hi';
  bool captionsRoman = false;
  String imageModel = 'gpt-image-1';
  String speechEngine = 'device'; // device | openai
  String whisperModel = 'base'; // tiny | base | small
  String styleNotes = ''; // Director: the channel's editing style, in the user's words

  static const defaultOpenaiModel = 'gpt-5-mini';
  static const defaultAnthropicModel = 'claude-sonnet-5-5';

  bool chatgptConnected = false;
  String chatgptModel = '';

  String get apiKey => provider == AiProvider.openai ? openaiKey : anthropicKey;
  String get model => switch (provider) {
        AiProvider.chatgpt => chatgptModel.isEmpty ? 'ChatGPT plan' : chatgptModel,
        AiProvider.openai => openaiModel,
        AiProvider.anthropic => anthropicModel,
      };
  bool get isConfigured => provider == AiProvider.chatgpt ? chatgptConnected : apiKey.trim().isNotEmpty;
  String get providerLabel => switch (provider) {
        AiProvider.chatgpt => 'ChatGPT plan',
        AiProvider.openai => 'OpenAI API',
        AiProvider.anthropic => 'Claude API',
      };

  static AiSettings? _cached;

  static Future<AiSettings> load() async {
    if (_cached != null) return _cached!;
    final s = AiSettings();
    try {
      final all = await _store.readAll();
      s.provider = AiProvider.values.firstWhere((p) => p.name == all['provider'], orElse: () => AiProvider.chatgpt);
      s.chatgptConnected = all['cg_refresh'] != null;
      s.chatgptModel = all['cg_model'] ?? '';
      s.openaiKey = all['openaiKey'] ?? '';
      s.anthropicKey = all['anthropicKey'] ?? '';
      s.openaiModel = (all['openaiModel'] ?? '').isEmpty ? defaultOpenaiModel : all['openaiModel']!;
      s.anthropicModel = (all['anthropicModel'] ?? '').isEmpty ? defaultAnthropicModel : all['anthropicModel']!;
      s.shareMedia = all['shareMedia'] != 'false';
      s.captionLanguage = all['captionLanguage'] ?? 'hi';
      s.captionsRoman = all['captionsRoman'] == 'true';
      s.speechEngine = all['speechEngine'] ?? 'device';
      s.whisperModel = all['whisperModel'] ?? 'base';
      s.styleNotes = all['styleNotes'] ?? '';
    } catch (_) {
      // First run or storage unavailable: defaults.
    }
    _cached = s;
    return s;
  }

  Future<void> save() async {
    _cached = this;
    await _store.write(key: 'provider', value: provider.name);
    await _store.write(key: 'openaiKey', value: openaiKey.trim());
    await _store.write(key: 'anthropicKey', value: anthropicKey.trim());
    await _store.write(key: 'openaiModel', value: openaiModel.trim());
    await _store.write(key: 'anthropicModel', value: anthropicModel.trim());
    await _store.write(key: 'shareMedia', value: '$shareMedia');
    await _store.write(key: 'captionLanguage', value: captionLanguage);
    await _store.write(key: 'captionsRoman', value: '$captionsRoman');
    await _store.write(key: 'speechEngine', value: speechEngine);
    await _store.write(key: 'whisperModel', value: whisperModel);
    await _store.write(key: 'styleNotes', value: styleNotes);
  }
}
