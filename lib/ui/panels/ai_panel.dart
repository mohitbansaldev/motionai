import 'package:flutter/material.dart';

import '../../ai/agent.dart';
import '../../ai/ai_client.dart';
import '../../ai/ai_settings.dart';
import '../../remote/remote_ui.dart'; // MCP (Agent P)
import '../../ai/chatgpt_auth.dart';
import '../../state/editor_controller.dart';
import '../common.dart';
import '../script_sheet.dart';
import '../director_screen.dart';
import '../theme.dart';
import '../../services/speech.dart';

/// Chat with the AI edit assistant.
class AiPanel extends StatefulWidget {
  final EditorController c;
  final EditAgent agent;
  final VoidCallback? onCaptions;
  const AiPanel({super.key, required this.c, required this.agent, this.onCaptions});

  @override
  State<AiPanel> createState() => _AiPanelState();
}

class _AiPanelState extends State<AiPanel> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  AiSettings? _settings;

  static const _suggestions = [
    'Make a 20-second cinematic documentary intro from my photos with slow parallax and a title',
    'Add a Ken Burns zoom to every photo and crossfade between them',
    'Add a bold title "Episode 1" with word pop animation at the start',
    'Grade everything like a dark documentary',
    'Turn this into a fast 9:16 Shorts edit',
  ];

  @override
  void initState() {
    super.initState();
    AiSettings.load().then((s) {
      if (mounted) setState(() => _settings = s);
    });
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send([String? text]) async {
    final msg = (text ?? _input.text).trim();
    if (msg.isEmpty || widget.agent.busy) return;
    final s = _settings ?? await AiSettings.load();
    if (!s.isConfigured) {
      if (mounted) await _openSettings();
      if (!(await AiSettings.load()).isConfigured) return;
    }
    _input.clear();
    setState(() {});
    final f = widget.agent.send(msg);
    setState(() {});
    _toBottom();
    await f;
    if (mounted) setState(() {});
    _toBottom();
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    });
  }

  Future<void> _openSettings() async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => const AiSettingsSheet(),
    );
    final s = await AiSettings.load();
    if (mounted) setState(() => _settings = s);
  }

  @override
  Widget build(BuildContext context) {
    final log = widget.agent.log;
    final s = _settings;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 0),
        child: Row(children: [
          const Icon(Icons.auto_awesome, size: 18, color: Colors.amber),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              s == null
                  ? 'AI assistant'
                  : s.isConfigured
                      ? 'AI · ${s.providerLabel} · ${s.model}'
                      : 'AI · connect ChatGPT or add an API key',
              style: const TextStyle(fontSize: 12.5, color: Colors.white70),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton.icon(
            onPressed: () => DirectorScreen.open(context, widget.c),
            icon: const Icon(Icons.movie_filter_outlined, size: 18, color: MA.gold),
            label: const Text('Director'),
          ),
          IconButton(
            tooltip: 'Script → Video',
            onPressed: () => ScriptSheet.open(context, widget.c),
            icon: const Icon(Icons.description_outlined, size: 20),
          ),
          if (widget.onCaptions != null)
            IconButton(
              tooltip: 'Captions',
              onPressed: widget.onCaptions,
              icon: const Icon(Icons.closed_caption_outlined, size: 20),
            ),
          IconButton(icon: const Icon(Icons.settings_outlined, size: 20), onPressed: _openSettings),
        ]),
      ),
      Expanded(
        child: log.isEmpty
            ? ListView(padding: const EdgeInsets.all(12), children: [
                const Text('Tell the AI what to make or change. It edits the timeline directly, and one Undo reverts it.',
                    style: TextStyle(color: Colors.white54, fontSize: 12.5)),
                const SizedBox(height: 10),
                for (final sug in _suggestions)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: ActionChip(
                      label: Text(sug, style: const TextStyle(fontSize: 12)),
                      onPressed: () => _send(sug),
                    ),
                  ),
              ])
            : ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.all(10),
                itemCount: log.length + (widget.agent.busy ? 1 : 0),
                itemBuilder: (context, i) {
                  if (i == log.length) {
                    return const Padding(
                      padding: EdgeInsets.all(8),
                      child: Row(children: [
                        SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                        SizedBox(width: 10),
                        Text('Editing…', style: TextStyle(color: Colors.white54)),
                      ]),
                    );
                  }
                  return _bubble(log[i]);
                },
              ),
      ),
      SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 4, 6, 6),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                decoration: const InputDecoration(
                  hintText: 'Describe the edit…',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            IconButton(
              icon: widget.agent.busy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send),
              onPressed: widget.agent.busy ? null : _send,
            ),
          ]),
        ),
      ),
    ]);
  }

  Widget _bubble(ChatEntry e) {
    final canUndo = e.undoMark != null && widget.c.undoDepth == e.undoMark;
    return Align(
      alignment: e.fromUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(10),
        constraints: const BoxConstraints(maxWidth: 320),
        decoration: BoxDecoration(
          color: e.fromUser
              ? const Color(0xFF2B3442)
              : e.isError
                  ? const Color(0xFF3A1D1D)
                  : const Color(0xFF1E2127),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SelectableText(e.text, style: const TextStyle(fontSize: 13)),
          if (e.applied > 0)
            Row(mainAxisSize: MainAxisSize.min, children: [
              Text('${e.applied} change${e.applied == 1 ? '' : 's'}',
                  style: const TextStyle(fontSize: 11, color: Colors.white54)),
              if (canUndo)
                TextButton(
                  onPressed: () {
                    widget.c.undo();
                    setState(() {});
                    showSnack(context, 'AI edit undone');
                  },
                  child: const Text('Undo'),
                ),
            ]),
        ]),
      ),
    );
  }
}

/// Provider, API key and model settings.
class AiSettingsSheet extends StatefulWidget {
  const AiSettingsSheet({super.key});
  @override
  State<AiSettingsSheet> createState() => _AiSettingsSheetState();
}

class _AiSettingsSheetState extends State<AiSettingsSheet> {
  AiSettings? s;
  final _openaiKey = TextEditingController();
  final _anthropicKey = TextEditingController();
  final _openaiModel = TextEditingController();
  final _anthropicModel = TextEditingController();

  @override
  void initState() {
    super.initState();
    AiSettings.load().then((v) {
      if (!mounted) return;
      setState(() {
        s = v;
        _openaiKey.text = v.openaiKey;
        _anthropicKey.text = v.anthropicKey;
        _openaiModel.text = v.openaiModel;
        _anthropicModel.text = v.anthropicModel;
      });
      _loadChatgpt();
    });
  }

  @override
  void dispose() {
    for (final c in [_openaiKey, _anthropicKey, _openaiModel, _anthropicModel]) {
      c.dispose();
    }
    super.dispose();
  }

  bool _connecting = false;
  String? _cgError;
  String? _cgEmail;
  List<String> _cgModels = const [];

  Future<void> _loadChatgpt() async {
    _cgEmail = await ChatGptAuth.email;
    if (s!.chatgptConnected) {
      try {
        _cgModels = await ChatGptAuth.models();
      } catch (e) {
        _cgError = '$e';
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _connect() async {
    setState(() {
      _connecting = true;
      _cgError = null;
    });
    try {
      await ChatGptAuth.signIn();
      s!.chatgptConnected = true;
      await _loadChatgpt();
    } on AiException catch (e) {
      _cgError = e.message;
    } catch (e) {
      _cgError = '$e';
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Widget _chatgptBox(AiSettings v) {
    return Container(
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(color: const Color(0xFF1C1F27), borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (!v.chatgptConnected) ...[
          const Text('Use your ChatGPT Plus or Pro plan — no API key needed. '
              'You sign in on OpenAI\'s page and choose how much of your plan MotionAI may use.',
              style: TextStyle(fontSize: 12.5, color: Colors.white70)),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black),
              onPressed: _connecting ? null : _connect,
              icon: _connecting
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.bolt),
              label: const Text('Continue with ChatGPT'),
            ),
          ),
        ] else ...[
          Row(children: [
            const Icon(Icons.check_circle, color: Colors.greenAccent, size: 18),
            const SizedBox(width: 6),
            Expanded(child: Text('Connected${_cgEmail == null ? '' : ' as $_cgEmail'}')),
            TextButton(
              onPressed: () async {
                await ChatGptAuth.signOut();
                setState(() => v.chatgptConnected = false);
              },
              child: const Text('Disconnect'),
            ),
          ]),
          if (_cgModels.isNotEmpty)
            DropdownButton<String>(
              isExpanded: true,
              value: _cgModels.contains(v.chatgptModel) ? v.chatgptModel : null,
              hint: const Text('Model (auto)'),
              items: [for (final m in _cgModels) DropdownMenuItem(value: m, child: Text(ChatGptAuth.displayName(m)))],
              onChanged: (m) async {
                if (m == null) return;
                await ChatGptAuth.setModel(m);
                setState(() => v.chatgptModel = m);
              },
            ),
        ],
        if (_cgError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_cgError!, style: const TextStyle(color: Colors.redAccent, fontSize: 12.5)),
          ),
      ]),
    );
  }

  Future<void> _save() async {
    final v = s!;
    v.openaiKey = _openaiKey.text;
    v.anthropicKey = _anthropicKey.text;
    v.openaiModel = _openaiModel.text.trim().isEmpty ? AiSettings.defaultOpenaiModel : _openaiModel.text.trim();
    v.anthropicModel =
        _anthropicModel.text.trim().isEmpty ? AiSettings.defaultAnthropicModel : _anthropicModel.text.trim();
    await v.save();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final v = s;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: v == null
          ? const SizedBox(height: 120, child: Center(child: CircularProgressIndicator()))
          : SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('AI settings', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                const Text(
                  'Use your ChatGPT Plus/Pro plan, or your own API key. Credentials are stored encrypted on this phone only. '
                  'Speech-to-text (captions, transcripts) runs on your phone for free.',
                  style: TextStyle(fontSize: 12, color: Colors.white60),
                ),
                const SizedBox(height: 12),
                SegmentedButton<AiProvider>(
                  segments: const [
                    ButtonSegment(value: AiProvider.chatgpt, label: Text('ChatGPT plan')),
                    ButtonSegment(value: AiProvider.openai, label: Text('OpenAI key')),
                    ButtonSegment(value: AiProvider.anthropic, label: Text('Claude key')),
                  ],
                  selected: {v.provider},
                  onSelectionChanged: (sel) => setState(() => v.provider = sel.first),
                ),
                const SizedBox(height: 12),
                if (v.provider == AiProvider.chatgpt) _chatgptBox(v),
                TextField(
                  controller: _openaiKey,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'OpenAI API key', border: OutlineInputBorder(), isDense: true),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _openaiModel,
                  decoration: const InputDecoration(labelText: 'OpenAI model', border: OutlineInputBorder(), isDense: true),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _anthropicKey,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Anthropic (Claude) API key', border: OutlineInputBorder(), isDense: true),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _anthropicModel,
                  decoration: const InputDecoration(labelText: 'Claude model', border: OutlineInputBorder(), isDense: true),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Let the AI see my media'),
                  subtitle: const Text('Sends small thumbnails so it can choose shots', style: TextStyle(fontSize: 12)),
                  value: v.shareMedia,
                  onChanged: (b) => setState(() => v.shareMedia = b),
                ),
                const SizedBox(height: 4),
                const Text('Speech-to-text', style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'device', label: Text('On this phone (free)')),
                    ButtonSegment(value: 'openai', label: Text('OpenAI key')),
                  ],
                  selected: {v.speechEngine},
                  onSelectionChanged: (sel) => setState(() => v.speechEngine = sel.first),
                ),
                if (v.speechEngine == 'device') ...[
                  const SizedBox(height: 6),
                  Wrap(spacing: 8, children: [
                    for (final m in const ['tiny', 'base', 'small'])
                      ChoiceChip(
                        label: Text(Speech.modelLabel(m)),
                        selected: v.whisperModel == m,
                        onSelected: (_) => setState(() => v.whisperModel = m),
                      ),
                  ]),
                  const Text('The model downloads once on first use. "Accurate" is best for Hindi but slower.',
                      style: TextStyle(fontSize: 11.5, color: Colors.white54)),
                ],
                // MCP (Agent P) >>>
                const Divider(height: 28),
                const ClaudeControlSection(),
                // <<< MCP (Agent P)
                const SizedBox(height: 8),
                SizedBox(width: double.infinity, child: FilledButton(onPressed: _save, child: const Text('Save'))),
              ]),
            ),
    );
  }
}
