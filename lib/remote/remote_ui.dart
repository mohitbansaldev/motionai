// MCP (Agent P): Settings section "Claude control", the "Claude connected"
// badge and the log of what Claude did.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ui/theme.dart';
import 'remote_control.dart';

RemoteControl get _rc => RemoteControl.instance;

void _copy(BuildContext context, String text, String what) {
  Clipboard.setData(ClipboardData(text: text));
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('$what copied')));
}

String _clock(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

/// Wraps the whole app: shows a "Claude connected" pill while Claude is using it.
class RemoteBadge extends StatelessWidget {
  final Widget child;
  const RemoteBadge({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      Positioned.fill(child: child),
      AnimatedBuilder(
        animation: _rc,
        builder: (context, _) {
          if (!_rc.connected) return const SizedBox.shrink();
          final last = _rc.log.isEmpty ? null : _rc.log.first;
          return Positioned(
            top: MediaQuery.paddingOf(context).top + 6,
            left: 0,
            right: 0,
            child: Center(
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () {
                    final ctx = _rc.navigatorKey.currentContext;
                    if (ctx != null) RemoteLogSheet.open(ctx);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xFFD97757).withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 8)],
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.smart_toy_outlined, size: 15, color: Colors.white),
                      const SizedBox(width: 6),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 420),
                        child: Text(
                          last == null ? 'Claude connected' : 'Claude connected · ${last.tool.replaceAll('_', ' ')}',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ]),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    ]);
  }
}

/// Everything Claude did, newest first.
class RemoteLogSheet extends StatelessWidget {
  const RemoteLogSheet({super.key});

  static Future<void> open(BuildContext context) => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (_) => const FractionallySizedBox(heightFactor: 0.7, child: RemoteLogSheet()),
      );

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _rc,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('What Claude did${_rc.client == null ? '' : ' · ${_rc.client}'}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          const Text('Every edit is a normal undo step: press Undo (Ctrl+Z) to take it back.', style: TextStyle(color: MA.textDim, fontSize: 12)),
          const SizedBox(height: 8),
          Expanded(
            child: _rc.log.isEmpty
                ? const Center(child: Text('Nothing yet.', style: TextStyle(color: MA.textDim)))
                : ListView(children: [for (final e in _rc.log) _LogRow(e)]),
          ),
        ]),
      ),
    );
  }
}

class _LogRow extends StatelessWidget {
  final RemoteLogEntry e;
  const _LogRow(this.e);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(e.ok ? Icons.check_circle_outline : Icons.error_outline, size: 15, color: e.ok ? Colors.greenAccent : Colors.redAccent),
          const SizedBox(width: 8),
          Text(_clock(e.time), style: const TextStyle(fontSize: 11.5, color: MA.textDim, fontFeatures: [FontFeature.tabularFigures()])),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: e.tool.replaceAll('_', ' '), style: const TextStyle(fontWeight: FontWeight.w700)),
                if (e.summary.isNotEmpty) TextSpan(text: '  ${e.summary}', style: const TextStyle(color: MA.textDim)),
              ]),
              style: const TextStyle(fontSize: 12.5),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ]),
      );
}

/// Opens the Claude control settings as a sheet (home screen button).
class ClaudeControlSheet {
  static Future<void> open(BuildContext context) => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (ctx) => Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
          child: const SingleChildScrollView(child: ClaudeControlSection()),
        ),
      );
}

/// "Claude control" settings: on/off, connect buttons, token, port, log.
class ClaudeControlSection extends StatefulWidget {
  const ClaudeControlSection({super.key});

  @override
  State<ClaudeControlSection> createState() => _ClaudeControlSectionState();
}

class _ClaudeControlSectionState extends State<ClaudeControlSection> {
  bool _showToken = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _rc.init();
  }

  Future<void> _addToDesktop() async {
    setState(() => _busy = true);
    try {
      final files = await _rc.addToClaudeDesktop();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Added to Claude Desktop'),
          content: Text('MotionAI was added to:\n${files.join('\n')}\n\n'
              'Now fully quit Claude Desktop (right-click its tray icon → Quit) and open it again. '
              'Then ask Claude, for example: "Open my latest MotionAI project and add a title".'),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ),
      );
    } catch (e) {
      if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editPort() async {
    final ctl = TextEditingController(text: '${_rc.port}');
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Port'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(helperText: '1024–65535 · only this PC can connect (127.0.0.1)'),
          onSubmitted: (s) => Navigator.pop(ctx, s),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('Save')),
        ],
      ),
    );
    final p = int.tryParse(v?.trim() ?? '');
    if (p != null) await _rc.setPort(p);
  }

  Widget _btn(IconData icon, String label, VoidCallback? onTap) => OutlinedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 17),
        label: Text(label, style: const TextStyle(fontSize: 12.5)),
      );

  @override
  Widget build(BuildContext context) {
    if (!RemoteControl.supported) {
      return const ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.smart_toy_outlined),
        title: Text('Claude control'),
        subtitle: Text('Letting Claude control MotionAI works in the Windows app.', style: TextStyle(fontSize: 12)),
      );
    }
    return AnimatedBuilder(
      animation: _rc,
      builder: (context, _) {
        final on = _rc.enabled;
        final win = Platform.isWindows;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          const Row(children: [
            Icon(Icons.smart_toy_outlined, color: Color(0xFFD97757)),
            SizedBox(width: 8),
            Text('Claude control', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          ]),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Allow Claude to control MotionAI'),
            subtitle: const Text(
              'Claude (Claude Desktop, Claude Code) can open projects, edit, look at frames and export. '
              'You see every change live and can undo it. Only programs on this PC can connect, with a secret token.',
              style: TextStyle(fontSize: 12),
            ),
            value: on,
            onChanged: _rc.loaded ? (v) => _rc.setEnabled(v) : null,
          ),
          if (on) ...[
            Row(children: [
              Icon(_rc.running ? (_rc.connected ? Icons.link : Icons.circle) : Icons.error_outline,
                  size: 14, color: _rc.running ? (_rc.connected ? Colors.greenAccent : MA.textDim) : Colors.redAccent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _rc.running
                      ? (_rc.connected ? 'Claude connected${_rc.client == null ? '' : ' (${_rc.client})'}' : 'Waiting for Claude · ${_rc.url}')
                      : (_rc.error ?? 'Starting…'),
                  style: TextStyle(fontSize: 12, color: _rc.running ? MA.textDim : Colors.redAccent),
                ),
              ),
            ]),
            const SizedBox(height: 10),
            const Text('Connect Claude Desktop', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(
              win
                  ? (_rc.bridgeExists
                      ? '1. Tap "Add to Claude Desktop" (or copy the config and paste it in Claude → Settings → Developer → Edit Config).\n'
                          '2. Quit Claude Desktop completely and open it again.\n3. Ask Claude to edit your video.'
                      : 'motionai-mcp.exe was not found next to MotionAI. Install the latest MotionAI build (it includes it).')
                  : 'Use the URL and token below in your Claude client.',
              style: const TextStyle(fontSize: 12, color: MA.textDim),
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              if (win)
                FilledButton.icon(
                  onPressed: _busy || !_rc.bridgeExists ? null : _addToDesktop,
                  icon: const Icon(Icons.add_link, size: 18),
                  label: const Text('Add to Claude Desktop'),
                ),
              if (win) _btn(Icons.copy, 'Copy config for Claude', () => _copy(context, _rc.desktopSnippet, 'Claude Desktop config')),
              if (win) _btn(Icons.terminal, 'Copy Claude Code command', () => _copy(context, _rc.claudeCodeCommand, 'Claude Code command')),
              _btn(Icons.http, 'Copy URL + token (HTTP)', () => _copy(context, _rc.httpSnippet, 'HTTP config')),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              const Text('Token  ', style: TextStyle(fontSize: 12.5, color: MA.textDim)),
              Expanded(
                child: SelectableText(
                  _showToken ? _rc.token : '•' * 24,
                  maxLines: 1,
                  style: const TextStyle(fontSize: 12.5, fontFamily: 'Roboto Mono'),
                ),
              ),
              IconButton(
                tooltip: _showToken ? 'Hide' : 'Show',
                icon: Icon(_showToken ? Icons.visibility_off : Icons.visibility, size: 18),
                onPressed: () => setState(() => _showToken = !_showToken),
              ),
              IconButton(tooltip: 'Copy token', icon: const Icon(Icons.copy, size: 18), onPressed: () => _copy(context, _rc.token, 'Token')),
              IconButton(
                tooltip: 'New token (disconnects HTTP clients that use the old one)',
                icon: const Icon(Icons.refresh, size: 18),
                onPressed: () => _rc.regenerateToken(),
              ),
            ]),
            Row(children: [
              Text('Port ${_rc.port}', style: const TextStyle(fontSize: 12.5, color: MA.textDim)),
              TextButton(onPressed: _editPort, child: const Text('Change')),
              const Spacer(),
              TextButton.icon(
                onPressed: () => RemoteLogSheet.open(context),
                icon: const Icon(Icons.history, size: 18),
                label: Text('Activity (${_rc.log.length})'),
              ),
            ]),
            for (final e in _rc.log.take(5)) _LogRow(e),
          ],
        ]);
      },
    );
  }
}
