import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Easing;
import 'package:video_player/video_player.dart';

import '../../core/engine/evaluator.dart';
import '../../core/engine/fx_math.dart';
import '../../core/model/easing.dart';
import '../../core/model/layer.dart';
import '../../core/model/project.dart';
import '../../state/video_pool.dart';
import 'fx/fx_painters.dart';
import 'fx/offscreen.dart';
import 'fx/particles.dart';
import 'fx/text_fx.dart';
import 'shape_painter.dart';

/// Draws one evaluated layer: content → effects → masks → depth blur → opacity → transform.
///
/// During export, [videoFrames] supplies exact decoded frames for video
/// layers instead of the live players.
class LayerView extends StatelessWidget {
  final RenderItem item;
  final Project project;
  final VideoPool? videos;
  final double time;
  final Map<String, ui.Image>? videoFrames;

  const LayerView({
    super.key,
    required this.item,
    required this.project,
    required this.videos,
    required this.time,
    this.videoFrames,
    this.draft = false,
    this.playing = false,
    this.asMatte = false,
  });

  final bool draft;
  final bool playing;

  /// Drawn only as a track matte (its pixels are never shown): a live video
  /// is replaced by its opaque frame box, since a snapshot of a platform
  /// texture can come out blank.
  final bool asMatte;

  /// Longest side images are decoded at in the live preview.
  static const draftImageSize = 1280;

  @override
  Widget build(BuildContext context) {
    final l = item.layer;
    Widget child = SizedBox(width: l.width, height: l.height, child: _content(l));
    for (final e in l.effects) {
      if (e.enabled) child = _effect(e, child, l);
    }
    for (final m in l.masks) {
      child = _mask(m, child);
    }
    // Cache the layer's pixels: when only its 3D/camera transform changes,
    // the GPU re-composites the cached picture instead of repainting it.
    if (draft) child = RepaintBoundary(child: child);
    // Depth-of-field blur is the most expensive thing in 3D: lighter in the
    // preview and skipped while playing (full quality on export).
    if (item.dofBlur > 0.3 && !(draft && playing)) {
      final s = math.min(item.dofBlur, draft ? 12.0 : 40.0);
      child = ImageFiltered(imageFilter: ui.ImageFilter.blur(sigmaX: s, sigmaY: s, tileMode: TileMode.decal), child: child);
    }
    if (item.opacity < 0.999) child = Opacity(opacity: item.opacity, child: child);
    Widget out = Transform(transform: item.matrix, child: child);
    // Motion blur from on-screen velocity (comp px/frame), in screen space.
    final mb = _motionBlur(l);
    if (mb != null) {
      out = ImageFiltered(
        imageFilter: ui.ImageFilter.blur(sigmaX: mb.$1, sigmaY: mb.$2, tileMode: TileMode.decal),
        child: out,
      );
    }
    return Positioned(left: 0, top: 0, child: out);
  }

  /// Blur sigmas (x, y) for the layer's motion, or null when not needed.
  /// Skipped while the draft preview plays (like depth blur); full on export.
  (double, double)? _motionBlur(Layer l) {
    if (item.vx == 0 && item.vy == 0) return null;
    if (draft && playing) return null;
    double shutter = project.main.motionBlur ? 0.5 : 0;
    for (final e in l.effects) {
      if (e.enabled && e.type == 'motion_blur') shutter = (e.params['amount']?.valueAt(time)[0] ?? 50) / 100;
    }
    if (shutter <= 0) return null;
    final cap = draft ? 16.0 : 80.0;
    final sx = math.min(cap, item.vx.abs() * shutter / 2.5);
    final sy = math.min(cap, item.vy.abs() * shutter / 2.5);
    if (sx < 0.6 && sy < 0.6) return null;
    return (math.max(0.01, sx), math.max(0.01, sy));
  }

  Widget _content(Layer l) {
    switch (l.type) {
      case LayerType.video:
        final frame = videoFrames?[l.id];
        if (frame != null) return RawImage(image: frame, fit: BoxFit.fill, width: l.width, height: l.height);
        if (asMatte) return const ColoredBox(color: Color(0xFFFFFFFF));
        final VideoPlayerController? c = videos?.controllerFor(l.id);
        if (c == null) return const ColoredBox(color: Color(0xFF15181D));
        return VideoPlayer(c);
      case LayerType.image:
        final asset = project.media[l.mediaId];
        if (asset == null) return const ColoredBox(color: Color(0xFF3A1010));
        return Image.file(
          File(asset.path),
          width: l.width,
          height: l.height,
          fit: BoxFit.fill,
          gaplessPlayback: true,
          filterQuality: draft && playing ? FilterQuality.low : FilterQuality.medium,
          cacheWidth: math.min(l.width.round(), draft ? draftImageSize : 2560),
          errorBuilder: (_, e, _) => ColoredBox(
            color: const Color(0xFF3A1010),
            child: Center(
              child: Text('Image could not be shown\n$e',
                  textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontSize: l.height * 0.04)),
            ),
          ),
        );
      case LayerType.text:
        return _text(l, l.text ?? TextData());
      case LayerType.solid:
        return ColoredBox(color: Color(l.color));
      case LayerType.shape:
        final sh = l.shape;
        if (sh == null) return const SizedBox.shrink();
        final tr = l.props[Props.trim]?.valueAt(time) ?? const [0.0, 100.0];
        return RepaintBoundary(
          child: CustomPaint(
            size: Size(l.width, l.height),
            painter: ShapePainter(sh, tr[0] / 100, tr[1] / 100),
          ),
        );
      case LayerType.nullObject:
      case LayerType.audio:
        return const SizedBox.shrink();
    }
  }

  // ------------------------------------------------------------------ text

  Widget _text(Layer l, TextData t) {
    final weightIndex = ((t.fontWeight ~/ 100) - 1).clamp(0, FontWeight.values.length - 1);
    final style = TextStyle(
      fontSize: t.fontSize,
      color: Color(t.color),
      fontWeight: FontWeight.values[weightIndex],
      fontFamily: t.fontFamily,
      height: 1.15,
      decoration: TextDecoration.none,
      shadows: t.shadow
          ? [Shadow(color: Colors.black.withValues(alpha: 0.6), blurRadius: t.fontSize * 0.12, offset: Offset(0, t.fontSize * 0.04))]
          : null,
    );
    final align = switch (t.align) { 'left' => TextAlign.left, 'right' => TextAlign.right, _ => TextAlign.center };
    final wrapAlign = switch (t.align) {
      'left' => WrapAlignment.start,
      'right' => WrapAlignment.end,
      _ => WrapAlignment.center,
    };
    final local = time - l.start;
    final p = t.animDuration <= 0 ? 1.0 : (local / t.animDuration).clamp(0.0, 1.0);

    // Fade/slide intro for painted text (per-letter animators animate themselves).
    final perGlyph = t.animator == 'random_pop' || t.animator == 'scramble';
    Widget intro(Widget painted) {
      if (perGlyph || t.animator == 'none' || t.animator == 'karaoke') return painted;
      final e = Easing.easeOut.transform(p);
      return Opacity(
        opacity: e,
        child: Transform.translate(offset: Offset(0, (1 - e) * t.fontSize * 0.4), child: painted),
      );
    }

    final shown = t.counter?.valueAt(time) ?? t.text;
    final size = Size(l.width, l.height);
    MarkedTextPainter marked(MarkLayer layer) => MarkedTextPainter(
          text: shown,
          style: style,
          align: align,
          marks: t.marks,
          time: time,
          outline: t.outline,
          extrude: t.extrude,
          extrudeColor: Color(t.extrudeColor),
          draft: draft,
          layer: layer,
        );

    // Per-letter animators and the 3D extruded edge (also on counters, and
    // combined with highlight/circle/underline marks).
    if (perGlyph || (t.extrude > 0 && t.marks.isEmpty)) {
      final glyphs = CustomPaint(
        size: size,
        painter: GlyphTextPainter(
          text: shown,
          style: style,
          align: align,
          animator: perGlyph ? t.animator : 'none',
          local: local,
          duration: t.animDuration,
          seed: stableHash(l.id),
          outline: t.outline,
          extrude: t.extrude,
          extrudeColor: Color(t.extrudeColor),
          draft: draft,
        ),
      );
      if (t.marks.isEmpty) return intro(glyphs);
      // Marks around per-letter text: highlighter behind, pen marks on top.
      return Stack(children: [
        CustomPaint(size: size, painter: marked(MarkLayer.behind)),
        glyphs,
        CustomPaint(size: size, painter: marked(MarkLayer.front)),
      ]);
    }

    if (t.marks.isNotEmpty || t.counter != null || t.outline > 0 || t.extrude > 0) {
      return intro(CustomPaint(size: size, painter: marked(MarkLayer.all)));
    }

    Widget content;
    switch (t.animator) {
      case 'typewriter':
        final n = (t.text.length * p).round();
        content = Text.rich(
          TextSpan(children: [
            TextSpan(text: t.text.substring(0, n)),
            TextSpan(text: t.text.substring(n), style: const TextStyle(color: Colors.transparent, shadows: [])),
          ]),
          textAlign: align,
          style: style,
        );
        break;
      case 'slide_up':
        final e = Easing.easeOut.transform(p);
        content = ClipRect(
          child: Transform.translate(
            offset: Offset(0, (1 - e) * t.fontSize * 1.3),
            child: Opacity(opacity: e, child: Text(t.text, textAlign: align, style: style)),
          ),
        );
        break;
      case 'word_pop':
      case 'fade_up':
      case 'karaoke':
        content = _words(l, t, style, wrapAlign, local);
        break;
      default:
        content = Text(t.text, textAlign: align, style: style);
    }

    if (t.boxColor != 0) {
      content = Container(
        padding: EdgeInsets.symmetric(horizontal: t.fontSize * 0.35, vertical: t.fontSize * 0.12),
        decoration: BoxDecoration(color: Color(t.boxColor), borderRadius: BorderRadius.circular(t.fontSize * 0.2)),
        child: content,
      );
    }
    return Align(
      alignment: switch (t.align) { 'left' => Alignment.centerLeft, 'right' => Alignment.centerRight, _ => Alignment.center },
      child: content,
    );
  }

  Widget _words(Layer l, TextData t, TextStyle style, WrapAlignment wrapAlign, double local) {
    final timed = t.words.isNotEmpty;
    final words = timed ? t.words.map((w) => w.word).toList() : t.text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final n = words.length;
    final children = <Widget>[];
    for (int i = 0; i < n; i++) {
      Widget w = Text('${words[i]} ', style: style);
      switch (t.animator) {
        case 'word_pop':
        case 'fade_up':
          final delay = n <= 1 ? 0.0 : i * (t.animDuration * 0.6) / (n - 1);
          final span = math.max(0.05, t.animDuration * 0.4);
          final q = ((local - delay) / span).clamp(0.0, 1.0);
          if (t.animator == 'word_pop') {
            w = Opacity(
              opacity: q,
              child: Transform.scale(scale: math.max(0.0, Easing.back.transform(q)), child: w),
            );
          } else {
            w = Opacity(
              opacity: q,
              child: Transform.translate(offset: Offset(0, (1 - Easing.easeOut.transform(q)) * t.fontSize * 0.5), child: w),
            );
          }
          break;
        case 'karaoke':
          bool active;
          bool spoken;
          if (timed) {
            final wt = t.words[i];
            active = time >= wt.start && time < wt.end;
            spoken = time >= wt.start;
          } else {
            final idx = l.duration <= 0 ? 0 : (local / l.duration * n).floor();
            active = idx == i;
            spoken = i <= idx;
          }
          w = Transform.scale(
            scale: active ? 1.08 : 1.0,
            child: Text(
              '${words[i]} ',
              style: style.copyWith(
                color: active ? Color(t.highlightColor) : (spoken ? Color(t.color) : Color(t.color).withValues(alpha: 0.75)),
              ),
            ),
          );
          break;
      }
      children.add(w);
    }
    return Wrap(alignment: wrapAlign, crossAxisAlignment: WrapCrossAlignment.center, children: children);
  }

  // --------------------------------------------------------------- effects

  Widget _effect(Effect e, Widget child, Layer l) {
    double p(String k, [int i = 0]) {
      final ap = e.params[k];
      return ap == null ? 0 : ap.valueAt(time)[i];
    }

    Widget overlay(Widget o) => Stack(children: [child, Positioned.fill(child: IgnorePointer(child: o))]);
    Color rgb(String k) => Color.fromARGB(255, p(k, 0).round().clamp(0, 255), p(k, 1).round().clamp(0, 255), p(k, 2).round().clamp(0, 255));
    List<double> rgbList(String k) => [p(k, 0), p(k, 1), p(k, 2)];
    final cheap = draft && playing;

    switch (e.type) {
      case 'blur':
        final a = p('amount') * 0.5;
        if (a <= 0.05) return child;
        return ImageFiltered(imageFilter: ui.ImageFilter.blur(sigmaX: a, sigmaY: a, tileMode: TileMode.decal), child: child);
      case 'color':
        return ColorFiltered(
          colorFilter: ColorFilter.matrix(colorAdjustMatrix(p('brightness'), p('contrast'), p('saturation'))),
          child: child,
        );
      case 'tint':
        return ColorFiltered(
          colorFilter: ColorFilter.matrix(tintMatrix(p('color', 0), p('color', 1), p('color', 2), p('amount') / 100)),
          child: child,
        );
      case 'vignette':
        final amount = (p('amount') / 100).clamp(0.0, 1.0);
        final size = (p('size') / 100).clamp(0.05, 1.0);
        return overlay(DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              radius: 0.75,
              colors: [Colors.transparent, Colors.black.withValues(alpha: amount)],
              stops: [size * 0.95, 1.0],
            ),
          ),
        ));
      case 'glow':
        final amount = (p('amount') / 100).clamp(0.0, 1.0);
        final r = p('radius').clamp(1.0, 100.0);
        if (amount <= 0) return child;
        return Stack(children: [
          child,
          IgnorePointer(
            child: Opacity(
              opacity: amount * 0.85,
              child: ImageFiltered(
                imageFilter: ui.ImageFilter.blur(sigmaX: r, sigmaY: r, tileMode: TileMode.decal),
                child: ColorFiltered(colorFilter: ColorFilter.matrix(colorAdjustMatrix(25, 20, 10)), child: child),
              ),
            ),
          ),
        ]);
      case 'grain':
        final amount = (p('amount') / 100).clamp(0.0, 1.0);
        if (amount <= 0) return child;
        return overlay(CustomPaint(painter: _GrainPainter((time * 24).floor(), amount, p('size').clamp(1.0, 8.0))));
      case 'light_leak':
        final amount = (p('amount') / 100).clamp(0.0, 1.0);
        final sp = p('speed');
        return overlay(Opacity(
          opacity: amount,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(math.sin(time * sp * 0.7) * 0.9, math.cos(time * sp * 0.5) * 0.6 - 0.3),
                radius: 1.1,
                colors: const [Color(0xCCFF8A3D), Color(0x66FF2E63), Color(0x00FF2E63)],
                stops: const [0, 0.45, 1],
              ),
            ),
          ),
        ));
      case 'gradient':
        final bottom = (p('amount') / 100).clamp(0.0, 1.0);
        final top = (p('top') / 100).clamp(0.0, 1.0);
        return overlay(DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: top),
                Colors.transparent,
                Colors.transparent,
                Colors.black.withValues(alpha: bottom),
              ],
              stops: const [0, 0.35, 0.55, 1],
            ),
          ),
        ));
      case 'letterbox':
        final bar = (p('amount') / 100).clamp(0.0, 0.45) * l.height;
        if (bar <= 0) return child;
        return Stack(children: [
          child,
          Positioned(left: 0, right: 0, top: 0, height: bar, child: const ColoredBox(color: Colors.black)),
          Positioned(left: 0, right: 0, bottom: 0, height: bar, child: const ColoredBox(color: Colors.black)),
        ]);
      case 'outline':
        final w = p('width');
        if (w <= 0) return child;
        final col = Color.fromARGB(255, p('color', 0).round(), p('color', 1).round(), p('color', 2).round());
        final silhouette = ColorFiltered(colorFilter: ColorFilter.mode(col, BlendMode.srcIn), child: child);
        return Stack(clipBehavior: Clip.none, children: [
          for (int i = 0; i < 12; i++)
            Transform.translate(
              offset: Offset(math.cos(i * math.pi / 6) * w, math.sin(i * math.pi / 6) * w),
              child: silhouette,
            ),
          child,
        ]);
      case 'shadow':
        final dist = p('distance'), blur = p('blur'), op = (p('opacity') / 100).clamp(0.0, 1.0);
        final a = p('angle') * math.pi / 180;
        return Stack(clipBehavior: Clip.none, children: [
          Transform.translate(
            offset: Offset(math.cos(a) * dist, math.sin(a) * dist),
            child: Opacity(
              opacity: op,
              child: ImageFiltered(
                imageFilter: ui.ImageFilter.blur(sigmaX: math.max(0.01, blur), sigmaY: math.max(0.01, blur), tileMode: TileMode.decal),
                child: ColorFiltered(colorFilter: const ColorFilter.mode(Colors.black, BlendMode.srcIn), child: child),
              ),
            ),
          ),
          child,
        ]);
      case 'dust':
        return overlay(CustomPaint(painter: _DustPainter(time, p('amount') / 100, p('size'))));
      case 'shatter':
        final prog = (p('progress') / 100).clamp(0.0, 1.0);
        if (prog <= 0) return child;
        return Stack(clipBehavior: Clip.none, children: [
          Opacity(
            opacity: (1 - prog * 1.6).clamp(0.0, 1.0),
            child: Transform.scale(scale: 1 + prog * 0.15, child: child),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _ShardPainter(
                  prog,
                  Color.fromARGB(255, p('color', 0).round(), p('color', 1).round(), p('color', 2).round()),
                  e.id.hashCode,
                ),
              ),
            ),
          ),
        ]);
      case 'paper':
        return overlay(CustomPaint(painter: _TexturePainter(e.id.hashCode, p('amount') / 100, dark: false)));
      case 'grunge':
        return overlay(CustomPaint(painter: _TexturePainter(e.id.hashCode, p('amount') / 100, dark: true)));
      case 'flicker':
        final f = p('amount') / 100;
        final v = 1 - f * (0.5 + 0.5 * math.sin(time * 23.0) * math.sin(time * 7.3)).abs();
        return Opacity(opacity: v.clamp(0.0, 1.0), child: child);

      // ---------------------------------------------- V1 motion FX
      case 'silhouette':
        final sil = ColorFiltered(colorFilter: ColorFilter.mode(rgb('color'), BlendMode.srcIn), child: child);
        final glow = (p('glow') / 100).clamp(0.0, 1.0);
        if (glow <= 0) return sil;
        final gs = (4 + glow * 26) * (cheap ? 0.5 : 1.0);
        return Stack(clipBehavior: Clip.none, children: [
          IgnorePointer(
            child: Opacity(
              opacity: (0.35 + glow * 0.65).clamp(0.0, 1.0),
              child: ImageFiltered(imageFilter: ui.ImageFilter.blur(sigmaX: gs, sigmaY: gs, tileMode: TileMode.decal), child: sil),
            ),
          ),
          sil,
        ]);
      case 'mono':
        final a = (p('amount') / 100).clamp(0.0, 1.0);
        if (a <= 0) return child;
        return ColorFiltered(colorFilter: ColorFilter.matrix(FxColor.mono(a)), child: child);
      case 'duotone':
        final a = (p('amount') / 100).clamp(0.0, 1.0);
        if (a <= 0) return child;
        return ColorFiltered(colorFilter: ColorFilter.matrix(FxColor.duotone(rgbList('dark'), rgbList('light'), a)), child: child);
      case 'edge_blur':
        final a = (p('amount') / 100).clamp(0.0, 1.0);
        if (a <= 0) return child;
        final bs = a * (cheap ? 10.0 : 22.0);
        final w = l.width, h = l.height;
        final ell = Float64List.fromList([w / 2, 0, 0, 0, 0, h / 2, 0, 0, 0, 0, 1, 0, w / 2, h / 2, 0, 1]);
        return Stack(children: [
          ImageFiltered(imageFilter: ui.ImageFilter.blur(sigmaX: bs, sigmaY: bs, tileMode: TileMode.decal), child: child),
          ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (_) => ui.Gradient.radial(Offset.zero, 1, const [Color(0xFFFFFFFF), Color(0xFFFFFFFF), Color(0x00FFFFFF)],
                [0, (0.62 - 0.3 * a).clamp(0.05, 0.9), 1.0], TileMode.clamp, ell),
            child: child,
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _VignettePainter(a * 0.55),
              ),
            ),
          ),
        ]);
      case 'curve':
        return MeshWarp(
          mode: WarpMode.curve,
          a: p('bend'),
          maxSide: draft ? 1280 : 3000,
          draft: draft,
          child: child,
        );
      case 'sway':
        return MeshWarp(
          mode: WarpMode.sway,
          a: p('amount'),
          b: p('speed'),
          time: time,
          seed: stableHash(e.id),
          maxSide: draft ? 1024 : 2560,
          draft: draft,
          child: child,
        );
      case 'glass_frame':
        final th = math.max(0.0, p('thickness'));
        return Stack(children: [
          ClipRRect(borderRadius: BorderRadius.circular(GlassFramePainter.radiusFor(th)), child: child),
          Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: GlassFramePainter(th, p('gloss'))))),
        ]);
      case 'torn_edge':
        final side = p('side').round().clamp(0, 3);
        final amt = (p('amount') / 100).clamp(0.0, 1.0);
        if (amt <= 0) return child;
        final depth = amt * 0.09 * (side <= 1 ? l.height : l.width);
        final seed = stableHash(e.id);
        return Stack(children: [
          Positioned.fill(
            child: ClipPath(clipper: TornEdgeClipper(side, depth, seed + 1, inset: 0.5), child: const ColoredBox(color: Color(0xFFF4F0E6))),
          ),
          ClipPath(clipper: TornEdgeClipper(side, depth, seed), child: child),
        ]);
      case 'particles':
        return overlay(CustomPaint(
          painter: ParticlesPainter(
            kind: p('kind').round(),
            amount: p('amount'),
            speed: p('speed'),
            direction: p('direction'),
            time: time,
            color: rgb('color').toARGB32(),
            seed: stableHash(e.id) & 0xFFFF,
          ),
        ));
      case 'light_rays':
        return overlay(CustomPaint(
          painter: LightRaysPainter(angle: p('angle'), amount: p('amount'), time: time, color: rgb('color'), seed: stableHash(e.id) & 0xFFFF),
        ));
      case 'reveal':
        final prog = p('progress');
        if (prog >= 99.99) return child;
        if (prog <= 0.01) return Opacity(opacity: 0, child: child);
        final kind = p('kind').round().clamp(0, 3);
        final soft = (p('softness') / 100).clamp(0.0, 1.0);
        final cx = p('cx') / 100, cy = p('cy') / 100;
        final seed = stableHash(e.id) & 0xFFFF;
        final size = Size(l.width, l.height);
        return ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (_) => RevealMask.shader(kind, prog / 100, soft, cx, cy, seed, size, draft: draft),
          child: child,
        );
      case 'motion_blur':
        return child; // applied in screen space in build()
      case 'flash':
        final a = (p('amount') / 100).clamp(0.0, 1.0);
        if (a <= 0.001) return child;
        return ColorFiltered(colorFilter: ColorFilter.matrix(FxColor.flash(rgbList('color'), a)), child: child);
      case 'glitch':
        final a = (p('amount') / 100).clamp(0.0, 1.0);
        if (a <= 0) return child;
        final seed = stableHash(e.id) & 0xFFFF;
        final frame = (time * 24).floor();
        if (hash01(frame, seed) > 0.25 + 0.75 * a) return child;
        final jx = (hash01(frame, seed + 1) - 0.5) * 2 * a * l.width * 0.03;
        final split = a * math.max(4.0, l.width * 0.008) * (0.5 + hash01(frame, seed + 2));
        return Stack(clipBehavior: Clip.none, children: [
          Transform.translate(
            offset: Offset(jx - split, 0),
            child: Opacity(opacity: 0.75, child: ColorFiltered(colorFilter: const ColorFilter.matrix(_redOnly), child: child)),
          ),
          Transform.translate(
            offset: Offset(jx + split, 0),
            child: Opacity(opacity: 0.75, child: ColorFiltered(colorFilter: const ColorFilter.matrix(_cyanOnly), child: child)),
          ),
          Transform.translate(offset: Offset(jx, 0), child: child),
        ]);
      default:
        return child;
    }
  }

  // ----------------------------------------------------------------- masks

  Widget _mask(Mask m, Widget child) {
    List<double> v(String k, List<double> d) => m.props[k]?.valueAt(time) ?? d;
    final c = v('center', [0, 0]);
    final s = v('size', [100, 100]);
    final f = math.max(0.0, v('feather', [0])[0]);
    final rx = math.max(1.0, s[0] / 2), ry = math.max(1.0, s[1] / 2);

    if (m.shape == 'ellipse') {
      final inner = (1 - f / math.min(rx, ry)).clamp(0.0, 0.999);
      final matrix = Float64List.fromList([rx, 0, 0, 0, 0, ry, 0, 0, 0, 0, 1, 0, c[0], c[1], 0, 1]);
      final colors = m.invert ? const [Color(0x00FFFFFF), Color(0xFFFFFFFF)] : const [Color(0xFFFFFFFF), Color(0x00FFFFFF)];
      return ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (_) => ui.Gradient.radial(Offset.zero, 1, colors, [inner, 1.0], TileMode.clamp, matrix),
        child: child,
      );
    }

    final rect = Rect.fromCenter(center: Offset(c[0], c[1]), width: s[0], height: s[1]);
    if (m.invert) {
      return ClipPath(
        clipper: _InvertRectClipper(rect),
        child: child,
      );
    }
    ui.Gradient ramp(Offset a, Offset b, double len) {
      final e = len <= 0 ? 0.0 : (f / len).clamp(0.0, 0.5);
      return ui.Gradient.linear(
        a,
        b,
        const [Color(0x00FFFFFF), Color(0xFFFFFFFF), Color(0xFFFFFFFF), Color(0x00FFFFFF)],
        [0, e, 1 - e, 1],
      );
    }

    final w = rect.width + f, h = rect.height + f;
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (_) => ramp(Offset(rect.left - f / 2, 0), Offset(rect.right + f / 2, 0), w),
      child: ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (_) => ramp(Offset(0, rect.top - f / 2), Offset(0, rect.bottom + f / 2), h),
        child: child,
      ),
    );
  }
}

const List<double> _redOnly = [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0];
const List<double> _cyanOnly = [0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0];

/// Elliptical dark vignette (edge_blur).
class _VignettePainter extends CustomPainter {
  final double amount;
  _VignettePainter(this.amount);
  @override
  void paint(Canvas canvas, Size size) {
    if (amount <= 0) return;
    final w = size.width, h = size.height;
    final m = Float64List.fromList([w / 2, 0, 0, 0, 0, h / 2, 0, 0, 0, 0, 1, 0, w / 2, h / 2, 0, 1]);
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ui.Gradient.radial(Offset.zero, 1.25, [const Color(0x00000000), Color.fromRGBO(0, 0, 0, amount)], const [0.55, 1.0], TileMode.clamp, m),
    );
  }

  @override
  bool shouldRepaint(covariant _VignettePainter old) => old.amount != amount;
}

class _InvertRectClipper extends CustomClipper<Path> {
  final Rect hole;
  _InvertRectClipper(this.hole);
  @override
  Path getClip(Size size) => Path()
    ..fillType = PathFillType.evenOdd
    ..addRect(Offset.zero & size)
    ..addRect(hole);
  @override
  bool shouldReclip(covariant _InvertRectClipper old) => old.hole != hole;
}

class _GrainPainter extends CustomPainter {
  final int seed;
  final double amount;
  final double dot;
  _GrainPainter(this.seed, this.amount, this.dot);

  // Point buffer reused across frames (grain repaints 24× a second).
  static Float32List _pts = Float32List(0);

  @override
  void paint(Canvas canvas, Size size) {
    final rnd = math.Random(seed);
    final count = (size.width * size.height / (dot * dot * 40)).clamp(500, 20000).toInt();
    if (_pts.length < count * 2) _pts = Float32List(count * 2);
    final half = (count + 1) ~/ 2; // even points → light (first half), odd → dark
    for (int i = 0; i < count; i++) {
      final j = (i.isEven ? i ~/ 2 : half + i ~/ 2) * 2;
      _pts[j] = rnd.nextDouble() * size.width;
      _pts[j + 1] = rnd.nextDouble() * size.height;
    }
    final pl = Paint()
      ..color = Colors.white.withValues(alpha: 0.35 * amount)
      ..strokeWidth = dot
      ..strokeCap = StrokeCap.square;
    final pd = Paint()
      ..color = Colors.black.withValues(alpha: 0.45 * amount)
      ..strokeWidth = dot
      ..strokeCap = StrokeCap.square;
    canvas.drawRawPoints(ui.PointMode.points, Float32List.sublistView(_pts, 0, half * 2), pl);
    canvas.drawRawPoints(ui.PointMode.points, Float32List.sublistView(_pts, half * 2, count * 2), pd);
  }

  @override
  bool shouldRepaint(covariant _GrainPainter old) => old.seed != seed || old.amount != amount || old.dot != dot;
}

class _DustPainter extends CustomPainter {
  final double t, amount, dot;
  _DustPainter(this.t, this.amount, this.dot);
  @override
  void paint(Canvas canvas, Size size) {
    if (amount <= 0) return;
    final rnd = math.Random(7);
    final n = (60 + 240 * amount).round();
    final paint = Paint();
    for (int i = 0; i < n; i++) {
      final sx = rnd.nextDouble(), sy = rnd.nextDouble(), sp = 0.01 + rnd.nextDouble() * 0.03, ph = rnd.nextDouble() * 6;
      final x = ((sx + t * sp * 0.6 + math.sin(t * 0.7 + ph) * 0.01) % 1) * size.width;
      final y = ((sy - t * sp) % 1 + 1) % 1 * size.height;
      final a = (0.25 + 0.5 * (0.5 + 0.5 * math.sin(t * 2 + ph))) * amount;
      paint.color = Colors.white.withValues(alpha: a.clamp(0.0, 1.0));
      canvas.drawCircle(Offset(x, y), dot * (0.5 + rnd.nextDouble()), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _DustPainter old) => old.t != t || old.amount != amount;
}

class _ShardPainter extends CustomPainter {
  final double p;
  final Color color;
  final int seed;
  _ShardPainter(this.p, this.color, this.seed);
  @override
  void paint(Canvas canvas, Size size) {
    final rnd = math.Random(seed);
    final c = size.center(Offset.zero);
    final paint = Paint();
    for (int i = 0; i < 70; i++) {
      final a = rnd.nextDouble() * math.pi * 2;
      final speed = (0.3 + rnd.nextDouble()) * size.shortestSide * 0.9;
      final start = Offset(c.dx + (rnd.nextDouble() - 0.5) * size.width * 0.8, c.dy + (rnd.nextDouble() - 0.5) * size.height * 0.8);
      final pos = start + Offset(math.cos(a), math.sin(a)) * speed * p + Offset(0, p * p * size.height * 0.4);
      final r = size.shortestSide * (0.01 + rnd.nextDouble() * 0.035);
      final rot = rnd.nextDouble() * 6 + p * 8;
      paint.color = (i % 3 == 0 ? Colors.white : color).withValues(alpha: (1 - p).clamp(0.0, 1.0));
      canvas.save();
      canvas.translate(pos.dx, pos.dy);
      canvas.rotate(rot);
      canvas.drawPath(Path()..moveTo(-r, -r * 0.4)..lineTo(r, -r * 0.7)..lineTo(r * 0.3, r)..close(), paint);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _ShardPainter old) => old.p != p;
}

class _TexturePainter extends CustomPainter {
  final int seed;
  final double amount;
  final bool dark;
  _TexturePainter(this.seed, this.amount, {required this.dark});
  @override
  void paint(Canvas canvas, Size size) {
    if (amount <= 0) return;
    final rnd = math.Random(seed);
    final paint = Paint()..maskFilter = MaskFilter.blur(BlurStyle.normal, size.shortestSide * 0.03);
    for (int i = 0; i < 40; i++) {
      final o = Offset(rnd.nextDouble() * size.width, rnd.nextDouble() * size.height);
      final r = size.shortestSide * (0.05 + rnd.nextDouble() * 0.2);
      paint.color = (dark ? Colors.black : const Color(0xFF8B6B3D)).withValues(alpha: amount * (0.08 + rnd.nextDouble() * 0.15));
      canvas.drawCircle(o, r, paint);
    }
    final speck = Paint()..color = (dark ? Colors.black : const Color(0xFF5A4630)).withValues(alpha: amount * 0.35);
    for (int i = 0; i < 400; i++) {
      canvas.drawCircle(Offset(rnd.nextDouble() * size.width, rnd.nextDouble() * size.height), rnd.nextDouble() * 1.6, speck);
    }
  }

  @override
  bool shouldRepaint(covariant _TexturePainter old) => old.amount != amount;
}

const _lr = 0.2126, _lg = 0.7152, _lb = 0.0722;

/// brightness/contrast/saturation in -100..100 → Flutter 5x4 color matrix.
List<double> colorAdjustMatrix(double brightness, double contrast, double saturation) {
  final s = (saturation + 100) / 100;
  final c = (contrast + 100) / 100;
  final off = 128 * (1 - c) + brightness * 1.28;
  final sr = _lr * (1 - s), sg = _lg * (1 - s), sb = _lb * (1 - s);
  return [
    c * (sr + s), c * sg, c * sb, 0, off,
    c * sr, c * (sg + s), c * sb, 0, off,
    c * sr, c * sg, c * (sb + s), 0, off,
    0, 0, 0, 1, 0,
  ];
}

/// Blends toward luminance × tint color by [amount] (0..1).
List<double> tintMatrix(double r, double g, double b, double amount) {
  final a = amount.clamp(0.0, 1.0);
  final tr = r / 255, tg = g / 255, tb = b / 255;
  return [
    (1 - a) + a * tr * _lr, a * tr * _lg, a * tr * _lb, 0, 0,
    a * tg * _lr, (1 - a) + a * tg * _lg, a * tg * _lb, 0, 0,
    a * tb * _lr, a * tb * _lg, (1 - a) + a * tb * _lb, 0, 0,
    0, 0, 0, 1, 0,
  ];
}
