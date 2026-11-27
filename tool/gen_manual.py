"""Embed docs/MOTIONAI_MANUAL.md into the app as lib/remote/manual_text.dart (served by the MCP tool get_manual
and the resource motionai://manual). Run from the repo root after editing the manual:

    python tool/gen_manual.py            # writes lib/remote/manual_text.dart
    python tool/gen_manual.py --catalog  # prints Appendix A.1-A.3 (effects, components, transitions) from the
                                         # Dart source, to paste into the manual when the catalogues change

test/manual_test.dart fails when manual_text.dart is out of date.
"""
import re, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
DOC = ROOT / 'docs' / 'MOTIONAI_MANUAL.md'
OUT = ROOT / 'lib' / 'remote' / 'manual_text.dart'
Q3 = "'" * 3


def read(p): return (ROOT / p).read_text(encoding='utf-8')


def catalog():
    out = []
    def read(p): return (ROOT / p).read_text(encoding='utf-8')

    # ---------------- effects
    src = read('lib/core/model/effects_catalog.dart')
    consts = {m.group(1): re.findall(r"'([^']+)'", m.group(2))
              for m in re.finditer(r"const List<String> (\w+) = \[(.*?)\];", src, re.S)}
    body = src[src.index('static const List<EffectDef> all'):]
    effects = []
    for m in re.finditer(r"EffectDef\('(\w+)',\s*'([^']*)',\s*\[(.*?)\]\s*(?:,\s*category:\s*'(\w+)')?\)", body, re.S):
        typ, label, params, cat = m.group(1), m.group(2), m.group(3), m.group(4) or 'stylize'
        ps = []
        for p in re.finditer(r"ParamDef\('(\w+)',\s*'([^']*)',\s*\[([^\]]*)\],\s*([-\d.]+),\s*([-\d.]+)(.*?)\)(?=,|\s*$)", params, re.S):
            key, plabel, dflt, lo, hi, rest = p.groups()
            extra = ''
            o = re.search(r"options:\s*(\w+|const\s*\[[^\]]*\]|\[[^\]]*\])", rest)
            if o:
                v = o.group(1)
                names = consts.get(v) if v in consts else re.findall(r"'([^']+)'", v)
                if names: extra = 'choices: ' + ', '.join(names)
            if 'color: true' in rest: extra = 'colour (R,G,B) or "#RRGGBB"'
            ps.append(f"`{key}` ({plabel}; default {dflt.strip()}; {lo}..{hi}{'; ' + extra if extra else ''})")
        effects.append((cat, typ, label, ps))
    out.append(f"### A.1 Effects ({len(effects)}) — `add_effect {{layer, effect, id?, params?}}`\n")
    out.append("Every effect, its category and every parameter with default and range (extracted from `lib/core/model/effects_catalog.dart`). "
               "Choice parameters accept the name (e.g. `kind: \"snow\"`). Animate any parameter with `set_effect_param {..., time}` "
               "or `set_keyframe {target, effect, prop: <param>, time, value}`.\n")
    out.append("| Effect id | Label | Category | Parameters |\n|---|---|---|---|")
    for cat, typ, label, ps in effects:
        out.append(f"| `{typ}` | {label} | {cat} | {'<br>'.join(ps) if ps else '—'} |")
    out.append('')

    # ---------------- components
    csrc = read('lib/core/presets/components.dart')
    m = re.search(r"static const types = \[(.*?)\];", csrc, re.S)
    types = re.findall(r"'(\w+)'", m.group(1)) if m else []
    labels = dict(re.findall(r"'(\w+)':\s*'([^']+)'", csrc[csrc.index('static String label'):]))
    for f, tv, lv in [('map_kit.dart', '_sceneTypes', '_sceneLabels'), ('components_evidence.dart', '_evTypes', '_evLabels'),
                      ('map_geo.dart', '_geoTypes', '_geoLabels'), ('components_datahud.dart', '_dataHudTypes', '_dataHudLabels')]:
        fs = read('lib/core/presets/' + f)
        mt = re.search(tv + r" = \[(.*?)\];", fs, re.S); types += re.findall(r"'(\w+)'", mt.group(1))
        ml = re.search(lv + r" = \{(.*?)\};", fs, re.S)
        if ml: labels.update(dict(re.findall(r"'(\w+)':\s*'([^']+)'", ml.group(1))))
    out.append(f"### A.2 Components ({len(types)}) — `add_component {{type, id?, start?, duration?, ...fields}}`\n")
    out.append("Every component type (from `Components.types`). Fields for each are in the component chapter and in `get_command_spec`. "
               "A component is a group: null layer `<id>_g` plus children `<id>_<part>`; move/scale/fade the group.\n")
    out.append("| Type | Label |\n|---|---|")
    for t in types: out.append(f"| `{t}` | {labels.get(t, '')} |")
    out.append('')

    # ---------------- transitions
    trans = []
    for f in ['lib/core/presets/doc_transitions.dart', 'lib/core/presets/doc_transitions_v3.dart']:
        fs = read(f)
        for m in re.finditer(r"TransitionDef\('(\w+)',\s*'([^']*)',\s*((?:'(?:[^'\\]|\\.)*'\s*)+)(.*?)(?=TransitionDef\(|\];)", fs, re.S):
            best = ''.join(re.findall(r"'((?:[^'\\]|\\.)*)'", m.group(3))).replace("\\'", "'")
            rest = m.group(4)
            dur = re.search(r"duration:\s*([\d.]+)", rest); snd = re.search(r"sounds:\s*\[([^\]]*)\]", rest)
            prm = re.findall(r"TransitionParam\('(\w+)'", rest)
            trans.append((m.group(1), m.group(2), best, dur.group(1) if dur else '', ', '.join(re.findall(r"'(\w+)'", snd.group(1))) if snd else '', prm))
    out.append(f"### A.3 Transitions ({len(trans)}) — `transition {{from, to, type, duration?, at?, sound?, params?}}`\n")
    out.append("From `DocTransitions.catalog` (doc_transitions.dart + doc_transitions_v3.dart). Shared params: direction (left|right|up|down), "
               "tone (warm|cold|neutral), target (layer), point [x,y], size [w,h], cx/cy (% of frame). `list_transitions {}` prints the live catalog.\n")
    out.append("| Type | Label | Best for | Default s | Sound | Own params |\n|---|---|---|---|---|---|")
    for t in trans: out.append(f"| `{t[0]}` | {t[1]} | {t[2]} | {t[3]} | {t[4]} | {', '.join(t[5])} |")
    out.append('')
    return '\n'.join(out)


def embed():
    text = DOC.read_text(encoding='utf-8').replace('\r\n', '\n')
    if Q3 in text:
        sys.exit('The manual must not contain three single quotes in a row (it is embedded as a Dart raw string).')
    dart = ('// GENERATED by tool/gen_manual.py from docs/MOTIONAI_MANUAL.md - do not edit by hand.\n\n'
            '/// The complete MotionAI control manual for Claude (get_manual / motionai://manual).\n'
            'const String kManual = r' + Q3 + text + Q3 + ';\n')
    OUT.write_text(dart, encoding='utf-8', newline='\n')
    print(f'wrote {OUT.relative_to(ROOT)} ({len(text)} characters)')


if __name__ == '__main__':
    if '--catalog' in sys.argv:
        print(catalog())
    else:
        embed()
