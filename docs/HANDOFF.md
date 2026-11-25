# MotionAI — Complete Handoff for the Next Chat

> **How to use this:** paste this whole document into the new chat (or attach it) and say
> "Continue the MotionAI project from this handoff." The same file is saved in the repo at
> `docs/HANDOFF.md` on branch `integ/v1`.
>
> Written: 25 Nov 2026, ~10:25 IST.

---

## 0. Instructions for Claude (read first)

You are continuing a long project with **Mohit**: building **MotionAI**, his own AI motion-graphics video editor (Alight Motion / After Effects–style) for his Hindi/Hinglish documentary YouTube channel **Mohitflix**. The previous chat built a phone app, then a full **Windows desktop app** with a large V1 feature set using up to 17 parallel helper agents. Everything is merged on the GitHub branch **`integ/v1`**.

Working rules that have held all along:
- **Mohit's preferences**
  - Don't take control of his PC screen. No computer use on File Explorer or terminals. Do the work in the background: GitHub, file access via the device bridge, the built-in browser.
  - He writes short messages, often in Hinglish or with typos. Reply in simple English, with clear status and percentages when he asks "how much left".
  - He wants speed and "continue" momentum. He likes parallel helper agents, but **when he interrupts a tool call, running helpers get stopped**. Mention that if it happens, and restart only what he asks for.
  - He has a **Claude Max** plan. ChatGPT Plus is connected in the app through "Sign in with ChatGPT".
- **There is no Flutter SDK in the cloud container.** GitHub Actions is the compiler: push a branch → CI runs analyze + tests (+ Windows build). Poll CI with
  `unset GH_TOKEN; curl -s "https://api.github.com/repos/mohitbansaldev/motionai/actions/runs?branch=<branch>&per_page=5"`.
  Read job logs with `curl -sL https://api.github.com/repos/mohitbansaldev/motionai/actions/jobs/<job_id>/logs`. The container proxy injects GitHub auth, so `unset GH_TOKEN` before curl or gh. The Actions secrets API is blocked through the proxy.
- **Never push to `main` casually.** A push to main runs "Build APK", which publishes a phone release `build-N` marked *latest*, and the phone's in-app updater picks it up. Mohit asked to pause phone updates during V1 work. If a main push happens by accident, cancel the run: `curl -X POST .../actions/runs/<id>/cancel`.
- **Windows builds**: `.github/workflows/build-windows.yml` runs on pushes to `main`, `feat/windows` and `integ/v1`. It publishes a GitHub release **`win-N`** with `make_latest: false`, so the Android updater ignores it.
- **Wait for the running Windows build to finish before pushing integ/v1 again.** A new push cancels the in-progress run.
- **Security constraints**
  - The **Android signing keystore** lives only on Mohit's PC (`Documents\MotionAI\signing\`) and in the repo secret `SIGNING_KEYSTORE_B64`. Never commit it. `.gitignore` covers `signing/`, `*.keystore`, `*.jks`, `key.properties` and `*.env`.
  - API keys stay in encrypted device storage (`flutter_secure_storage`).
  - No unofficial ChatGPT or Claude subscription hacks. Claude subscription OAuth is not allowed for third-party apps.
  - Reference clips are for learning techniques only. Never reuse the creators' footage, logos or designs.
- **Smart App Control:** Mohit originally refused to lower Windows security. He then agreed to turn Smart App Control off, after Windows Update, so he could install the unsigned Windows app. He installed win-4 and confirmed it works ("ITS WORK NOW"). Later options for signed distribution: a private Microsoft Store listing (free individual developer account) or Microsoft Artifact Signing (~$10/month).

---

## 1. Project facts

| Item | Value |
|---|---|
| Repo | https://github.com/mohitbansaldev/motionai (public, MIT, owner `mohitbansaldev`) |
| Active branch | **`integ/v1`** — everything V1 is here (~100 commits ahead of `main`) |
| `main` | `a4e9c98` (phone app + docs). The latest phone release is **build-23** (Director mode etc.) |
| Phone app | Android, package `com.mohitflix.motionai`, permanent signing via `SIGNING_KEYSTORE_B64` secret, in-app updater reads GitHub `releases/latest` |
| Windows app | Releases `win-N` with `MotionAI-Setup.exe` (Inno Setup, no admin) + `MotionAI-Windows-portable.zip` |
| Latest Windows release confirmed | **win-23** (commit `0d0031e`: everything except Claude control). https://github.com/mohitbansaldev/motionai/releases/download/win-23/MotionAI-Setup.exe |
| Final build | Commit **`ed59107`** (adds Claude control/MCP) was building when this was written. Its release will be the next `win-N` (likely win-24). Check releases and give Mohit the link. |
| Mohit's PC folders | `C:\YT\Tools\Ref\clips` (first references), `C:\YT\Tools\Ref\7 and 8 - All clips\To be design` (10 reference clips: 1,3–11.mp4), `Documents\MotionAI` (old local copy + `signing\` + `docs\REFERENCE_STYLE.md`) |
| Flutter/Dart | Flutter stable 3.50.x in CI (`subosito/flutter-action` stable), Dart ≥3.10. pubspec `version: 0.5.0+5` |

**Local worktrees** from the old container (`/home/claude/wt-*`) are gone in a new chat. Start with:
`git clone https://github.com/mohitbansaldev/motionai.git && cd motionai && git checkout integ/v1`.

---

## 2. History (what happened, in order)

1. **V1 phone app (Android, Flutter).**
   - Core editor: layers, keyframes with bezier easing, 2D/3D camera, effects, masks, undo.
   - JSON edit-command layer for the AI agent.
   - GitHub Actions APK builds.
   - Permanent signing key; in-app updates.
2. **V2/V3.**
   - "Sign in with ChatGPT" bridge: OpenAI open-source dynamic agent client flow on a loopback port, with model-list parsing.
   - Premium UI, landscape layout, graph editor.
   - Captions, Script → Video, export with audio mix.
   - Fixes: images not visible (a Stack needed `fit: StackFit.expand`); ChatGPT model selection.
3. **Doc kit and Alight Motion parity** from Mohit's reference clips: shapes, source cards, maps (Natural Earth data), AI cut-out/erase (ML Kit plus Kotlin inpaint), in-app updater.
4. **Director mode** (build-23): AI media labelling, on-phone Whisper (`whisper_ggml`), phone TTS voice-over, storyboard → build, SFX, music ducking, frame review.
5. **3D lag on phone.** A fix was written (draft preview, cached layers, near-plane cull) and later merged into integ/v1.
6. **Decision to build the Windows desktop app.**
   - Browser vs native comparison; native chosen for performance.
   - Smart App Control discussion (see above).
7. **Reference analysis.**
   - "Viral 3D intro + glass screen": title slam, random-letter pop, curved glass screen on carbon.
   - "Village fly-through": many flat cut-out assets at depths, a 3D camera fly to a hut, push through the door.
   - Design principle agreed: **"compose flat, play deep"**. Arrange the shot like a 2D collage, press *Make 3D*, then use camera moves aimed with one tap. Don't save whole scenes as templates; use reusable pieces (assets, sets, camera moves, transitions, atmosphere, look/frame) and *recipes*.
   - **10-clip reference pack** analysed: Louis Vuitton documentary recreation, silhouette crowd, 3D room, article highlight, icon drift, scanner, presenter on map, text behind subject, map route follow, article scramble. Mohit chose **not** to cut people out of moving video (no video matting).
8. **V1 Windows build with parallel agents** (all merged into `integ/v1`; details in §4):
   - Agents: A Windows platform (finished by the lead), B FX engine, C doc kit + AI wiring, D2 3D scenes + maps, E2 Windows AI, F QA, G library/templates, H Director v2, I fonts, J captions, K sound, L precomps, M green screen, N bulk select, O 3D performance, P Claude control (MCP).
   - The first Windows installer (win-4) was confirmed working by Mohit. Releases since then: win-6 → win-8 → win-18 → win-22 → win-23 → final (ed59107).

---

## 3. Architecture overview

- **Pure-Dart core** (`lib/core`)
  - `model/`: AnimProp, Keyframe, Easing; Layer and Props; Project/Composition/MediaAsset, plus `comps` (precomps), `recipes` and `shots`; camera; effects_catalog; motion_path.
  - `engine/`: evaluator (3D projection, depth sort, parenting, DOF, velocity), precomp (nested comps, cache, time remap), chroma, fx_math.
  - `commands/`: `edit_commands.dart` is the JSON command dispatcher. Ops include add/update/remove layer, keyframes, effects, masks, camera, batch, components, templates and more. Feature hooks live in clearly marked blocks: `// FX (Agent B)`, `PRECOMP (Agent L)`, `SCENE (Agent D)`, `BULK (Agent N)`, `Sound (Agent K)`, `FONTS (Agent I)`, `CHROMA (Agent M)`, `MCP (Agent P)`, `PERF`. The other command files are `fx_commands`, `precomp_commands` and `bulk_commands`.
  - `presets/`: `components.dart` (+ parts `components_doc.dart`, `components_article.dart`, `map_kit.dart`), `scene3d.dart`, `camera_presets.dart`, `motion_presets.dart` (transitions/styles), `templates.dart` (`ProjectTemplate` and `SceneTemplates` gallery), `world_map.dart`.
- **AI** (`lib/ai`)
  - `ai_settings`: providers chatgpt/openai/anthropic, `speechEngine`, `whisperModel`, `styleNotes`.
  - `ai_client`, `chatgpt_auth`, `agent.dart` (EditAgent, project summary incl. selection and comps).
  - `command_spec.dart` is the big system prompt documenting every op, component and effect. **Keep it accurate.**
  - `phrase_finder.dart` (vision boxes for article highlights).
- **Director** (`lib/director`): `director.dart`, `story_builder.dart`, `sfx.dart` (28 synthesized SFX kinds), and the v2 files `chapters.dart`, `planner.dart`, `pacing.dart`, `variety.dart`, `capabilities.dart` (gating on available ops), `json_repair.dart`, `storyboard.dart`.
- **Feature libraries**
  - `lib/audio` (WAV I/O, music analysis, beat sync, auto mix, sound commands)
  - `lib/captions` (styles, grouping, emphasis, placement, SRT/VTT)
  - `lib/fonts` (catalog, text styles, font commands)
  - `lib/library` (asset library, tagging, Director integration)
  - `lib/remote` (MCP server and tools)
- **Platform**
  - `lib/services/media_bridge.dart` routes to Kotlin MethodChannel `motionai/media` on Android, or to `lib/platform/win_media.dart` (FFmpeg processes) on Windows.
  - `lib/platform/windows_ai/` (E2): u2netp ONNX cut-out via `ort_ffi.dart`, Dart inpaint, image normalisation, PowerShell TTS (System.Speech + OneCore), and whisper-cli speech-to-text.
  - A's older interim files in `lib/platform/` (`image_ops`, `onnx_ffi`, `whisper_cli`, `win_cutout`, `win_tts`) are now unused by WinAi but still tested in `test/windows_test.dart`. Cleanup candidate.
- **State and UI**
  - `lib/state/editor_controller.dart`: multi-selection, open comp, undo, playback, `panelTime` (quiet while playing).
  - `lib/state/video_pool.dart`.
  - `lib/ui`: editor_screen (PC layout, shortcuts, context menus, ⋮ menu with Director/Templates/Library/Sound), home_screen, preview (composition_view/canvas, layer_view, fx/, precomp_view, preview_quality), timeline, panels, bulk, library, fonts, audio, director_screen, export_screen, captions_sheet, doc_kit_sheet.
- **Android native**: `android/app/src/main/kotlin/com/mohitflix/motionai/MediaBridge.kt`.
  - FrameReader and VideoEncoder.
  - AudioMixer with per-clip `envelope` volume automation.
  - `wav16k`, cutout (ML Kit), inpaint, normalizeImage, `tts` (phone TextToSpeech), save/share.
- **CI**
  - `build-apk.yml`: main only. Releases `build-N` as latest. Installs NDK 29 for whisper_ggml; sets minSdk 24.
  - `check.yml`: branch pushes except main; analyze + test.
  - `build-windows.yml`: Windows build, bundles FFmpeg, whisper.cpp `b5454`, onnxruntime DLLs (from the PyPI wheel 1.22.0), VC++ runtime and `motionai-mcp.exe` (dart compile exe); then Inno Setup installer and `win-N` release.
- **Tests**: ~480 tests across 20 files. All pass on integ/v1; one chroma widget test is skipped on Windows runners.

---

## 4. V1 feature inventory (all on `integ/v1`)

**Windows app (A + lead)**
- Desktop layout: big preview, full timeline, side panels.
- Shortcuts: Space, J/K/L, Ctrl+Z/Y, S split, Ctrl+D, Delete, arrows, +/−, Home/End, F1 help.
- Right-click menus, drag and drop from Explorer.
- FFmpeg export with GPU encoders (nvenc/qsv/amf, else x264), 1080p/1440p/4K, output folder.
- Windows video preview (`video_player_win`), Windows updater (`win-*` releases), window title.

**Effects engine (B)**
- Effects: `silhouette`, `mono`, `duotone`, `edge_blur`, `curve` (mesh warp), `glass_frame`, `torn_edge`, `particles` (confetti, leaves, stars, rain, snow, smoke, dust, bokeh, streaks, birds, clouds), `light_rays`, `sway`, `reveal` (iris/ink/smoke/wipe), `motion_blur`, `flash`, `glitch`.
- Text animators `random_pop` and `scramble`; `extrude` (3D text).
- Track matte `Layer.matte` {layer, mode alpha|inverse}.
- Motion paths `Layer.path` + `path_progress`.
- Transitions iris/ink/smoke/flash/glitch_flash.
- Comp `motionBlur` (`set_comp motion_blur`).
- Colours accept "#RRGGBB"/"green"/"blue".

**Doc kit (C, fixed by F)**
- Components: `name_tag`, `character_label`, `arrow_callout`, `censor_bar`, `plaque`, `poster`, year-ruler `timeline`, `glass_screen`, `title_slam` (bokeh, streaks, impact SFX → silence → music drop), `foreground_wipe`, `icon_badge`, `icon_stream` (along a path), `scanner` (beam + matte reveal), `silhouette_crowd`, `number_tiles`, `date_title`, `article` (torn paper, scroll, highlight/circle/underline/redact marks with scramble, coming-up tag).
- AI phrase finder for articles.

**3D scenes and maps (D2)**
- `make_3d` {layers?, bands?, start?}: "compose flat, play deep"; the first frame stays identical.
- `camera_shot` {move: drift|fly_to|push_through|pass_by|reveal|pull_back|orbit, target|point, start, duration, intensity, cut_to}: near-plane clamp and edge fill.
- `save_shot`/`load_shot`, `save_recipe`/`apply_recipe`/`delete_recipe`.
- Components `room`, `board` (curved panel, pop-out).
- Maps: `needle_pin`, `avatar_pin`, `map_fly`, `route_follow`; map `style: 'road'`; `clouds: true`.
- Camera panel "3D scene" section.

**Fonts (I)**
- 23 OFL/Apache families (9.3 MB) incl. Anton, Bebas Neue, Oswald, Teko, Playfair, Great Vibes, Special Elite and Hindi fonts (Noto Sans Devanagari, Hind, Mukta, Baloo 2, Rozha One, Yatra One, Kalam).
- Automatic Devanagari fallback, `font:` and `text_style:` presets, FontPicker.

**Captions (J)**
- 11 styles: karaoke, word pop, yellow keyword, boxed, neon, MrBeast punch, typewriter, minimal, Hinglish, Devanagari, decode.
- Smart line breaks (Hindi particles, numbers, names), automatic and AI key words, safe areas (avoid name tags, Shorts UI).
- Per-word edit/retime, SRT/VTT import and export.

**Library and templates (G)**
- Asset library across projects: dedupe, alpha detection, AI tags, kits, search.
- Director can use library assets as `lib:<id>`.
- Template gallery: 27 built-ins in 8 categories, incl. Viral 3D Intro, Article reveal, Silhouette crowd, Scanner, Icon flow, Name tag intro, Year ruler, 200 years ago tiles, Village fly-through, Map journey, Map fly.
- Save as template (right-click a layer).
- Recipes panel.

**Precomps (L)**
- Nested comps: `precompose`, `unprecompose`, `add_comp`, `open_comp`, `in_comp`; comp layers with time remap/loop.
- Breadcrumbs, double-click to open.

**Sound (K)**
- 28 SFX kinds incl. braam, sub_drop, glitch, typewriter, pin_drop, heartbeat, and loopable beds (rain/wind/fire/crowd/clock/room/night).
- Music analysis: tempo, beats, drop, sections.
- Ops `add_sfx`, `beat_sync` (cuts/pops/drop), `auto_mix` (loudness targets, ducking).
- Sound sheet (⋮ → "Sound FX, beats & mix").
- Platform TODO: on Windows set `PcmSources.platform` (ffmpeg → mono PCM) so non-WAV music can be analysed. Android already works via `wav16k`.

**Director v2 (H)**
- Chapter planning (hook/context/conflict/turning point/ending), pacing rules.
- Variety scoring and repair, capability gating.
- JSON repair, cancel/resume, rebuild a single chapter.
- Mood atmosphere, per-chapter review.

**Bulk (N)**
- Multi-selection (Ctrl/Shift click, Ctrl+A, rubber band, phone long-press).
- Bulk ops for everything, each one undo step: align/distribute, stagger, transform together, make 3D (toggle or "keep look" via make_3d), group (Ctrl+G), precompose (Ctrl+Shift+C), copy/paste layers/effects/animation.
- Ops `for_layers`, `select`, `align`, `distribute`, `align_time`, `shift_time`, `transform_layers`, `offset_property`, `parent_layers`, `group_layers`, `paste_layers`, `paste_effects`, `paste_animation`.

**Green screen (M)**
- `chroma_key` effect via GPU fragment shader `shaders/chroma_key.frag` with CPU fallback.
- Params color/tolerance/softness/spill/choke/contrast/view.
- Auto-detect, eyedropper, view matte.
- Live video keyed via decoded frames: exact when paused, ~640 px while playing.

**Windows AI (E2)**
- u2netp cut-out via ONNX Runtime FFI; models download once and are hash-checked.
- Dart inpaint/erase.
- Hindi/English Windows TTS (the Hindi voice pack must be installed).
- whisper.cpp speech-to-text (ggml base default; tiny/small optional).

**3D performance (O + lead)**
- Per-layer content memoization (LayerSig fingerprints) and cached raster images under a moving 3D camera.
- Baked DOF blur; projected-size image decoding; no velocity pass while playing.
- Preview Quality chip (Auto/Full/Half/Quarter) and FPS meter (Ctrl+Shift+F).
- Panels quiet while playing.

**Claude control (P)**
- MCP server inside the app: 127.0.0.1:7820, bearer token, off by default.
- Stdio bridge `motionai-mcp.exe`. "Add to Claude Desktop" button merges the config into `%APPDATA%\Claude\claude_desktop_config.json`.
- 32 tools: get_state, run_commands, render_frame (PNG), import_media, export_video, director_run, apply_template, library_search, select, undo/redo, projects…
- Docs in `docs/CLAUDE_CONTROL.md`.

---

## 5. Known risks / not yet verified on a real device

1. **3D performance.** Fixes were measured only by layer counts in CI (no GPU). Ask Mohit to test with the FPS meter. If scrubbing with depth of field gets slow, set `RenderLayerRaster.maxReblursPerFrame = 0`.
2. **Video under curve/sway effects** in the live preview uses a strip-warp approximation.
3. **Green screen live video plays at reduced resolution.** It is CPU-heavy on Android. GLES orientation risk on old phones.
4. **Windows AI.** u2netp quality on hair is weak; it can be upgraded to `silueta` (44 MB, drop-in) or isnet. Hindi TTS needs the voice pack. Models download from GitHub/Hugging Face on first use.
5. **Claude control.** Offscreen render/export/Director via MCP are untested on a real desktop; they fail if the window is minimised. The Microsoft Store Claude config path is a guess.
6. **Sound.** Windows `PcmSource` isn't implemented, so beat analysis of mp3/m4a on Windows is pending. `bedForMood` substring false positives.
7. **Precomps.** Some features may still read `project.main` instead of `project.editComp`.
8. **Captions.** In some styles key-word colour falls back to a scale pulse (renderer limitation).
9. **Blend modes** are stored but not rendered.
10. **Phone app** hasn't received any V1 features yet. Merging `integ/v1` → `main` would trigger a phone release; test on the phone first. The Android build of new parts (shaders, ONNX not used on Android, fonts +9 MB) hasn't been run since the merges.
11. **Cleanup candidates.** A's unused interim Windows files (+ their tests). The `media_bridge.dart` comment calls cutout "ML Kit". Temporary CI branch triggers were removed by the agents.

---

## 6. Next steps (suggested order)

1. Check the final Windows build for commit `ed59107` (Actions → "Build Windows" on `integ/v1`). Give Mohit the newest `win-N` `MotionAI-Setup.exe` link. If it failed, read the log and fix.
2. Get Mohit's test feedback on Windows:
   - the 3D lag (FPS meter), templates, doc kit, green screen, cut-out/erase, captions with Whisper, Director v2, the Claude control connection.
   - Fix bugs he reports.
3. When Mohit approves, **merge `integ/v1` into `main`** for the phone release. Watch "Build APK"; Android-specific breakage is possible: shaders, the PcmSource and WinAi guards, minSdk.
4. Implement the leftover TODOs:
   - Windows `PcmSource` via ffmpeg for music analysis;
   - Director using the new SFX kinds + `beat_sync` + `auto_mix`;
   - timeline beat markers; PrecompBreadcrumbs placement;
   - audio inside precomps in the export mix; blend modes;
   - a better cut-out model; cleanup of unused files.
5. More references: Mohit may send more clips (intros, transitions with sound, caption styles, music under voice). Analyse each one into reusable pieces: asset/set/move/transition/atmosphere/look-frame. Build only the missing pieces.
6. Optional: signed distribution (private Microsoft Store listing or Artifact Signing) so Smart App Control can go back on.

---

## 7. Key docs in the repo

- `docs/V1_PLAN.md`: V1 plan, ownership, B/C contract, and the **full reference-clip notes** (viral intro, village fly-through, all 10 clips).
- `docs/REFERENCE_STYLE.md`: earlier reference analysis (doc-kit style, 20 building blocks).
- `docs/EDIT_COMMANDS.md`, `docs/ROADMAP.md`, `docs/CLAUDE_CONTROL.md`, `README.md`.
- `lib/ai/command_spec.dart`: the authoritative list of every op/component/effect the AI can use.

## win-30 (branch `integ/v3`, Windows releases win-31 …)

**Engine**
- 3D layers that reach behind the camera are drawn cropped to their part in view (`RenderItem.crop`, `Evaluator.nearCrop`) instead of culled: no more black frames from big backgrounds/floors during pass_by / orbit / arc.
- Stacked parallel 3D layers (tilted calendar pages, cards on a board) sort by plane distance (`Evaluator.stackedDepthKeys`).
- Camera-facing 3D layers get a sub-pixel perspective term in the **editor preview only** (`Realism.previewSafe`) — the Windows compositor dropped them.
- Masks clip what effects draw past the layer edge (eye_reflection "square box").
- New camera_shot moves: `truck`, `arc`, `crane`.

**Components / commands**
- x / y / size / width / height on components accept 0–1 fractions (`_B.f`).
- map `bounds`: [[lat,lon],[lat,lon]], flat list or {north,south,east,west}; bad bounds are an error.
- book: 2+ filled pages are read (zoom first, hold per page, marks on their own page).
- match_colour default amount 60, exposure capped 75–140 %.
- shape layers accept `shape` as an alias of `kind`.
- `room` component = real 3D set (walls/floor planes, grounded items, foreground).

**Templates** (`templates_sets.dart`, each builds its own precomp, every slot optional, `look` slot: warm|cold|noir|vintage):
photo pile → title, pieces on a board, stage line-up, topics → idea, pinned portraits, room set, street set, push through a frame, character intro, article on a desk.

**MCP** (45 tools): get_layers, editor_screenshot, get_logs, list_files / read_file / write_file (Documents\MotionAI* only), `comp` on get_layer / render_frame / preview_shot, `format: jpeg`, `export_status {wait_s}`, perf (RAM) in get_state, POST `/api/upload` for Google Flow (origins labs.google / flow.google.com, bearer token) → Documents\MotionAI_Flow\<folder>. Helper: `tool/flow_helper.js` (match by Flow batch card).

**GPU / export**: NVIDIA/AMD high-performance exports in the runner, "Use high-performance GPU" button (Windows per-app preference), compat FFmpeg (n7.1/n6.1) for NVENC on older drivers, encoder error reasons + re-check, `-hwaccel auto` decoding, overlapped encoder writes, cancel needs confirmation (Cancel button excluded from focus), cancel source logged.

**Memory**: `MemoryGuard` — 256 MB decoded-image cap, caches trimmed above 2 GB RSS.

**Not done yet**: video proxy files (the reader already decodes at preview size).
