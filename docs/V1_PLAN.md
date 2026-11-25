# MotionAI V1 — Windows app + reference pack (build plan)

Owner: Mohit (Mohitflix, Hindi/Hinglish documentary YouTube channel). The app is
Flutter. The phone (Android) app already works; V1 adds a Windows desktop app
and every feature below. **Reuse existing code wherever possible** — the core
engine (`lib/core`), AI (`lib/ai`), Director (`lib/director`) and most UI are
platform-neutral already.

There is NO local Flutter SDK in the dev container. GitHub Actions is the
compiler: push your branch → `.github/workflows/check.yml` runs
`flutter analyze --no-fatal-infos` + `flutter test` (ubuntu). Poll it with
`unset GH_TOKEN; curl -s https://api.github.com/repos/mohitbansaldev/motionai/actions/runs?branch=<branch>`
and read job logs at `.../actions/jobs/<id>/logs`. Never push to `main`
(main releases the phone APK). Push only your own branch.

Flutter stable (3.38+/Dart 3.10). Known pitfalls: `import 'package:flutter/material.dart' hide Easing;`
where `core/model/easing.dart` is used; `show RenderRepaintBoundary` from rendering;
`double.clamp` returns num in some contexts — use `.toDouble()`; `math.max` with int
literals; keyframes closer than 1 ms merge (`kTimeEpsilon`). Layer list index 0 = TOP/front.

## Ownership (to avoid merge conflicts)

| Agent | Branch | Owns (may edit freely) |
|---|---|---|
| A — Windows platform & PC UI | `feat/windows` | `.github/workflows/build-windows.yml` (new), `lib/services/*` (media_bridge → platform layer, speech, updater, media_importer, project_storage), new `lib/platform/**`, `windows/**`, `lib/ui/editor_screen.dart`, `lib/ui/home_screen.dart`, `lib/ui/theme.dart`, `lib/ui/timeline/**`, `lib/ui/export_screen.dart`, `lib/state/video_pool.dart`, `lib/main.dart`, `pubspec.yaml` (coordinate: append deps only) |
| B — Render engine & motion FX | `feat/fx` | `lib/ui/preview/**` (layer_view, composition_canvas, shape_painter, new `fx/` folder), `lib/core/model/layer.dart`, `lib/core/model/effects_catalog.dart`, `lib/core/engine/evaluator.dart`, `lib/core/presets/motion_presets.dart`, `lib/ui/panels/effects_panel.dart`, `lib/ui/panels/layer_panel.dart` |
| C — Doc kit, articles, maps, 3D scenes, AI wiring | `feat/dockit` | `lib/core/presets/components.dart`, `world_map.dart`, `camera_presets.dart`, `templates.dart`, new `lib/core/presets/*`, `lib/core/commands/edit_commands.dart`, `lib/ai/command_spec.dart`, `lib/director/**`, `lib/ui/doc_kit_sheet.dart`, `lib/ui/panels/add_panel.dart`, `lib/ui/panels/camera_panel.dart`, `assets/**` |

Each agent adds its own tests in a NEW test file (`test/windows_test.dart`,
`test/fx_test.dart`, `test/dockit_test.dart`). Small, append-only edits to a
file you don't own are allowed when unavoidable — keep them minimal.

## Contract between B and C (names are fixed — build to these)

B implements in the renderer/engine; C uses them from components/commands/AI
by these exact names. Effects are `{'op':'add_effect','layer':id,'effect':NAME,'params':{...}}`.

Effects (B):
- `silhouette` {color '#FFC107', glow 0-100} — fill a cut-out with one solid colour (+ glow)
- `mono` {amount 0-100} — black & white
- `duotone` {dark '#000000', light '#FF2020', amount}
- `edge_blur` {amount} — blurry soft edges + vignette (tilt-shift look)
- `curve` {bend -100..100} — bulge/curve the layer like a curved screen/board (mesh warp)
- `glass_frame` {thickness, gloss 0-100} — glossy bevelled glass border + highlight
- `torn_edge` {side 'top'|'bottom'|'left'|'right', amount} — torn paper edge
- `particles` {kind 'confetti'|'leaves'|'stars'|'rain'|'snow'|'smoke'|'dust'|'bokeh'|'streaks'|'birds'|'clouds', amount, speed, color, direction} — fills the layer box; animate with time
- `light_rays` {angle, amount, color}
- `sway` {amount, speed} — wind sway (bottom pinned) for grass/plants
- `reveal` {kind 'iris'|'ink'|'smoke'|'wipe', progress 0-100, softness, cx, cy} — animated procedural mask (keyframe `progress`)
- `motion_blur` {amount} — directional blur from the layer's on-screen velocity (also used by the camera)
Text (B), in TextData: `animator` gains `random_pop` (letters pop in random order) and `scramble` (letters cycle random glyphs then settle, left→right); new `extrude` {depth px, color} thick 3D text edge; existing outline+glow = neon.
Track matte (B): `Layer.matte` = {'layer': id, 'mode': 'alpha'|'inverse'} — the layer is shown only inside (or outside) the matte layer's pixels; matte layer itself is hidden. Command: `update_layer` with `'matte': {...}`.
Motion path (B): `Layer.path` = {'points': [[x,y],...], 'smooth': true, 'orient': bool} plus animatable prop `path_progress` (0-100). When a layer has a path, its position follows the path at `path_progress` (offset by position). Command: `update_layer` with `'path': {...}`; keyframe `path_progress`.
Transitions (B), usable in `animate_in`/`animate_out` presets: `iris`, `ink`, `smoke`, `spin`, `flash`, `glitch_flash` (plus existing ones). `foreground_wipe` is a C component (needs an image).
Camera motion blur (B): comp setting `motionBlur` (bool) → evaluator gives each item a screen velocity; LayerView applies directional blur when fast.

## Feature list for V1 (what must exist at the end)

1. **Windows app (A)**: PC layout (big preview, full timeline, side panels), mouse/keyboard (Space, J/K/L, Ctrl+Z/Y, S split, Ctrl+D duplicate, Delete, arrows nudge, +/- timeline zoom, right-click menus), open files from any folder, FFmpeg export with GPU encoder (h264_nvenc / h264_qsv / h264_amf, fallback libx264), 1080p/4K, any fps, Windows video preview, projects compatible with phone, auto-save, installer `MotionAI-Setup.exe` + portable zip built in CI and published as GitHub release tagged `win-N` (must NOT be marked latest — the Android in-app updater reads releases/latest), Windows in-app updater reading the newest `win-*` release. Platform layer so Android keeps working unchanged. Speech-to-text on Windows (whisper.cpp), voice-over with Windows voices, photo cut-out (on-device ONNX model, e.g. u2netp/isnet via onnxruntime), object erase (port the Kotlin inpaint to Dart isolate), image normalisation.
2. **Core editor**: everything already there (layers, keyframes, graph editor, 2D/3D camera, masks, effects, looks, undo).
3. **Effects/looks (B)**: list above.
4. **Text (B + C)**: random letter pop, scramble/decode, neon outline, 3D extrude, rolling number tiles (C component `number_tiles`), big serif date/year titles with shooting-star streak (C component `date_title`).
5. **Doc kit (C)**: `name_tag` (name + yellow highlight bar on role), `character_label` (black/red tag pinned to a point), `arrow_callout` (curved arrow to a glowing circle), `censor_bar` (glowing bar over eyes), `plaque` (gravestone/plaque with text), `poster` (vintage poster collage), improved `timeline` year ruler (slides, stops on red marker), `glass_screen` (curved glass screen showcase on carbon backdrop), `title_slam` (viral 3D intro: bokeh, streaks, random-pop title, zigzag dotted line, flashes, impact sound → silence → drop), `foreground_wipe` (an image sweeps past the camera), `icon_stream` (icons flow along a curved path from A to B), `icon_badge` (app-style rounded-square / circle icon), `scanner` (cone beam from a logo swings between targets; targets visible only inside the beam), `silhouette_crowd` (cut-outs filled solid glowing colour rising in a stagger).
6. **Articles (C)**: `article` component: screenshot on paper (torn edge, tilt, starry/colour backdrop), auto-scroll down long screenshots, highlighter sweep / hand-drawn circle / underline on phrase boxes, redaction bars with scramble-to-word, articles changing continuously, "Coming up next" tag. **Phrase finder**: give a phrase → AI vision returns its box in the screenshot (normalised coords) → highlight.
7. **Maps (C)**: needle pin, fly between countries (camera pan/zoom across the map), route follow (camera follows the line tip with motion blur, avatar travels), avatar pin (round face photo), clouds drifting over the map, road-map paper style.
8. **Paths & motion graphics**: move along a curve (B engine), icon stream (C), scanner beam + reveal inside shape (B matte + C component).
9. **3D scenes — "compose flat, play deep" (C)**: `make_3d` command: give each layer a depth band (sky/far/mid/near/front; auto-guess from type, size, vertical position) and convert to 3D while the first frame looks identical (scale compensation, like `parallax_rig`). Camera moves aimed by a target layer or point: `drift`, `fly_to`, `push_through` (into a door/window → cut/blur into next shot), `pass_by`, `reveal` (from behind a near object), `pull_back` (from extreme close-up), `orbit`. Room builder (`room` component: floor + walls from textures, cut-outs inside). Curved panels/boards (`board` component using `curve` effect; picture pops out). `save_shot` = reuse arrangement.
10. **Transitions (B)**: iris, ink bleed, smoke dissolve, spin, rapid flash inserts, white flash on drop; (C) foreground wipe, through-the-door.
11. **Atmosphere (B effects, C toggles)**: confetti, leaves, stars, dust, rain, smoke, fire glow, light rays, wind sway, birds, clouds, bokeh, gold streaks.
12. **Sound**: auto SFX (exists: `lib/director/sfx.dart`), ducking, drop-silence for intros (C in title_slam).
13. **AI (C)**: every new op/component/effect documented in `lib/ai/command_spec.dart`; Director prompt (`lib/director/director.dart`) knows the new visuals (name_tag, character_label, article+phrase, needle pin map fly, icon_stream, scanner, silhouette_crowd, make_3d + camera moves, foreground_wipe, glass_screen, title_slam).
14. **Library & reuse (A UI, C data)**: asset library across projects (tagged), recipes (saved combination of move+transition+atmosphere+look+frame) — C defines data + commands, A shows UI if time permits.

Out of scope: cutting people out of moving video; full 3D models.

## Reference notes
- `docs/REFERENCE_STYLE.md` — earlier reference analysis (doc-kit style).
- Village fly-through reference: many flat cut-out assets (sky, houses reused at different depths, grass strips hiding house bases, reed plant very near camera, birds), 3D camera: low drift right + forward → fly to hero hut → fast push into door with motion blur → 0.4 s interior insert → loop.
- Viral 3D intro: maroon gradient + bokeh + diagonal gold streaks; "VIRAL 3D" white condensed with grey 3D edge; "ANIMATION" yellow glow, letters pop in random order in ~0.6 s; dotted white zigzag line draws under; white flash at 0; impact hit at 0 decaying to silence by 2.4 s; red light-leak sweep, white flash, music drop at 2.6 s; then curved glossy glass screen on carbon grid with orange light-leak sweeps every 1–2 s hiding cuts.
- Reference pack (10 clips): Louis Vuitton recreation (rolling number tiles "200 Y" + gold "AGO" bounce on old map; object wipe; outlined title in sky behind a house cut-out; character rises from bottom + name tag with yellow highlight; tree/cloud foreground wipes; date title + script name with red bar + curved arrow to glowing circle; "Poor Farmer" big gold word; objects falling in (hats); smoke dissolve; shooting streak into big serif "1831"; gravestone; silhouettes with red labels + confetti; labels on characters; year ruler sliding to red "1835"; fire flash into cabin with falling leaves; vintage job poster collage; road map with needle pin drop + curved route to Paris + clouds over map), silhouette crowd (yellow-filled people rising, police cut-out in colour with glowing eye bar, glowing labels typing), 3D room (floor/walls/railing planes, man on chair, camera tilt, curved wooden board with flag + "1996" coin, photo pops out + confetti, spin transition, B&W with one teal object, red ink bleed reveal), article highlight (torn paper, tilt, purple starry bg, slow pan down, yellow highlighter sweep, red hand-drawn circle), icon drift (flag app icons, round item icons streaming along an arc), scanner (round profile + red name tag, iris zoom, logo circle, cone beam swings revealing grayscale faces with red labels), presenter on map (presenter photo cut-out on white spotlight disc, pull back, map slides in, needle pin, highlighted countries, pan India→USA), text behind subject (pull back from close-up, huge glowing yellow word behind person, white glowing outline words in front breaking out of the frame, rapid flash inserts), map route follow (avatar pin, line draws west, camera follows tip with motion blur), article scramble (redaction bars with scrambling letters settling to the word, curved paper, edge blur, continuous article changes, "Coming up next").
