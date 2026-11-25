import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Text-to-speech with the voices installed in Windows (Settings → Time &
/// language → Speech). Uses the modern WinRT voices (they include Hindi
/// "Kalpana"/"Hemant" when the Hindi speech pack is installed) through
/// Windows PowerShell, falling back to the classic System.Speech voices.
class WinTts {
  static Future<List<(String, double)>> speak(List<String> texts, String dir,
      {String lang = 'hi-IN', double rate = 1.0, double pitch = 1.0}) async {
    if (texts.isEmpty) return const [];
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final outs = [for (var i = 0; i < texts.length; i++) '$dir${Platform.pathSeparator}voice_${stamp}_$i.wav'];
    final tmp = Directory.systemTemp;
    final script = File('${tmp.path}${Platform.pathSeparator}motionai_tts.ps1');
    final job = File('${tmp.path}${Platform.pathSeparator}motionai_tts_$stamp.json');
    // UTF-8 with BOM so Windows PowerShell 5.1 reads Hindi text correctly.
    await script.writeAsBytes([0xEF, 0xBB, 0xBF, ...utf8.encode(_script)]);
    await job.writeAsString(jsonEncode({'texts': texts, 'outs': outs, 'lang': lang, 'rate': rate, 'pitch': pitch}));
    try {
      final r = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        script.path,
        job.path,
      ], stdoutEncoding: utf8, stderrEncoding: utf8);
      final err = '${r.stderr}${r.stdout}';
      if (r.exitCode != 0) {
        if (err.contains('NOVOICE')) {
          throw StateError('No ${_langName(lang)} voice is installed. Add it in Windows Settings → Time & language → Speech → Add voices.');
        }
        throw StateError('Windows text-to-speech failed: ${err.trim().split('\n').last}');
      }
    } finally {
      job.delete().ignore();
    }
    final res = <(String, double)>[];
    for (var i = 0; i < outs.length; i++) {
      final f = File(outs[i]);
      if (!f.existsSync()) throw StateError('The voice could not read line ${i + 1}.');
      final bytes = await f.readAsBytes();
      res.add((outs[i], wavDuration(bytes)));
    }
    return res;
  }

  static String _langName(String lang) => switch (lang.split('-').first) {
        'hi' => 'Hindi',
        'en' => 'English',
        'mr' => 'Marathi',
        _ => lang,
      };

  /// Seconds of audio in a RIFF/WAVE file (0 when unreadable).
  static double wavDuration(Uint8List b) {
    if (b.length < 12 || ascii.decode(b.sublist(0, 4), allowInvalid: true) != 'RIFF') return 0;
    final bd = ByteData.sublistView(b);
    var pos = 12;
    var byteRate = 0;
    while (pos + 8 <= b.length) {
      final id = ascii.decode(b.sublist(pos, pos + 4), allowInvalid: true);
      final size = bd.getUint32(pos + 4, Endian.little);
      if (id == 'fmt ' && pos + 20 <= b.length) byteRate = bd.getUint32(pos + 8 + 8, Endian.little);
      if (id == 'data') {
        if (byteRate <= 0) return 0;
        final avail = b.length - pos - 8;
        final n = (size == 0 || size > avail) ? avail : size;
        return n / byteRate;
      }
      pos += 8 + size + (size & 1);
    }
    return 0;
  }

  static const _script = r'''
param([string]$job)
$ErrorActionPreference = 'Stop'
$j = Get-Content -Raw -Encoding UTF8 -LiteralPath $job | ConvertFrom-Json
$texts = @($j.texts)
$outs = @($j.outs)

function Find-Lang($list, $getLang) {
  $v = $list | Where-Object { (& $getLang $_) -eq $j.lang } | Select-Object -First 1
  if (-not $v) {
    $p = $j.lang.Split('-')[0]
    $v = $list | Where-Object { (& $getLang $_) -like "$p-*" } | Select-Object -First 1
  }
  return $v
}

function Use-WinRT {
  Add-Type -AssemblyName System.Runtime.WindowsRuntime
  $null = [Windows.Media.SpeechSynthesis.SpeechSynthesizer, Windows.Media.SpeechSynthesis, ContentType = WindowsRuntime]
  $null = [Windows.Storage.Streams.DataReader, Windows.Storage.Streams, ContentType = WindowsRuntime]
  $asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
      $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
  $synth = New-Object Windows.Media.SpeechSynthesis.SpeechSynthesizer
  $voice = Find-Lang ([Windows.Media.SpeechSynthesis.SpeechSynthesizer]::AllVoices) { param($v) $v.Language }
  if (-not $voice) { throw 'NOVOICE' }
  $synth.Voice = $voice
  try { $synth.Options.SpeakingRate = [double]$j.rate } catch {}
  try { $synth.Options.AudioPitch = [double]$j.pitch } catch {}
  for ($i = 0; $i -lt $texts.Count; $i++) {
    $t1 = $asTask.MakeGenericMethod([Windows.Media.SpeechSynthesis.SpeechSynthesisStream]).Invoke($null, @($synth.SynthesizeTextToStreamAsync([string]$texts[$i])))
    $t1.Wait(-1) | Out-Null
    $stream = $t1.Result
    $reader = New-Object Windows.Storage.Streams.DataReader($stream.GetInputStreamAt(0))
    $n = [uint32]$stream.Size
    $t2 = $asTask.MakeGenericMethod([uint32]).Invoke($null, @($reader.LoadAsync($n)))
    $t2.Wait(-1) | Out-Null
    $bytes = New-Object byte[] $n
    $reader.ReadBytes($bytes)
    [IO.File]::WriteAllBytes([string]$outs[$i], $bytes)
    $reader.Dispose()
    $stream.Dispose()
  }
}

function Use-Sapi {
  Add-Type -AssemblyName System.Speech
  $s = New-Object System.Speech.Synthesis.SpeechSynthesizer
  $v = Find-Lang ($s.GetInstalledVoices()) { param($x) $x.VoiceInfo.Culture.Name }
  if (-not $v) { throw 'NOVOICE' }
  $s.SelectVoice($v.VoiceInfo.Name)
  $s.Rate = [int][Math]::Max(-10, [Math]::Min(10, [Math]::Round(([double]$j.rate - 1) * 10)))
  for ($i = 0; $i -lt $texts.Count; $i++) {
    $s.SetOutputToWaveFile([string]$outs[$i])
    $s.Speak([string]$texts[$i])
    $s.SetOutputToNull()
  }
  $s.Dispose()
}

try {
  Use-WinRT
} catch {
  $first = $_.Exception.Message
  try {
    Use-Sapi
  } catch {
    if ($first -match 'NOVOICE' -or $_.Exception.Message -match 'NOVOICE') { [Console]::Error.WriteLine('NOVOICE'); exit 3 }
    [Console]::Error.WriteLine("$first / $($_.Exception.Message)")
    exit 2
  }
}
exit 0
''';
}
