part of 'doc_transitions.dart';

// V3-D: transitions, mood & character FX for documentary patterns
// (refpack PATTERN_LIBRARY_SPEC P-D 35–54). Same rules as the V2 types:
// pure model code (keyframes, masks, effects, helper layers tr_<to>_*), every
// key eased, motion blur where things move fast, one undo step (the
// `transition` op runs inside the atomic dispatcher).

const _v3Dir = TransitionParam('direction', 'string', 'right', 'side the burst blasts in from',
    options: ['right', 'left', 'center', 'top', 'bottom']);

const List<TransitionDef> _v3Catalog = [
  TransitionDef('powder_burst', 'Powder Burst',
      'snowy / desert stories: a white powder cloud blasts across, full cover at the cut, flakes linger over the next shot (in/out of the presenter, any scene change)',
      duration: 0.65, pre: 0.55, sounds: ['powder_whoosh'], params: [
        _v3Dir,
        TransitionParam('kind', 'string', 'snow', 'powder', options: ['snow', 'dust', 'sand', 'ash']),
        TransitionParam('color', 'color', '#FFFFFF', 'powder colour (default by kind)'),
        TransitionParam('density', 'number', 80, 'amount of powder 0-100'),
        TransitionParam('linger', 'number', 0.3, 's the flakes stay over the incoming shot'),
      ]),
  TransitionDef('debris_burst', 'Debris Burst',
      'the most frequent documentary cut: ice / snow / glass / dust / leaves burst toward the lens, full cover for a few frames, debris clears over the next shot',
      duration: 0.7, pre: 0.55, sounds: ['ice_crash'], params: [
        TransitionParam('kind', 'string', 'ice', 'debris', options: ['ice', 'snow', 'cloud', 'glass', 'dust', 'leaves']),
        TransitionParam('from', 'string', 'center', 'where it bursts from',
            options: ['right', 'left', 'center', 'top', 'bottom', 'top_left', 'top_right', 'bottom_left', 'bottom_right']),
        TransitionParam('pre_roll', 'number', 1.2, 's of sparse shards drifting in before the burst'),
        TransitionParam('peak_cover', 'number', 100, 'how much of the frame is covered at the cut (0-100)'),
        TransitionParam('tail', 'number', 0.5, 's the debris takes to clear over the incoming shot'),
        TransitionParam('tone', 'string', 'cold', 'colour preset', options: ['cold', 'warm', 'neutral']),
        TransitionParam('density', 'number', 80, 'amount 0-100'),
      ]),
  TransitionDef('frost_shatter', 'Frost Shatter', 'cold / ice / mountain stories: frost crystals grow from a corner, then the shot shatters with a radial blur',
      duration: 1.4, pre: 0.75, sounds: ['ice_crash'], params: [
        TransitionParam('corner', 'string', 'top_left', 'where the frost grows from',
            options: ['top_left', 'top_right', 'bottom_left', 'bottom_right', 'center']),
      ]),
  TransitionDef('zoom_blur', 'Zoom Blur', 'evidence → reenactment / landscape, macro → presenter, leaving an archive photo on a pause',
      duration: 0.45, pre: 0.5, sounds: ['whoosh'], params: [
        TransitionParam('zoom', 'number', 2.5, 'how far the outgoing crashes in (2-3)'),
        TransitionParam('flash', 'bool', false, 'white flash on the cut'),
        TransitionParam('grain', 'bool', false, 'crash-zoom into film grain (exit variant)'),
        TransitionParam('cx', 'number', 50, 'zoom centre X % of the frame'),
        TransitionParam('cy', 'number', 50, 'zoom centre Y % of the frame'),
      ]),
  TransitionDef('eye_reflection', 'Eye Reflection', 'event → witness reaction: the event is seen in the pupil of the incoming eye close-up, which pulls back 5× → 1×',
      duration: 0.9, pre: 0.3, sounds: ['braam'], params: [
        TransitionParam('point', 'point', null, '[x, y] of the pupil in the incoming shot (default the frame centre)'),
        TransitionParam('size', 'number', null, 'pupil diameter px (default 15% of the width)'),
        TransitionParam('opacity', 'number', 70, 'reflection opacity %'),
        TransitionParam('linger', 'number', 0.8, 's the reflection stays in the eye after the pull-back'),
      ]),
  TransitionDef('holes', 'Burn Holes', 'harsh exit from a gruesome still to the presenter: 30-60 burnt holes open and eat the shot',
      duration: 0.5, pre: 0.8, sounds: ['swoosh_reverse'], params: [
        TransitionParam('count', 'number', 45, 'number of holes (30-60)'),
        TransitionParam('size', 'number', 10, 'largest hole, % of the width'),
        TransitionParam('rim', 'color', '#603212', 'burnt rim colour'),
      ]),
  TransitionDef('shatter', 'Shatter', 'impact moments: cracks spread, then the shot breaks into shards (tone ice = frozen glass)',
      duration: 1.4, pre: 0.75, sounds: ['ice_crash'], params: [
        TransitionParam('tone', 'string', 'glass', 'shard look', options: ['glass', 'ice', 'gold']),
        TransitionParam('lead_in', 'number', 1.0, 's of cracks before the break'),
        TransitionParam('shard_color', 'color', null, 'shard colour (ice: #BFE6FF)'),
        TransitionParam('cx', 'number', 55, 'impact X %'),
        TransitionParam('cy', 'number', 45, 'impact Y %'),
      ]),
  TransitionDef('slice', 'Slice', 'fast topic changes: 3-4 horizontal bands of the next shot slide in from alternating sides',
      duration: 0.4, pre: 0.5, sounds: ['whoosh'], params: [
        TransitionParam('bands', 'number', 4, 'number of bands'),
        TransitionParam('stagger', 'number', 30, 'delay between bands 0-100'),
      ]),
  TransitionDef('slant_wipe', 'Slant Wipe', 'a ~10° diagonal panel slides in from a side while the old shot (a map) compresses aside',
      duration: 0.75, sounds: ['whoosh'], params: [
        TransitionParam('direction', 'string', 'right', 'side the panel enters from', options: ['left', 'right', 'top', 'bottom']),
        TransitionParam('angle', 'number', 10, 'slant of the edge in degrees'),
        TransitionParam('edge', 'number', 60, 'white edge highlight 0-100'),
      ]),
  TransitionDef('shrink_to_card', 'Shrink to Card', 'footage shrinks into a bordered card with a shadow over the next shot (grunge red background): the shot becomes evidence',
      duration: 1.0, pre: 0.35, sounds: ['swoosh_short'], params: [
        TransitionParam('size', 'number', 0.45, 'card size as a share of the frame'),
        TransitionParam('bg', 'string', 'grunge_red', 'look of the incoming background', options: ['grunge_red', 'none']),
        TransitionParam('tilt', 'number', -4, 'card rotation in degrees'),
        TransitionParam('hold', 'number', 1.5, 's the card stays before it drops away'),
        TransitionParam('border', 'color', '#FFFFFF', 'card border colour'),
      ]),
  TransitionDef('emerge', 'Emerge', 'the next card / photo grows out of a point or layer (inverse of zoom_into_photo)',
      duration: 0.75, pre: 0.0, sounds: ['swoosh_short'], params: [
        TransitionParam('target', 'layer', null, 'layer it grows out of (default the point / the frame centre)'),
        TransitionParam('point', 'point', null, '[x, y] screen point it grows from'),
        TransitionParam('from', 'number', 0.05, 'start size as a share of the rest size'),
      ]),
  TransitionDef('zoom_out_of_photo', 'Zoom Out of Photo', 'proving a claim: pull back from a full-frame photo to reveal it inside an article / book page / screen',
      duration: 1.1, pre: 0.1, sounds: ['paper'], params: [
        TransitionParam('layer', 'layer', null, 'the photo inside the incoming shot (this comp or inside the incoming precomp, e.g. <article>_embed)'),
        TransitionParam('photo_box', 'size', null, '[x0, y0, x1, y1] screen box of the photo in the incoming shot (instead of layer)'),
        _v3Point,
        _v3Size,
      ]),
  TransitionDef('slide_film', 'Slide Film', 'reconstruction → real archive photo: the frame shrinks into a 35 mm slide mount, the carousel moves to the next slide, it grows to full frame',
      duration: 1.0, pre: 0.5, sounds: ['shutter'], params: [
        TransitionParam('size', 'number', 0.55, 'slide size while in the carousel'),
        TransitionParam('pink', 'number', 30, 'faded-pink archive tint on the incoming slide 0-100'),
      ]),
  TransitionDef('exposure_in', 'Exposure In (Sun Glare)', 'sun-glare entry: the incoming starts over-exposed with bloom and rays that fade',
      duration: 0.75, pre: 0.0, sounds: ['swoosh_short'], params: [
        TransitionParam('from', 'number', 3.0, 'starting exposure (1 = normal)'),
        TransitionParam('color', 'color', '#FFF1D6', 'glare colour'),
      ]),
  TransitionDef('punch_in', 'Punch In', 'presenter returns: the incoming enters at 150% blurred and snaps to 100% in 0.25 s',
      duration: 0.25, pre: 0.0, sounds: ['whoosh']),
  TransitionDef('cut_to_black', 'Cut to Black', 'crash → black: a hard cut into black and silence before the next beat',
      duration: 1.5, pre: 0.0, sounds: ['impact'], params: [
        TransitionParam('silence', 'bool', true, 'duck music / voice to silence during the black'),
      ]),
];

const _v3Point = TransitionParam('point', 'point', null, '[x, y] centre of the photo in the incoming shot (with size)');
const _v3Size = TransitionParam('size', 'size', null, '[w, h] of the photo in the incoming shot');

/// V3-D: ducks every audio / video track of [comp] active over [from, to]
/// to silence (fast eased dip, recovery 0.35 s after [to]); layers whose id
/// starts with [skipPrefix] are left alone. Returns how many were ducked.
int v3DuckAudio(Composition comp, double from, double to, double fr, {String? skipPrefix}) {
  var n = 0;
  for (final l in comp.layers) {
    if (l.type != LayerType.audio && l.type != LayerType.video) continue;
    if (skipPrefix != null && l.id.startsWith(skipPrefix)) continue;
    if (l.end <= from || l.start >= to) continue;
    final vol = l.prop(Props.volume);
    final before = vol.valueAt(from - fr * 2)[0];
    final after = vol.valueAt(to + 0.35)[0];
    vol.keyframes.removeWhere((k) => k.time > from - fr * 2 - kTimeEpsilon && k.time < to + 0.35 + kTimeEpsilon);
    if (l.start < from - fr * 2) vol.setKeyframe(from - fr * 2, [before], easing: _inCubic);
    vol.setKeyframe(from, [0], easing: Easing.hold);
    vol.setKeyframe(to, [0], easing: _outCubic);
    if (l.end > to + 0.35) vol.setKeyframe(to + 0.35, [after], easing: _outCubic);
    n++;
  }
  return n;
}

extension _V3Ctx on _Ctx {
  /// Runs V3 transition [type]; false when it is not one.
  bool v3(String type) {
    switch (type) {
      case 'powder_burst':
        powderBurst();
      case 'debris_burst':
        debrisBurst();
      case 'frost_shatter':
        frostShatter();
      case 'zoom_blur':
        zoomBlur();
      case 'eye_reflection':
        eyeReflection();
      case 'holes':
        holesBurn();
      case 'shatter':
        shatterBreak();
      case 'slice':
        slice();
      case 'slant_wipe':
        slantWipe();
      case 'shrink_to_card':
        shrinkToCard();
      case 'emerge':
        emerge();
      case 'zoom_out_of_photo':
        zoomOutOfPhoto();
      case 'slide_film':
        slideFilm();
      case 'exposure_in':
        exposureIn();
      case 'punch_in':
        punchIn();
      case 'cut_to_black':
        cutToBlack();
      default:
        return false;
    }
    return true;
  }

  List<double> colorParam(String k, String def) => _Ctx._rgb(str(k, def));

  bool flag(String k, bool d) {
    final v = params[k];
    if (v == null) return d;
    if (v is bool) return v;
    return '$v' == 'true';
  }

  /// A full-frame helper layer directly BELOW both shots.
  Layer underlay(String kind, {String name = 'Backdrop', int color = 0xFF000000, double? start, double? end}) {
    final l = overlay(kind, name: name, color: color, start: start, end: end);
    comp.layers.remove(l);
    final idx = math.max(comp.indexOf(a.id), comp.indexOf(b.id));
    comp.layers.insert(idx + 1, l);
    return l;
  }

  /// A transparent full-frame overlay carrying a `burst` effect whose full
  /// cover is centred on the cut (2.5 frames).
  Layer burstLayer({
    required int kind,
    required int origin,
    required double density,
    required List<double> color,
    double preRoll = 0,
    double cover = 100,
    double linger = 0.3,
    double? clear,
    String tag = 'burst',
  }) {
    final rise = math.max(fr * 2, (cut - t0) * 0.9);
    final st = math.max(0.0, math.min(t0, cut - rise - fr * 1.25 - preRoll));
    final en = t1 + linger + 0.05;
    final o = overlay(tag, name: 'Burst', start: st, end: en);
    fx(o, 'burst', values: {
      'kind': [kind.toDouble()],
      'origin': [origin.toDouble()],
      'density': [density.clamp(0.0, 100.0).toDouble()],
      'color': color,
      'cut': [cut - st],
      'rise': [rise],
      'hold': [fr * 2.5],
      'clear': [clear ?? math.max(fr * 2, (t1 - cut) * 0.65)],
      'linger': [math.max(0.0, linger)],
      'pre_roll': [math.max(0.0, preRoll)],
      'cover': [cover.clamp(0.0, 100.0).toDouble()],
    });
    return o;
  }

  /// The outgoing pushes toward the lens into the burst, the incoming
  /// settles out of it (hard cut hidden under the full cover).
  void burstShots({double push = 1.08, double settle = 1.06}) {
    hardCut();
    _Ctx.key(a.prop(Props.scale), t0, aScale, _inCubic);
    _Ctx.key(a.prop(Props.scale), cut, [aScale[0] * push, aScale[1] * push, aScale[2]], _inCubic);
    _Ctx.keys(fx(a, 'blur').params['amount']!..staticValue = [0], [(t0 + (cut - t0) * 0.5, 0, _inCubic), (cut, 14, _inCubic)]);
    _Ctx.key(b.prop(Props.scale), cut, [bScale[0] * settle, bScale[1] * settle, bScale[2]], _expoOut);
    _Ctx.key(b.prop(Props.scale), t1, bScale, _expoOut);
    _Ctx.keys(fx(b, 'blur').params['amount']!..staticValue = [0], [(cut, 12, _expoOut), (t1, 0, _expoOut)]);
  }

  // 47. Powder burst (signature): white powder blasting across the frame.
  void powderBurst() {
    final dir = choice('direction', 'right', const ['right', 'left', 'center', 'top', 'bottom']);
    final kind = choice('kind', 'snow', const ['snow', 'dust', 'sand', 'ash']);
    final defColor = switch (kind) { 'dust' => '#CDB896', 'sand' => '#DDB77E', 'ash' => '#8E8984', _ => '#FFFFFF' };
    burstShots();
    burstLayer(
      kind: kBurstKinds.indexOf(kind),
      origin: kBurstOrigins.indexOf(dir),
      density: n('density', 80),
      color: colorParam('color', defColor),
      linger: n('linger', 0.3).clamp(0.0, 3.0).toDouble(),
    );
  }

  // 36. Debris burst (most frequent): sparse shards first, dense burst at the cut.
  void debrisBurst() {
    final kind = choice('kind', 'ice', const ['ice', 'snow', 'cloud', 'glass', 'dust', 'leaves']);
    final from = choice('from', 'center', kBurstOrigins);
    final tone = choice('tone', 'cold', const ['cold', 'warm', 'neutral']);
    final base = switch (kind) {
      'ice' => const [221.0, 242.0, 255.0],
      'glass' => const [232.0, 244.0, 255.0],
      'cloud' => const [242.0, 245.0, 248.0],
      'dust' => const [196.0, 176.0, 146.0],
      'leaves' => const [255.0, 255.0, 255.0],
      _ => const [255.0, 255.0, 255.0],
    };
    final tint = switch (tone) { 'warm' => const [1.0, 0.95, 0.85], 'neutral' => const [1.0, 1.0, 1.0], _ => const [0.96, 0.99, 1.0] };
    final col = params['color'] is String ? colorParam('color', '#FFFFFF') : [for (int i = 0; i < 3; i++) (base[i] * tint[i]).clamp(0.0, 255.0).toDouble()];
    final tail = n('tail', 0.5).clamp(0.1, 3.0).toDouble();
    burstShots(push: 1.1);
    burstLayer(
      kind: kBurstKinds.indexOf(kind),
      origin: kBurstOrigins.indexOf(from),
      density: n('density', 80),
      color: col,
      preRoll: n('pre_roll', 1.2).clamp(0.0, 3.0).toDouble(),
      cover: n('peak_cover', 100),
      clear: tail * 0.55,
      linger: tail,
    );
  }

  // 36b. Frost shatter: crystals grow from a corner, then the shot breaks.
  void frostShatter() {
    incomingOnTop(false);
    final corner = choice('corner', 'top_left', const ['top_left', 'top_right', 'bottom_left', 'bottom_right', 'center']);
    final ci = const ['top_left', 'top_right', 'bottom_left', 'bottom_right', 'center'].indexOf(corner);
    final grown = cut - (cut - t0) * 0.12;
    _Ctx.keys(fx(a, 'frost', values: {'corner': [ci.toDouble()]}).params['progress']!, [(t0, 0, _soft), (grown, 100, _soft)]);
    _Ctx.keys(fx(a, 'tint', values: {'color': [150, 200, 255]}).params['amount']!, [(t0, 0, _inOut), (grown, 35, _inOut)]);
    _Ctx.keys(fx(a, 'radial_blur').params['amount']!, [(grown, 0, _expoIn), (cut, 70, _expoIn), (t1, 100, _outCubic)]);
    _Ctx.keys(fx(a, 'shatter', values: {'color': [205, 235, 255]}).params['progress']!, [(cut - fr, 0, _outCubic), (t1, 100, _outCubic)]);
    _setEnd(a, t1);
    _Ctx.key(b.prop(Props.scale), cut, [bScale[0] * 1.08, bScale[1] * 1.08, bScale[2]], _expoOut);
    _Ctx.key(b.prop(Props.scale), t1, bScale, _expoOut);
    _Ctx.keys(fx(b, 'blur').params['amount']!..staticValue = [0], [(cut - fr, 18, _expoOut), (t1, 0, _expoOut)]);
    _Ctx.keys(fx(b, 'flash', values: {'color': [220, 240, 255]}).params['amount']!, [(cut - fr, 35, _expoOut), (cut + (t1 - cut) * 0.5, 0, _expoOut)]);
    burstLayer(kind: 4, origin: 2, density: 55, color: const [225.0, 244.0, 255.0], cover: 0, linger: 0.4, tag: 'shards');
  }

  // 35. Zoom blur: the outgoing crashes in with a radial blur, the incoming settles.
  void zoomBlur() {
    hardCut();
    final k = n('zoom', 2.5).clamp(1.2, 6.0).toDouble();
    final cx = n('cx', 50) / 100 * w, cy = n('cy', 50) / 100 * h;
    zoomKey(a, t0, 1, cx, cy, aPos, aScale, _expoIn);
    zoomKey(a, cut, k, cx, cy, aPos, aScale, _expoIn);
    _Ctx.keys(fx(a, 'radial_blur', values: {'cx': [n('cx', 50)], 'cy': [n('cy', 50)]}).params['amount']!, [(t0, 0, _expoIn), (cut, 90, _expoIn)]);
    const settle = 1.5;
    zoomKey(b, cut, settle, cx, cy, bPos, bScale, _expoOut);
    zoomKey(b, t1, 1, cx, cy, bPos, bScale, _expoOut);
    _Ctx.keys(fx(b, 'radial_blur', values: {'cx': [n('cx', 50)], 'cy': [n('cy', 50)]}).params['amount']!, [(cut, 75, _expoOut), (t1, 0, _expoOut)]);
    for (final l in [a, b]) {
      fx(l, 'motion_blur', values: {'amount': [100]});
    }
    if (flag('flash', false)) {
      _Ctx.keys(fx(a, 'flash').params['amount']!, [(t0 + (cut - t0) * 0.5, 0, _expoIn), (cut, 85, _expoIn)]);
      _Ctx.keys(fx(b, 'flash').params['amount']!, [(cut, 85, _expoOut), (cut + (t1 - cut) * 0.6, 0, _expoOut)]);
    }
    if (flag('grain', false)) {
      _Ctx.keys(fx(a, 'grain', values: {'size': [3]}).params['amount']!, [(t0, 0, _expoIn), (cut, 90, _expoIn)]);
    }
  }

  // 48. Eye reflection: the outgoing is seen in the pupil of the incoming eye ECU.
  void eyeReflection() {
    incomingOnTop(false);
    final pt = vec('point');
    final px = pt != null && pt.length >= 2 ? pt[0] : w / 2;
    final py = pt != null && pt.length >= 2 ? pt[1] : h / 2;
    final d = math.max(8.0, optNum('size') ?? w * 0.15);
    final op = n('opacity', 70).clamp(0.0, 100.0).toDouble();
    final linger = n('linger', 0.8).clamp(0.0, 5.0).toDouble();
    const k = 5.0;
    // The incoming: 5× on the pupil, pulls back to 1× (expo-out).
    zoomKey(b, t0, k, px, py, bPos, bScale, _soft);
    zoomKey(b, cut, k, px, py, bPos, bScale, _expoOut);
    zoomKey(b, t1, 1, px, py, bPos, bScale, _expoOut);
    fx(b, 'motion_blur', values: {'amount': [70]});
    _Ctx.keys(fx(b, 'blur').params['amount']!..staticValue = [0], [(cut, 10, _expoOut), (t1, 0, _expoOut)]);
    // The outgoing shrinks into the (zoomed) pupil, then rides the pull-back.
    final hs = math.max(1.0, a.height * aScale[1] / 100);
    final f1 = d * k / hs;
    _Ctx.key(a.prop(Props.position), t0, aPos, _inOut);
    _Ctx.key(a.prop(Props.position), cut, [px, py, aPos[2]], _expoOut);
    _Ctx.key(a.prop(Props.position), t1, [px, py, aPos[2]], _expoOut);
    _Ctx.key(a.prop(Props.scale), t0, aScale, _inOut);
    _Ctx.key(a.prop(Props.scale), cut, [aScale[0] * f1, aScale[1] * f1, aScale[2]], _expoOut);
    _Ctx.key(a.prop(Props.scale), t1, [aScale[0] * f1 / k, aScale[1] * f1 / k, aScale[2]], _expoOut);
    _Ctx.keys(a.prop(Props.opacity), [(t0, aOpacity, _inOut), (cut, aOpacity * op / 100, _inOut), (t1 + linger * 0.4, aOpacity * op / 100, _inOut), (t1 + linger, 0, _inOut)]);
    final diag = math.sqrt(a.width * a.width + a.height * a.height) * 1.1;
    final id = '${a.id}_trout_pupil';
    a.masks.removeWhere((m) => m.id == id);
    final size = AnimProp([diag, diag]);
    size.setKeyframe(t0, [diag, diag], easing: _inOut);
    size.setKeyframe(cut, [a.height, a.height], easing: _inOut);
    a.masks.add(Mask(id: id, shape: 'ellipse', props: {
      'center': AnimProp([a.width / 2, a.height / 2]),
      'size': size,
      'feather': AnimProp([a.height * 0.07]),
    }));
    // A glassy, bulging reflection.
    fx(a, 'lens_distortion', values: {'amount': [45]});
    fx(a, 'color', values: {'brightness': [8], 'contrast': [12], 'saturation': [-10]});
    _setEnd(a, t1 + linger);
  }

  // 49. Burnt holes open and eat the outgoing.
  void holesBurn() {
    incomingOnTop(false);
    final e = fx(a, 'holes', values: {
      'count': [n('count', 45).clamp(5, 120).toDouble()],
      'size': [n('size', 10).clamp(2, 40).toDouble()],
      'rim': colorParam('rim', '#603212'),
    });
    _Ctx.keys(e.params['progress']!, [(t0, 0, _inCubic), (cut, 100, _inCubic)]);
    _setEnd(a, cut + fr);
    _Ctx.key(b.prop(Props.scale), t0, [bScale[0] * 1.05, bScale[1] * 1.05, bScale[2]], _outCubic);
    _Ctx.key(b.prop(Props.scale), t1, bScale, _outCubic);
    _Ctx.keys(fx(b, 'color').params['brightness']!, [(t0, -30, _outCubic), (t1, 0, _outCubic)]);
  }

  // 49b. Shatter with a crack lead-in (tone ice / glass / gold).
  void shatterBreak() {
    incomingOnTop(false);
    final tone = choice('tone', 'glass', const ['glass', 'ice', 'gold']);
    final shard = params['shard_color'] is String
        ? colorParam('shard_color', '#BFE6FF')
        : switch (tone) { 'ice' => const [191.0, 230.0, 255.0], 'gold' => const [255.0, 200.0, 40.0], _ => const [236.0, 244.0, 250.0] };
    final lead = n('lead_in', 1.0).clamp(0.05, 5.0).toDouble();
    final c0 = math.max(a.start + fr, cut - lead);
    final cx = n('cx', 55), cy = n('cy', 45);
    _Ctx.keys(fx(a, 'cracks', values: {'cx': [cx], 'cy': [cy], 'color': tone == 'gold' ? const [255.0, 230.0, 160.0] : const [235.0, 245.0, 255.0]}).params['progress']!,
        [(c0, 0, _outCubic), (cut - fr * 2, 100, _outCubic)]);
    if (tone == 'ice') {
      _Ctx.keys(fx(a, 'tint', values: {'color': [150, 205, 255]}).params['amount']!, [(c0, 0, _inOut), (cut, 40, _inOut)]);
      _Ctx.keys(fx(a, 'frost', values: {'corner': [4]}).params['progress']!, [(c0, 0, _soft), (cut, 45, _soft)]);
    }
    // The hit: a small punch, then the break.
    _Ctx.key(a.prop(Props.scale), c0, aScale, _outCubic);
    _Ctx.key(a.prop(Props.scale), cut, [aScale[0] * 1.03, aScale[1] * 1.03, aScale[2]], _outCubic);
    _Ctx.keys(fx(a, 'shatter', values: {'color': shard}).params['progress']!, [(cut - fr, 0, _outCubic), (t1, 100, _outCubic)]);
    _Ctx.keys(fx(a, 'radial_blur', values: {'cx': [cx], 'cy': [cy]}).params['amount']!, [(cut - fr, 0, _outCubic), (t1, 60, _outCubic)]);
    _Ctx.key(b.prop(Props.scale), cut, [bScale[0] * 1.05, bScale[1] * 1.05, bScale[2]], _expoOut);
    _Ctx.key(b.prop(Props.scale), t1, bScale, _expoOut);
    _Ctx.keys(fx(b, 'blur').params['amount']!..staticValue = [0], [(cut - fr, 16, _expoOut), (t1, 0, _expoOut)]);
    _Ctx.keys(fx(b, 'flash').params['amount']!, [(cut - fr, 40, _expoOut), (cut + (t1 - cut) * 0.5, 0, _expoOut)]);
  }

  // 38a. Slice: bands of the incoming slide in from alternating sides.
  void slice() {
    final e = fx(b, 'slices', values: {'bands': [n('bands', 4).clamp(2, 12).roundToDouble()], 'stagger': [n('stagger', 30).clamp(0, 100).toDouble()]});
    _Ctx.keys(e.params['progress']!, [(t0, 0, _soft), (t1, 100, _soft)]);
    _Ctx.keys(fx(a, 'color').params['brightness']!, [(t0, 0, _inOut), (t1, -25, _inOut)]);
    _Ctx.key(a.prop(Props.scale), t0, aScale, _inOut);
    _Ctx.key(a.prop(Props.scale), t1, [aScale[0] * 0.96, aScale[1] * 0.96, aScale[2]], _inOut);
  }

  // 38b. Slant wipe: a slanted panel slides in, the old shot compresses aside.
  void slantWipe() {
    final side = choice('direction', 'right', const ['left', 'right', 'top', 'bottom']);
    final si = const ['left', 'right', 'top', 'bottom'].indexOf(side);
    final e = fx(b, 'slant_wipe', values: {
      'angle': [n('angle', 10).clamp(-45, 45).toDouble()],
      'side': [si.toDouble()],
      'edge': [n('edge', 60).clamp(0, 100).toDouble()],
    });
    _Ctx.keys(e.params['progress']!, [(t0, 0, _inOut), (t1, 100, _inOut)]);
    // Travel: the panel content slides in with the edge; the old shot is pushed aside.
    final (dx, dy) = switch (side) { 'left' => (1.0, 0.0), 'top' => (0.0, 1.0), 'bottom' => (0.0, -1.0), _ => (-1.0, 0.0) };
    final span = dy == 0 ? w : h;
    _Ctx.key(b.prop(Props.position), t0, [bPos[0] - dx * span * 0.3, bPos[1] - dy * span * 0.3, bPos[2]], _inOut);
    _Ctx.key(b.prop(Props.position), t1, bPos, _inOut);
    _Ctx.key(a.prop(Props.position), t0, aPos, _inOut);
    _Ctx.key(a.prop(Props.position), t1, [aPos[0] + dx * span * 0.35, aPos[1] + dy * span * 0.35, aPos[2]], _inOut);
    _Ctx.key(a.prop(Props.scale), t0, aScale, _inOut);
    _Ctx.key(a.prop(Props.scale), t1, [aScale[0] * (dy == 0 ? 0.82 : 0.95), aScale[1] * (dy == 0 ? 0.95 : 0.82), aScale[2]], _inOut);
    _Ctx.keys(fx(a, 'color').params['brightness']!, [(t0, 0, _inOut), (t1, -30, _inOut)]);
    for (final l in [a, b]) {
      fx(l, 'motion_blur', values: {'amount': [70]});
    }
  }

  // 38c. Shrink to card: the shot becomes a bordered card on the next shot.
  void shrinkToCard() {
    incomingOnTop(false);
    final s = n('size', 0.45).clamp(0.15, 0.9).toDouble();
    final tilt = n('tilt', -4).clamp(-30, 30).toDouble();
    final hold = n('hold', 1.5).clamp(0.0, 30.0).toDouble();
    final border = colorParam('border', '#FFFFFF');
    final cy = h * 0.47;
    final endT = t1 + hold;
    final exit = math.max(cut + fr, endT - math.min(0.35, (endT - cut) * 0.4));
    _Ctx.key(a.prop(Props.scale), t0, aScale, _inOut);
    _Ctx.key(a.prop(Props.scale), cut, [aScale[0] * s, aScale[1] * s, aScale[2]], _outCubic);
    _Ctx.key(a.prop(Props.scale), exit, [aScale[0] * s * 1.03, aScale[1] * s * 1.03, aScale[2]], _inCubic);
    _Ctx.key(a.prop(Props.position), t0, aPos, _inOut);
    _Ctx.key(a.prop(Props.position), cut, [w / 2 + (aPos[0] - w / 2) * s, cy + (aPos[1] - h / 2) * s, aPos[2]], _outCubic);
    _Ctx.key(a.prop(Props.position), exit, [w / 2 + (aPos[0] - w / 2) * s, cy + (aPos[1] - h / 2) * s, aPos[2]], _inCubic);
    _Ctx.key(a.prop(Props.position), endT, [w / 2, h * 1.6, aPos[2]], _inCubic);
    _Ctx.key(a.prop(Props.rotation), t0, aRot, _inOut);
    _Ctx.key(a.prop(Props.rotation), cut, [aRot[0], aRot[1], aRot[2] + tilt], _outCubic);
    _Ctx.key(a.prop(Props.rotation), exit, [aRot[0], aRot[1], aRot[2] + tilt], _inCubic);
    _Ctx.key(a.prop(Props.rotation), endT, [aRot[0], aRot[1], aRot[2] + tilt * 3], _inCubic);
    final lw = 14 / math.max(0.05, s * aScale[0] / 100);
    _Ctx.keys(fx(a, 'outline', values: {'color': border}).params['width']!, [(t0, 0, _inOut), (cut, lw, _inOut)]);
    _Ctx.keys(fx(a, 'shadow', values: {'distance': [22], 'blur': [30]}).params['opacity']!, [(t0, 0, _inOut), (cut, 65, _inOut)]);
    fx(a, 'motion_blur', values: {'amount': [60]});
    _setEnd(a, endT);
    if (choice('bg', 'grunge_red', const ['grunge_red', 'none']) == 'grunge_red') {
      fx(b, 'duotone', values: {'dark': [30, 4, 8], 'light': [205, 52, 60], 'amount': [85]});
      fx(b, 'grunge', values: {'amount': [55]});
    }
    _Ctx.key(b.prop(Props.scale), t0, [bScale[0] * 1.1, bScale[1] * 1.1, bScale[2]], _outCubic);
    _Ctx.key(b.prop(Props.scale), t1, bScale, _outCubic);
    _Ctx.keys(fx(b, 'blur').params['amount']!..staticValue = [0], [(t0, 22, _outCubic), (t1, 4, _outCubic)]);
  }

  // 38d. Emerge: the incoming grows out of a point / layer.
  void emerge() {
    final (r, _) = region('target', defaultShare: 0.05);
    final k = n('from', 0.05).clamp(0.01, 0.9).toDouble();
    zoomKey(b, t0, k, r.cx, r.cy, bPos, bScale, _expoOut);
    zoomKey(b, t1, 1, r.cx, r.cy, bPos, bScale, _expoOut);
    _Ctx.key(b.prop(Props.rotation), t0, [bRot[0], bRot[1], bRot[2] - 6], _expoOut);
    _Ctx.key(b.prop(Props.rotation), t1, bRot, _expoOut);
    _Ctx.keys(b.prop(Props.opacity), [(t0, 0, _outCubic), (t0 + dur * 0.15, bOpacity, _outCubic)]);
    _Ctx.keys(fx(b, 'shadow', values: {'distance': [18], 'blur': [28]}).params['opacity']!, [(t0, 60, _inOut), (t1, 0, _inOut)]);
    fx(b, 'motion_blur', values: {'amount': [70]});
    _Ctx.keys(fx(a, 'color').params['brightness']!, [(t0, 0, _inOut), (t1, -35, _inOut)]);
    _Ctx.keys(fx(a, 'blur').params['amount']!..staticValue = [0], [(t0, 0, _inOut), (t1, 10, _inOut)]);
  }

  /// Screen box of the photo inside the incoming shot at rest (t1).
  _Box photoBox() {
    final pb = vec('photo_box');
    if (pb != null && pb.length >= 4) {
      return _Box(math.min(pb[0], pb[2]), math.min(pb[1], pb[3]), math.max(pb[0], pb[2]), math.max(pb[1], pb[3]));
    }
    final id = params['layer'] ?? params['target'];
    if (id is String) {
      final l = comp.layerById(id);
      if (l != null) {
        if (l.id == a.id) throw ArgumentError('zoom_out_of_photo layer cannot be the outgoing layer');
        if (l.id == b.id) return _Box(0, 0, w, h);
        return _screenBox(_matrixAt(comp, l, t1), l.width, l.height);
      }
      final p = project;
      final child = p == null ? null : Precomp.childOf(p, b);
      final inner = child?.layerById(id);
      if (child != null && inner != null) {
        final ct = Precomp.childTime(b, child, t1) ?? 0;
        final mi = _matrixAt(child, inner, ct);
        final mb = _matrixAt(comp, b, t1);
        final corners = [
          for (final (x, y) in [(0.0, 0.0), (inner.width, 0.0), (inner.width, inner.height), (0.0, inner.height)]) _Ctx._proj(mi, x, y),
        ];
        return _Ctx._boxOf([for (final (x, y) in corners) _Ctx._proj(mb, x, y)]);
      }
      throw ArgumentError('zoom_out_of_photo: no layer "$id" in this comp${child != null ? ' or in the incoming precomp' : ''}');
    }
    final pt = vec('point');
    if (pt != null && pt.length >= 2) {
      final s = vec('size');
      final sw = s == null ? w * 0.4 : s[0];
      final sh = s == null ? h * 0.4 : (s.length > 1 ? s[1] : s[0]);
      return _Box.around(pt[0], pt[1], math.max(8.0, sw), math.max(8.0, sh));
    }
    return _Box.around(w / 2, h / 2, w * 0.4, h * 0.4);
  }

  // 13 / 38e. Zoom out of photo: the outgoing becomes the photo inside the incoming.
  void zoomOutOfPhoto() {
    incomingOnTop(false);
    final r = photoBox();
    final k = math.max(1.01, math.max(w / math.max(1, r.w), h / math.max(1, r.h)) * 1.02);
    // Fixed point so the photo centre sits on the frame centre at k.
    final qx = (r.cx * k - w / 2) / (k - 1), qy = (r.cy * k - h / 2) / (k - 1);
    zoomKey(b, t0, k, qx, qy, bPos, bScale, _inOut);
    zoomKey(b, cut, k, qx, qy, bPos, bScale, _inOut);
    zoomKey(b, t1, 1, qx, qy, bPos, bScale, _inOut);
    // The outgoing rides the same pull-back (it IS the photo), then hands over.
    zoomKey(a, cut, 1, qx, qy, aPos, aScale, _inOut);
    zoomKey(a, t1, 1 / k, qx, qy, aPos, aScale, _inOut);
    _Ctx.keys(a.prop(Props.opacity), [(t1 - (t1 - cut) * 0.35, aOpacity, _inOut), (t1, 0, _inOut)]);
    _Ctx.keys(fx(b, 'blur').params['amount']!..staticValue = [0], [(cut, 8, _outCubic), (t1, 0, _outCubic)]);
    for (final l in [a, b]) {
      fx(l, 'motion_blur', values: {'amount': [60]});
    }
  }

  // 37. Slide film: into a 35 mm mount, carousel advance, next slide grows.
  void slideFilm() {
    final s = n('size', 0.55).clamp(0.2, 0.9).toDouble();
    final pink = n('pink', 30).clamp(0.0, 100.0).toDouble();
    final p1 = t0 + dur * 0.25, p2 = t0 + dur * 0.75;
    final step = h * 0.78;
    const win = 0.78;
    final c = [w / 2, h / 2, 0.0];
    final bg = underlay('carousel', name: 'Slide carousel', color: 0xFF15110E);
    fx(bg, 'vignette', values: {'amount': [70], 'size': [55]});
    fx(bg, 'grain', values: {'amount': [18]});
    Layer mount(String tag, double st, double en) {
      final m = overlay(tag, name: 'Slide mount', start: st, end: en, width: w / win, height: h / win);
      fx(m, 'slide_mount', values: {'window': [win * 100], 'number': [(tag == 'mount_a' ? 11 : 12).toDouble()]});
      fx(m, 'motion_blur', values: {'amount': [60]});
      return m;
    }

    // Outgoing slide: shrink into its mount, then advance up and away.
    _Ctx.key(a.prop(Props.scale), t0, aScale, _inOut);
    _Ctx.key(a.prop(Props.scale), p1, [aScale[0] * s, aScale[1] * s, aScale[2]], _inOut);
    _Ctx.key(a.prop(Props.position), t0, aPos, _inOut);
    _Ctx.key(a.prop(Props.position), p1, [c[0] + (aPos[0] - c[0]) * s, c[1] + (aPos[1] - c[1]) * s, aPos[2]], _inOut);
    _Ctx.key(a.prop(Props.position), p2, [c[0] + (aPos[0] - c[0]) * s, c[1] + (aPos[1] - c[1]) * s - step, aPos[2]], _inOut);
    final ma = mount('mount_a', t0, p2 + fr);
    _Ctx.key(ma.prop(Props.scale), t0, [100, 100, 100], _inOut);
    _Ctx.key(ma.prop(Props.scale), p1, [100 * s, 100 * s, 100], _inOut);
    _Ctx.key(ma.prop(Props.position), p1, c, _inOut);
    _Ctx.key(ma.prop(Props.position), p2, [c[0], c[1] - step, 0], _inOut);
    // Incoming slide: comes up from below in its mount, then grows to full frame.
    _Ctx.key(b.prop(Props.scale), t0, [bScale[0] * s, bScale[1] * s, bScale[2]], _inOut);
    _Ctx.key(b.prop(Props.scale), p2, [bScale[0] * s, bScale[1] * s, bScale[2]], _inOut);
    _Ctx.key(b.prop(Props.scale), t1, bScale, _inOut);
    final bp = [c[0] + (bPos[0] - c[0]) * s, c[1] + (bPos[1] - c[1]) * s, bPos[2]];
    _Ctx.key(b.prop(Props.position), p1, [bp[0], bp[1] + step, bp[2]], _inOut);
    _Ctx.key(b.prop(Props.position), p2, bp, _inOut);
    _Ctx.key(b.prop(Props.position), t1, bPos, _inOut);
    final mb = mount('mount_b', p1 - fr, t1);
    _Ctx.key(mb.prop(Props.scale), p2, [100 * s, 100 * s, 100], _inOut);
    _Ctx.key(mb.prop(Props.scale), t1, [100, 100, 100], _inOut);
    _Ctx.key(mb.prop(Props.position), p1, [c[0], c[1] + step, 0], _inOut);
    _Ctx.key(mb.prop(Props.position), p2, c, _inOut);
    _Ctx.keys(mb.prop(Props.opacity), [(p2 + (t1 - p2) * 0.4, 100, _inOut), (t1, 0, _inOut)]);
    if (pink > 0) {
      _Ctx.keys(fx(b, 'tint', values: {'color': [236, 150, 170]}).params['amount']!, [(p1, pink, _inOut), (p2, pink, _inOut), (t1, pink * 0.35, _inOut)]);
    }
    for (final l in [a, b]) {
      fx(l, 'motion_blur', values: {'amount': [60]});
    }
  }

  // 54. Exposure in: over-exposed glare settling to normal.
  void exposureIn() {
    hardCut();
    final from = n('from', 3.0).clamp(1.0, 8.0).toDouble();
    final col = colorParam('color', '#FFF1D6');
    final f = ((from - 1) / 2.2).clamp(0.0, 1.0) * 100;
    _Ctx.keys(fx(b, 'flash', values: {'color': col}).params['amount']!, [(cut, f, _outCubic), (t1, 0, _outCubic)]);
    _Ctx.keys(fx(b, 'bloom', values: {'threshold': [35], 'radius': [60]}).params['amount']!, [(cut, 95, _outCubic), (t1, 0, _outCubic)]);
    _Ctx.keys(fx(b, 'color').params['contrast']!, [(cut, -30, _outCubic), (t1, 0, _outCubic)]);
    final rays = overlay('rays', name: 'Sun rays', start: cut, end: t1);
    fx(rays, 'light_rays', values: {'angle': [120], 'amount': [85], 'color': col});
    _Ctx.keys(rays.prop(Props.opacity), [(cut, 100, _outCubic), (t1, 0, _outCubic)]);
    _Ctx.key(b.prop(Props.scale), cut, [bScale[0] * 1.04, bScale[1] * 1.04, bScale[2]], _outCubic);
    _Ctx.key(b.prop(Props.scale), t1, bScale, _outCubic);
  }

  // 43. Punch in: the presenter enters at 150% blurred, snaps to 100%.
  void punchIn() {
    hardCut();
    _Ctx.key(b.prop(Props.scale), cut, [bScale[0] * 1.5, bScale[1] * 1.5, bScale[2]], _expoOut);
    _Ctx.key(b.prop(Props.scale), t1, bScale, _expoOut);
    _Ctx.keys(fx(b, 'blur').params['amount']!..staticValue = [0], [(cut, 40, _expoOut), (t1, 0, _expoOut)]);
    fx(b, 'motion_blur', values: {'amount': [100]});
  }

  // 41. Cut to black (+ silence): hard cut into black, then hard cut out.
  void cutToBlack() {
    hardCut();
    final black = overlay('black', name: 'Black', color: 0xFF000000, start: cut, end: t1);
    _Ctx.keys(black.prop(Props.opacity), [(cut, 100, Easing.hold), (t1 - fr, 100, Easing.hold), (t1, 0, Easing.hold)]);
    if (flag('silence', true)) {
      final ducked = v3DuckAudio(comp, cut, t1, fr, skipPrefix: 'tr_');
      if (ducked > 0) log.add('cut_to_black: $ducked audio track(s) silent from ${cut.toStringAsFixed(2)} to ${t1.toStringAsFixed(2)} s');
    }
  }

  // 40. ink_bleed incoming:"duotone_of_outgoing": the incoming (the same
  // image) is a navy duotone of the outgoing — for turning points.
  void v3InkDuo() {
    if (params['incoming'] != 'duotone_of_outgoing') return;
    fx(b, 'duotone', values: {'dark': [10, 22, 48], 'light': [108, 134, 176], 'amount': [100]});
    if (a.mediaId != null && b.mediaId != null && a.mediaId != b.mediaId) {
      log.add('ink_bleed: incoming "duotone_of_outgoing" expects the same photo on both layers (leave out "to" to split the outgoing)');
    }
  }
}
