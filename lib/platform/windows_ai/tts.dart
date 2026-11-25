// Voice-over on Windows (Agent E): the voices installed in Windows, driven
// through Windows PowerShell 5.1. Classic desktop voices go through
// System.Speech (SpeechSynthesizer.SetOutputToWaveFile); the modern
// "OneCore" voices — which is where Hindi "Microsoft Kalpana"/"Hemant" live
// once the Hindi speech pack is installed — go through
// Windows.Media.SpeechSynthesis, because System.Speech can't see them.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'wav.dart';

class WinVoice {
  final String engine; // 'sapi' (System.Speech) | 'winrt' (OneCore)
  final String name;
  final String id;
  final String lang; // e.g. hi-IN
  final String gender;

  const WinVoice({required this.engine, required this.name, this.id = '', required this.lang, this.gender = ''});

  factory WinVoice.fromJson(Map j) => WinVoice(
        engine: '${j['engine'] ?? 'sapi'}',
        name: '${j['name'] ?? ''}',
        id: '${j['id'] ?? ''}',
        lang: '${j['lang'] ?? ''}',
        gender: '${j['gender'] ?? ''}',
      );

  Map<String, dynamic> toJson() => {'engine': engine, 'name': name, 'id': id, 'lang': lang, 'gender': gender};

  @override
  String toString() => '$name ($lang, $engine)';
}

/// The voice chosen for a request, with a note when it is a fallback.
class VoiceChoice {
  final WinVoice voice;
  final String? note;
  const VoiceChoice(this.voice, [this.note]);
}

class WinTtsEngine {
  /// Hindi voices that ship with the Windows Hindi speech pack.
  static const hindiVoices = ['Kalpana', 'Hemant'];

  static String langName(String lang) => switch (lang.split(RegExp('[-_]')).first.toLowerCase()) {
        'hi' => 'Hindi',
        'en' => 'English',
        'mr' => 'Marathi',
        'ta' => 'Tamil',
        'te' => 'Telugu',
        'bn' => 'Bengali',
        'gu' => 'Gujarati',
        'pa' => 'Punjabi',
        'ur' => 'Urdu',
        _ => lang,
      };

  static String _base(String lang) => lang.split(RegExp('[-_]')).first.toLowerCase();
  static String _norm(String lang) => lang.replaceAll('_', '-').toLowerCase();

  /// True when every line is written in Latin letters (Hinglish in Roman
  /// script can be read by an Indian-English voice).
  static bool latinOnly(List<String> texts) =>
      texts.every((t) => !RegExp(r'[^\u0000-ɏ -⁯₠-⃏]').hasMatch(t));

  static int _rank(WinVoice v, String wantedBase) {
    var r = 0;
    if (wantedBase == 'hi' && hindiVoices.any((n) => v.name.contains(n))) r += 4;
    if (v.engine == 'sapi') r += 1; // System.Speech first when both list the voice
    return r;
  }

  static WinVoice? _best(Iterable<WinVoice> list, String base) {
    WinVoice? best;
    for (final v in list) {
      if (best == null || _rank(v, base) > _rank(best, base)) best = v;
    }
    return best;
  }

  /// Picks the voice for [lang] (BCP-47, e.g. hi-IN): the exact locale, then
  /// the same language; for Hindi lines in Roman script an Indian-English
  /// (then any English) voice. Null when nothing installed can read them.
  static VoiceChoice? pickVoice(List<WinVoice> voices, String lang, List<String> texts) {
    final want = _norm(lang), base = _base(lang);
    final exact = _best(voices.where((v) => _norm(v.lang) == want), base);
    if (exact != null) return VoiceChoice(exact);
    final same = _best(voices.where((v) => _base(v.lang) == base), base);
    if (same != null) return VoiceChoice(same, 'Using ${same.name} (${same.lang}) — no $lang voice is installed.');
    if (base != 'en' && latinOnly(texts)) {
      final enIn = _best(voices.where((v) => _norm(v.lang) == 'en-in'), 'en') ?? _best(voices.where((v) => _base(v.lang) == 'en'), 'en');
      if (enIn != null) {
        return VoiceChoice(enIn,
            'No ${langName(lang)} voice is installed, so ${enIn.name} reads the Roman-script lines. ${installHint(lang)}');
      }
    }
    return null;
  }

  static String installHint(String lang) => lang.toLowerCase().startsWith('hi')
      ? 'Add the Hindi voices (Microsoft Kalpana / Hemant) in Windows Settings → Time & language → Speech → Add voices → Hindi (India).'
      : 'Add a ${langName(lang)} voice in Windows Settings → Time & language → Speech → Add voices.';

  static String noVoiceMessage(String lang) => 'No ${langName(lang)} voice is installed on this PC. ${installHint(lang)}';

  /// System.Speech rate (-10..10, where +10 is 3× and -10 is ⅓×) for a
  /// speed multiplier.
  static int sapiRate(double rate) {
    if (!(rate > 0)) return 0;
    return (math.log(rate) / math.log(3) * 10).round().clamp(-10, 10).toInt();
  }

  static String _xml(String s) =>
      s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll("'", '&apos;');

  /// SSML that applies [pitch] (1.0 = normal) for System.Speech; null when
  /// the pitch is normal (plain text is spoken then).
  static String? ssml(String text, String voiceLang, double pitch) {
    final pct = ((pitch - 1) * 100).round().clamp(-50, 50);
    if (pct == 0) return null;
    final sign = pct > 0 ? '+' : '';
    return '<speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xml:lang="${_xml(voiceLang)}">'
        '<prosody pitch="$sign$pct%">${_xml(text)}</prosody></speak>';
  }

  /// Voices listed by the script (accepts a list or {voices: [...]}).
  static List<WinVoice> parseVoices(Object? json) {
    final raw = json is Map ? json['voices'] : json;
    final list = raw is List ? raw : (raw is Map ? [raw] : const []);
    return [
      for (final v in list)
        if (v is Map && '${v['name'] ?? ''}'.isNotEmpty) WinVoice.fromJson(v)
    ];
  }

  /// Job description for the speak step of [script].
  static Map<String, dynamic> speakJob(VoiceChoice c, List<String> texts, List<String> outs, String resultPath,
          {double rate = 1.0, double pitch = 1.0}) =>
      {
        'mode': 'speak',
        'result': resultPath,
        'engine': c.voice.engine,
        'voiceName': c.voice.name,
        'voiceId': c.voice.id,
        'texts': texts,
        'outs': outs,
        'rate': rate.clamp(0.5, 3.0),
        'pitch': pitch.clamp(0.0, 2.0),
        'sapiRate': sapiRate(rate),
        'ssml': [for (final t in texts) ssml(t, c.voice.lang, pitch) ?? ''],
      };

  // ----------------------------------------------------------- running

  static List<WinVoice>? _voices;

  /// Last fallback note (e.g. English voice for Roman-script Hindi).
  static String? lastNotice;

  static Future<Map<String, dynamic>> _runScript(Map<String, dynamic> job) async {
    final tmp = Directory.systemTemp.createTempSync('motionai_tts');
    try {
      final script = File('${tmp.path}\\tts.ps1');
      final jobFile = File('${tmp.path}\\job.json');
      final result = '${tmp.path}\\result.json';
      // UTF-8 with BOM so Windows PowerShell 5.1 reads Hindi text correctly.
      script.writeAsBytesSync([0xEF, 0xBB, 0xBF, ...utf8.encode(psScript)]);
      jobFile.writeAsStringSync(jsonEncode({...job, 'result': result}));
      final r = await Process.run(
          'powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', script.path, jobFile.path],
          stdoutEncoding: utf8, stderrEncoding: utf8);
      final f = File(result);
      if (!f.existsSync()) {
        final err = '${r.stderr}\n${r.stdout}'.trim();
        throw StateError('Windows text-to-speech did not start (${r.exitCode}): ${err.isEmpty ? 'no output' : err.split('\n').last}');
      }
      final txt = utf8.decode(f.readAsBytesSync(), allowMalformed: true).replaceFirst('﻿', '');
      final j = jsonDecode(txt);
      return j is Map<String, dynamic> ? j : {'ok': true, 'voices': j};
    } finally {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  static Future<List<WinVoice>> voices({bool refresh = false}) async {
    if (_voices != null && !refresh) return _voices!;
    final j = await _runScript({'mode': 'list'});
    return _voices = parseVoices(j);
  }

  /// One WAV per line in [dir]: (path, seconds).
  static Future<List<(String, double)>> speak(List<String> texts, String dir,
      {String lang = 'hi-IN', double rate = 1.0, double pitch = 1.0}) async {
    if (texts.isEmpty) return const [];
    var choice = pickVoice(await voices(), lang, texts);
    choice ??= pickVoice(await voices(refresh: true), lang, texts); // a voice may have just been added
    if (choice == null) throw StateError(noVoiceMessage(lang));
    lastNotice = choice.note;
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final sep = Platform.pathSeparator;
    final outs = [for (var i = 0; i < texts.length; i++) '$dir${sep}voice_${stamp}_$i.wav'];
    final j = await _runScript(speakJob(choice, texts, outs, '', rate: rate, pitch: pitch));
    if (j['ok'] != true) throw StateError('Windows voice ${choice.voice.name} failed: ${j['error'] ?? 'unknown error'}');
    final res = <(String, double)>[];
    for (var i = 0; i < outs.length; i++) {
      final f = File(outs[i]);
      if (!f.existsSync()) throw StateError('The voice could not read line ${i + 1}.');
      final secs = WavInfo.duration(await f.readAsBytes());
      if (secs <= 0 && texts[i].trim().isNotEmpty) throw StateError('The voice produced no audio for line ${i + 1}.');
      res.add((outs[i], secs));
    }
    return res;
  }

  static const psScript = r'''
param([string]$job)
$ErrorActionPreference = 'Stop'
$j = Get-Content -Raw -Encoding UTF8 -LiteralPath $job | ConvertFrom-Json

function Save($obj) {
  $json = ConvertTo-Json -InputObject $obj -Depth 5 -Compress
  [IO.File]::WriteAllText([string]$j.result, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Load-WinRT {
  Add-Type -AssemblyName System.Runtime.WindowsRuntime
  $null = [Windows.Media.SpeechSynthesis.SpeechSynthesizer, Windows.Media.SpeechSynthesis, ContentType = WindowsRuntime]
  $null = [Windows.Storage.Streams.DataReader, Windows.Storage.Streams, ContentType = WindowsRuntime]
}

function Await($op, [Type]$type) {
  $m = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
  $t = $m.MakeGenericMethod($type).Invoke($null, @($op))
  $t.Wait(-1) | Out-Null
  return $t.Result
}

if ($j.mode -eq 'list') {
  $voices = New-Object System.Collections.ArrayList
  try {
    Add-Type -AssemblyName System.Speech
    $s = New-Object System.Speech.Synthesis.SpeechSynthesizer
    foreach ($v in $s.GetInstalledVoices()) {
      if (-not $v.Enabled) { continue }
      $null = $voices.Add(@{ engine = 'sapi'; name = $v.VoiceInfo.Name; id = $v.VoiceInfo.Id; lang = $v.VoiceInfo.Culture.Name; gender = "$($v.VoiceInfo.Gender)" })
    }
    $s.Dispose()
  } catch {}
  try {
    Load-WinRT
    foreach ($v in [Windows.Media.SpeechSynthesis.SpeechSynthesizer]::AllVoices) {
      $null = $voices.Add(@{ engine = 'winrt'; name = $v.DisplayName; id = $v.Id; lang = $v.Language; gender = "$($v.Gender)" })
    }
  } catch {}
  Save @{ ok = $true; voices = @($voices.ToArray()) }
  exit 0
}

$texts = @($j.texts)
$outs = @($j.outs)
$ssml = @($j.ssml)
try {
  if ($j.engine -eq 'winrt') {
    Load-WinRT
    $voice = [Windows.Media.SpeechSynthesis.SpeechSynthesizer]::AllVoices | Where-Object { $_.Id -eq $j.voiceId } | Select-Object -First 1
    if (-not $voice) { $voice = [Windows.Media.SpeechSynthesis.SpeechSynthesizer]::AllVoices | Where-Object { $_.DisplayName -eq $j.voiceName } | Select-Object -First 1 }
    if (-not $voice) { throw "Voice not found: $($j.voiceName)" }
    $synth = New-Object Windows.Media.SpeechSynthesis.SpeechSynthesizer
    $synth.Voice = $voice
    try { $synth.Options.SpeakingRate = [double]$j.rate } catch {}
    try { $synth.Options.AudioPitch = [double]$j.pitch } catch {}
    for ($i = 0; $i -lt $texts.Count; $i++) {
      $stream = Await ($synth.SynthesizeTextToStreamAsync([string]$texts[$i])) ([Windows.Media.SpeechSynthesis.SpeechSynthesisStream])
      $reader = New-Object Windows.Storage.Streams.DataReader($stream.GetInputStreamAt(0))
      $n = [uint32]$stream.Size
      $null = Await ($reader.LoadAsync($n)) ([uint32])
      $bytes = New-Object byte[] $n
      $reader.ReadBytes($bytes)
      [IO.File]::WriteAllBytes([string]$outs[$i], $bytes)
      $reader.Dispose()
      $stream.Dispose()
    }
    $synth.Dispose()
  } else {
    Add-Type -AssemblyName System.Speech
    $s = New-Object System.Speech.Synthesis.SpeechSynthesizer
    $s.SelectVoice([string]$j.voiceName)
    $s.Rate = [int]$j.sapiRate
    for ($i = 0; $i -lt $texts.Count; $i++) {
      $s.SetOutputToWaveFile([string]$outs[$i])
      $done = $false
      if ($ssml.Count -gt $i -and $ssml[$i]) {
        try { $s.SpeakSsml([string]$ssml[$i]); $done = $true } catch { $s.SetOutputToNull(); $s.SetOutputToWaveFile([string]$outs[$i]) }
      }
      if (-not $done) { $s.Speak([string]$texts[$i]) }
      $s.SetOutputToNull()
    }
    $s.Dispose()
  }
  Save @{ ok = $true }
} catch {
  Save @{ ok = $false; error = "$($_.Exception.Message)" }
  exit 2
}
exit 0
''';
}
