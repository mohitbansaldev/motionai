# Edit commands (the AI agent interface)

Every change to a project is a JSON command. The UI uses these
commands too, so anything a person can do, the agent can do, and
everything the agent does is normal, editable, undoable timeline content.

Send one command, a list, or `{"commands": [...]}`. A list runs as one
**atomic batch**: if any command fails, nothing changes, and one Undo
reverts the whole batch. Errors name the valid options so an agent can
correct itself and retry.

## Conventions

- **Time** is in seconds of composition time. If `time` or `start` is left
  out, the playhead time is used.
- **Coordinates** are composition pixels: x to the right, y down,
  z away from the viewer. (0,0) is the top-left of the frame.
- **Values** are a number or a list: `[x, y, z]`. A single number on a
  multi-value property sets every component (`"scale": 120` → 120/120/120).
- **Property paths:** `position`, `anchor`, `scale`, `rotation` (x, y, z degrees), `opacity` (0–100).
  Add `.x`, `.y` or `.z` to set one component: `"prop": "position.z"`.
- **Target:** a layer id, or `"camera"`. Add `"effect": "<id>"` to address an effect parameter.
- **Colors:** `"#RRGGBB"`.
- **Ease:** `linear`, `hold`, `ease_in`, `ease_out`, `easy_ease`, `bounce`,
  `elastic`, `back`, or `{"type":"bezier","x1":0.2,"y1":0,"x2":0,"y2":1}`.
  The ease on a keyframe controls the motion *from* it to the next keyframe.

## Layers

| op | fields |
|---|---|
| `add_layer` | `type` (video, image, text, solid, null), `id`?, `name`?, `media` (video/image), `start`?, `duration`?, `source_in`?, `index`? (0 = top), `is3d`?, `fit`? (contain, cover, none), `position`?, `scale`?, `text`?, `font_size`?, `font_weight`?, `text_color`?, `align`?, `color`?, `width`?, `height`? |
| `remove_layer` | `layer` |
| `duplicate_layer` | `layer`, `new_id`? |
| `update_layer` | `layer` + any of `name`, `start` (moves its keyframes too), `duration`, `source_in`, `speed`, `is3d`, `visible`, `locked`, `parent` (id or null), `blend`, `color`, `text`, `font_size`, `font_weight`, `text_color`, `align`, `width`, `height` |
| `reorder_layer` | `layer`, `index` |
| `trim_layer` | `layer`, `in`? (new start time), `out`? (new end time) |
| `split_layer` | `layer`, `time`?, `new_id`? |

## Properties and keyframes

| op | fields |
|---|---|
| `set_property` | `target`, `prop`, `value` (if the property is animated, this sets a keyframe at the playhead) |
| `set_keyframe` | `target`, `prop`, `time`?, `value`, `ease`? |
| `remove_keyframe` | `target`, `prop`, `time` |
| `clear_keyframes` | `target`, `prop`, `time`? (the value at that time is kept) |
| `set_ease` | `target`, `prop`, `time`, `ease` |

## Effects

| op | fields |
|---|---|
| `add_effect` | `layer`, `effect` (blur, color, tint, vignette), `id`?, `params`? |
| `remove_effect` | `layer`, `effect` (id) |
| `set_effect_param` | `layer`, `effect`, `param`, `value`, `time`? (if given, sets a keyframe) |

| effect | params |
|---|---|
| blur | `amount` 0–100 |
| color | `brightness`, `contrast`, `saturation` −100…100 |
| tint | `color` [r,g,b] 0–255, `amount` 0–100 |
| vignette | `amount` 0–100, `size` 0–100 |

## Camera

| op | fields |
|---|---|
| `set_camera_mode` | `mode`: off, 2d, 3d |
| `camera_move` | `preset`, `start`?, `duration`? (3), `amount`?, `ease`?, `direction`? (left, right, up, down) |
| `parallax_rig` | `layers` [back … front], `depth`? (500 px between layers), `push`? (350 px), `start`?, `duration`? (4) |

3D camera properties: `position`, `poi` (point of interest), `zoom`, `roll`, `focus`, `aperture`.
2D camera properties: `pan`, `zoom2d`, `rotation2d`, `shake`, `shakeSpeed`.

Presets: `push_in`, `pull_out`, `orbit` (amount = degrees), `dolly_zoom`,
`drone_reveal`, `truck`, `pedestal`, `pan_2d`, `zoom_in_2d`, `zoom_out_2d`,
`rotate_2d`, `shake` (amount = pixels). Each move starts from wherever the
camera is at `start`, so you can chain moves.

## V2: transitions, looks, masks, text animation

| op | fields |
|---|---|
| `animate_in` / `animate_out` | `layer`, `preset` (fade, zoom_in, zoom_out, slide_left, slide_right, slide_up, slide_down, blur, spin, pop, whip), `duration`? (0.6) |
| `apply_style` | `style` (cinematic_doc, shorts_punch, retro_film, noir, warm_travel, clean_minimal), `layers`? |
| `add_mask` | `layer`, `shape` (ellipse, rect), `center`? [x,y], `size`? [w,h], `feather`?, `invert`?, `id`? |
| `update_mask` | `layer`, `mask`, `shape`?, `invert`? |
| `remove_mask` | `layer`, `mask` |

Mask props are keyframeable: `{"op":"set_keyframe","target":"L1","mask":"m1","prop":"size","time":1,"value":[800,800]}`.

Text fields on `add_layer` / `update_layer`: `animator` (none, typewriter, word_pop, fade_up, slide_up, karaoke), `anim_duration`, `highlight_color`, `box_color` (or "none"), `shadow`, `words` [{w, s, e}] (per-word timings for karaoke).

New effects: glow {amount, radius}, grain {amount, size}, light_leak {amount, speed}, gradient {amount, top}, letterbox {amount}.

Audio: `add_layer` with `type: "audio"` and an audio media id. Every layer has a `volume` property (0–200).

## V2-F: asset library pipeline (MCP tools, not edit commands)

Library operations work on the cross-project asset library (files on disk), so they are tools / library APIs
(`lib/library/library_ops.dart`: `LibraryOps.importFolder / clean / search / suggest`, JSON in → JSON out), not
undoable project ops.

| tool | fields |
|---|---|
| `library_import_folder` | `path`, `recursive`? (true), `kit`? (default folder name), `tags`? [..], `green_screen`? auto\|true\|false (auto), `remove_mark`? (false) |
| `library_clean` | `ids`? ["lib:<id>"] \| `kit`? \| `all`?, `green_screen`? (auto), `remove_mark`? (true), `restore`? |
| `library_search` | `query`?, `role`?/`roles`? (character, object, plate, overlay, set_piece, audio + synonyms), `tags`?, `kit`?, `type`?, `transparent`?, `limit`? |
| `library_suggest` | `brief`, `roles`? [..], `kit`?, `limit`? (per role, 5) |

Roles from file prefixes / folders: `char_` → character (kind person), `prop_` → object (prop), `plate_`/`bg_` → plate,
`fx_` → overlay, `cut_` → set_piece; folders `plates/`, `fx/`, `props/`, `characters/`. A JPEG and a PNG with the same
name (`char_x.jpg` on green, `cutouts/char_x.png`) → the PNG is imported. Same file twice → the existing asset.
Green-screen keying reuses the chroma_key maths (tolerance 40, softness 16, spill 70, light choke) and keeps the
original (`LibraryAsset.original`, `cleaned: [green_screen, mark]`). The mark remover only acts on a small, isolated,
star-shaped bright blob 0.5–9 % in from the bottom-right corner and inpaints just that patch.

Text animators `scramble`, `random_pop`, `typewriter` (and the typewriter SFX, number tiles) work on whole letters:
grapheme clusters with Indic conjuncts kept together ("स्था", "क्ष", "श्री"); settled text renders exactly like a plain
text layer.

<!-- V2-C >>> -->
## V2-C: documentary transitions

| op | fields |
|---|---|
| `transition` | `from` (outgoing layer), `to` (incoming layer) — or `layers: [from, to]`; `type`; `duration`?; `at`? (cut, default `to.start`); `sound`? (`true` = default SFX with its peak on the cut, `false`, a kind, or a list); `snap_to_beat`? (`true`: cut moves to the nearest analysed music beat within `beat_tolerance` (0.25 s); `beats`: [s] overrides the analysis); `params`? (per type, below; unknown top-level keys are passed as params too) |
| `list_transitions` | — logs the catalog JSON (`id`, `label`, `best_for`, `default_duration`, `cut_at`, `sound`, `params`) |

The op extends/trims both layers so they overlap around the cut (uses source handles; a shot without a handle is shifted and the log says so), writes eased keyframes, masks, effects and helper layers (`tr_<to>_*`), adds the SFX and is one undo step. Running it again on the same pair replaces the old transition (effects `<from>_trout_*`, `<to>_trin_*`).

| type | default s | params |
|---|---|---|
| push_through | 1.2 | `target` (door/window layer here or inside the outgoing precomp) or `point`+`size`, `shape` rect/ellipse |
| foreground_wipe | 0.8 | `direction`, `media` (cut-out), `shape` pillar/tree/person, `width` (0.55) |
| zoom_into_photo | 1.6 | `layer` (picture) or `point`+`size` |
| map_drop | 1.5 | `target`/`point`, `push` (1.06: the incoming ends 6 % closer) |
| match_cut | 0.6 | `from_point`, `to_point`, `from_size`, `to_size` |
| whip_pan, parallax_slide, paper_tear | 0.45 / 1.0 / 0.9 | `direction` left/right/up/down |
| burn_edge | 1.6 | `cx`, `cy` (%), `tone` |
| page_turn | 1.2 | `angle` (200) |
| focus_pull, dolly_zoom | 1.0 / 1.6 | — |
| film_burn, light_leak_wipe, ink_bleed, smoke_reveal | 1.0 / 1.0 / 1.2 / 1.4 | `tone` warm/cold/neutral (ink: `cx`, `cy`) |
| bw_to_colour | 2.0 | `cx`, `cy` |
| glitch_cut, flash_cut, dip_to_black | 0.6 / 0.5 / 0.9 | flash: `color`/`tone`; dip: `color` |

Example: `{"op":"transition","from":"shot1","to":"shot2","type":"push_through","params":{"target":"door"},"snap_to_beat":true}`

New effects: `burn_edge` {progress, cx, cy, color, embers}, `page_curl` {progress, angle, shadow, back}.
<!-- <<< V2-C -->

## V2-E: depth from photo (2.5D parallax)

| op | fields |
|---|---|
| `photo_to_3d` | `media` (photo id) or `layer` (photo layer id), `layers`? 3–6 (4), `start`?, `duration`? (rest of the layer), `camera`? move name (`drift` = slow push-in + drift, or any `camera_shot` move) / `{move, intensity?, direction?, start?, duration?}` / `"none"`, `intensity`? 0–1 (0.5), `model`? `auto` / `depth` / `fake` |
| `depth_map` | `media`, `model`? — new grayscale photo media, near = white |

Both run as a **background job** (`depth_N`): the command validates and logs the job
id; poll `job_status {job}`. When the job is done the app re-runs the command with
`prepared` (internal: `{model, layers: [{media, x, y, k, depth}]}`), which is the one
undo step that places the layers.

How it works: depth from Depth Anything V2 Small (ONNX on Windows, model downloaded
once) or a built-in estimate (`fake`: ground-plane gradient + sky / detail / haze
cues; used on Android or if the model fails). The photo is split at depth quantiles
into far → near layers; each nearer layer's matte is its region grown a few px plus
an edge-following feather, and behind it the farther layer is inpainted, so the
stack composites to the original photo exactly. Photos that fill the frame get a
mirrored 8 % margin so camera moves show no edges. Layers are copies of the photo
layer (timing, transform, masks; frame-wide effects such as vignette/grain stay on
the far layer only) pushed to camera distance `k` × home distance with the
make_3d homothety, k from the slice's mean inverse depth (0.5 intensity: far ≈ 2.75,
near ≈ 0.63). The flat photo layer is hidden, then `camera_shot` adds the move.

## Composition

| op | fields |
|---|---|
| `set_comp` | `name`?, `width`?, `height`?, `fps`?, `duration`?, `background`? |
| `batch` | `commands` [...] |

## Example: documentary intro

```json
[
  {"op": "add_layer", "type": "image", "media": "img_fort", "id": "bg", "fit": "cover"},
  {"op": "add_layer", "type": "text", "id": "t1", "text": "Amber Fort, 1592", "font_size": 140, "position": [960, 820, 0]},
  {"op": "parallax_rig", "layers": ["bg", "t1"], "depth": 700, "push": 400, "start": 0, "duration": 6},
  {"op": "add_effect", "layer": "bg", "effect": "color", "id": "grade", "params": {"contrast": 15, "saturation": -30}},
  {"op": "add_effect", "layer": "bg", "effect": "vignette", "params": {"amount": 70}},
  {"op": "set_keyframe", "target": "t1", "prop": "opacity", "time": 0.5, "value": 0},
  {"op": "set_keyframe", "target": "t1", "prop": "opacity", "time": 1.5, "value": 100},
  {"op": "camera_move", "preset": "shake", "start": 4.5, "duration": 0.6, "amount": 8}
]
```

## Realism (V2-D): photo-real 2.5D from flat cut-outs

| op | fields |
|---|---|
| `make_3d` (extras) | `haze`? 0–100 (default 25; 0 = off): far/sky layers get a `haze` effect toward the sky colour; `contact_shadows`? (default true): near/mid image cut-outs whose bottom is in the lower frame get a `contact_shadow` (feet measured from the alpha). Adjustment layers are never put in depth. |
| `match_colour` (`match_color`) | `layer` (cut-out), `to`? plate layer id or `"below"` (default), `amount`? 0–100, `time`?, `light_wrap`? true. Sets a `grade` effect `<layer>_match` (exposure, white balance, saturation, contrast, black level) from pixel statistics of the cut-out and of the plate region behind it. Image/solid layers. |
| `camera_shake` | `start`?, `duration`? (impact 0.8 s, else 2 s), `amount`? 0–100 (40), `style`: `handheld` \| `walk` \| `impact` \| `earthquake`. Smooth deterministic noise on the camera (3D: 70% rotation, 30% movement; 2D: pan/rotation) with an eased envelope. Camera props `shake3d` (px) / `shake3dStyle`. |
| `set_dof` | `focus`: `"target"` (camera point of interest — follows camera_shot targets) \| layer id (3D) \| number (px) \| `"off"`, `aperture`? (default 20). Same as `set_comp {dof: {...}}` / `{dof: false}`. Comp field `dofFocus`. |
| `apply_style` (extras) | `doc_golden_hour`, `doc_cold_night`, `doc_archive_sepia`, `doc_teal_orange`, `doc_noir_contrast`, `doc_desaturated_war` → adjustment layer `look`; `film_look` → adjustment layer `film_look` above it. |
| `add_layer` / `update_layer` | `adjustment`: true on a solid/null layer → its effects (and masks, opacity as a mix) apply to everything below it. |

Effects: `contact_shadow` {opacity 55, softness, length, angle (light direction °, 0 right / 90 overhead / 180 left), color, cast 0–100 (skewed fading silhouette), x0/x1/bottom (feet, % of the box)}, `grade` {lift [r,g,b] %, gain [r,g,b] %, saturation, contrast, amount}, `haze` {amount, color}, `light_wrap` {amount, width, color}, `bloom` {threshold, amount, radius}, `halation` {amount, radius, threshold}, `chromatic_aberration` {amount}, `lens_distortion` {amount −100..100, + barrel}, `gate_weave` {amount, flicker}.

## V2-B: default layer timing, shots and sequences

**Default timing.** `add_layer` without `start` starts at 0 (not at the playhead). Without `start` *and* `duration` a still/text/solid/shape/null layer lasts the whole comp — inside a shot precomp, the whole shot. With only `start` it lasts 5 s (as before); video, audio and comp layers last their source. `add_component` without `start` starts at 0; "set" components (map, room, board, tv_frame, glass_screen, map_fly, route_follow, silhouette_crowd, poster, plaque, article) without start/duration span the comp, pop-ups keep 5 s. Existing projects are unchanged (only new layers are affected). The editor's Add panel still inserts at the playhead (it passes `start`).

| op | fields |
|---|---|
| `add_shot` | `id`?, `name`?, `start`? (end of the last shot), `duration`? (6), `style`?, `plate` (media id), `layers` [{`media`, `role`? sky/far/mid/near/front/ground, `id`?, `x`? 0..1, `ground`? 0..1 (bottom), `height`? 0..1, `flip`?, `hero`?, `effects`?}], `floor`? (0.88), `ground`? auto/shadows/none/media id, `ground_color`?, `camera`? [{`move`, `target`?, `start`, `duration`, `intensity`, `ease`?, `direction`?}] or "none", `atmosphere`?, `look`?, `title`?, `caption`?, `keep_far_visible`? (true) |
| `sequence` | `shots` [add_shot specs], `start`?, `transition`?, `transition_duration`?, `transitions`? [{`between`: [i, i+1], `type`, `duration`?, `overlap`?}] |
| `update_shot` | `shot`, any add_shot field, `ripple`? |
| `remove_shot` | `shot`, `ripple`? |

A shot is a precomp (own 3D camera) + ONE comp layer in main; both use the shot id. Cut-outs are sized by role (front ≤ 45 % of the frame height, tall mid ≈ 62 %, far ≈ 27 %, aspect-aware), their bottoms stand on one floor plane (the ground lines of the far/near bands follow from the perspective), they get soft contact shadows, and a soft floor plane fades out with distance (`ground: "auto"`). The camera moves are the `camera_shot` moves, clamped to keep clear of every layer; the plate is grown so no empty edge shows at any time of the shot. Shots are stored in `Project.seqShots` (`seq_shots` in JSON) so `update_shot` can rebuild them.

Styles (`style`): `opening_reveal`, `character_focus`, `crowd_pass`, `slow_push_detail`, `crash_pull_back` — each sets camera, atmosphere and look; explicit fields override.

Transitions come from `TransitionRegistry` (lib/core/presets/transition_registry.dart; providers call `TransitionRegistry.addRegistrar(DocTransitions.registerAll)`); unknown types fall back to an `animate_in` preset on the incoming shot (fade, flash, ink, smoke, iris, whip, blur, glitch_flash…).

```json
{"op": "sequence", "transition": "flash", "transition_duration": 0.5, "shots": [
  {"plate": "dutch_sky", "style": "opening_reveal", "title": {"text": "TULIP MANIA", "subtitle": "Amsterdam, 1637"},
   "layers": [{"media": "windmill", "role": "far"}, {"media": "houses", "role": "mid"}, {"media": "tulips", "role": "front"}]},
  {"plate": "market", "style": "character_focus", "layers": [{"media": "merchant", "role": "mid", "hero": true}, {"media": "crowd", "role": "far"}]},
  {"plate": "vault", "style": "slow_push_detail", "duration": 5, "layers": [{"media": "gold", "role": "front"}, {"media": "bulb", "role": "mid", "hero": true}]}
]}
```

## V3-A: maps & geo (documentary map grammar)

All of these are one command = one undo step. The geo ops are also
`add_component` types (`{"op":"status_ring",...}` ==
`{"op":"add_component","type":"status_ring",...}`). Sizes ≤ 1 are a
fraction of the frame height, larger numbers are pixels. Map places are
`[lat, lon]`, `{lat, lon}` or a country name / ISO code.

| op / component | fields | when to use |
|---|---|---|
| `map` `style: "satellite"` | `countries` [name \| ISO \| `{code, fill, label, at, label_rotate}`], `focus`, `bounds` `[[lat,lon],[lat,lon]]`, `zoom`, `fill_opacity` (0.62), `stroke_width` (screen px, 1.6), `label_size` (0.06), `label_opacity`, `label_rotate` (`"auto"` default on satellite \| degrees \| 0), `label_animator` (`pop` 120→100 % in 0.25 s \| `typewriter` \| `fade_up`), `label_stagger` (0.6 s), `focus_dim` (60), `cities` `[{name, lat, lon, at, side}]`, `tilt` (+ `tilt_at`, `roll`), `zoom_rotation` (degrees turned during the zoom; map-only shots), `texture_opacity`, `border_width` | a country/city is named: reveal it on the word with `at` |
| `map_pin` `tag_style: "box"` | `map`?, `lat`, `lon` \| `country`, `label`, `side`, `label_size` | a city/site is named (white box, black caps, constant screen size) |
| `route_follow` | `from`, `to`, `map`?, `style` (satellite), `arrow_head` (true), `line_style` (`solid` \| `dashed`), `draw` (2.2 s), `vehicle` (cut-out id, faces right), `orient` (true), `vehicle_angle`, `vehicle_size`, `trail_fade` (true \| 0..1), `land_highlight` (`{fill, label}` \| false), `from_highlight`, `label` + `label_at` (0.5) + `follow_tangent` (true), `follow` (0.35), `push` (0.08), `fill` (0.62) | "went from X to Y": white arc draws A→B, map keeps the tip in frame, B fills + label pops on arrival |
| `map_route` | `map`, `from`, `to`, `label`, `label_at`, `follow_tangent`, `line_style`, `arrow_head`, `draw`, `line_width`, `label_size` | travel time / distance label ("11 MINS") wiping in along the arc |
| `camera_move` `preset: "punch_in"` | `point` [x,y] \| `target` layer, `amount` (×2.6), `duration` (0.45), `start`, `ease` (ease_in), `layer` \| `map` (punch a layer / map group instead of the 2D camera — required when the camera is 3D), `center`, `blur` (true), `sound` (true \| sfx kind \| false) | emphasis / right before a twist (motion blur + whoosh) |
| `map_tilt` | `map`?, `tilt` (38), `roll` (−10), `at`, `duration` (0.6), `scale` | mountains, rivers, borders: the map pitches back in 3D (moved into precomp `<map>_tilt`, comp layer `<map>_tilted`; later map ops on it need `in_comp`) |
| `terrain_label` | `map`?, `text`, `along` `[[lat,lon],…]`, `size` (0.045), `spread` (0.8), `stagger`, `glyphs` (`peaks` \| `none`), `opacity` | a mountain range / river / border is named (letters along the feature + peak hatches) |
| `map_watermark` | `map`?, `code`, `text`, `size` (0.35), `opacity` (60), `rotate` (`auto` \| degrees) | establishing the country: giant ghost word along its axis |
| `status_ring` | `attach` \| `lat`+`lon` \| `x`,`y` \| `at`, `size` (0.06), `color` (#D0202A), `dashed`, `dashes`, `spin` (4 s/turn), `glow` | marking the tracked vehicle / subject |
| `signal_rings` | `attach` \| place \| point, `color` (red), `count` (3), `period` (0.75), `flatten` (0.35), `max_radius` (0.12), `opacity`, `delay` | radio calls, distress signals |
| `pulse_rings` | same; white, 4 rings, 1.2 s, round | "here", epicentre, a location pinging |
| `geo_label` | `text`, `at` [x,y] (comp px) \| `lat`+`lon` \| `at:{lat,lon}` \| `attach`, `pointer` (`hook` \| `line` \| `none`), `side`, `length`, `size` (0.04), `animator` (typewriter), `color` | a specific spot on the ground ("CRASH SITE") |
| `path_text` | `text`, `path_layer` (shape layer with points) \| `points`, `offset`, `size`, `spacing`, `lift`, `typing` (true), `cps` (14), `color` | naming a planned route along a (dashed) line |
| `search_sweep` | `place`, `label`, `vehicle` (top-down cut-out, else vector helicopter), `ground` (media, else slate snow), `beam_size` (0.12), `path` [[x,y] 0..1], `snow` (true), `duration` (4.5) | "a search began over X" |
| `sketch_map` | `items` `[{icon: mountain\|camp\|crash\|x\|river\|dot, x, y, label, arrow, at}]`, `compass` (`{x, y, size, heading:[{at, deg}]}` \| false), `directions` `[{label, side, at, reveal: photo}]`, `paper`, `duration` (7) | directions / "which way": parchment sketch, chrome compass, red block arrows, photo reveals |

The satellite texture is NASA Blue Marble (public domain), bundled as
`assets/maps/blue_marble_dark.jpg` (4096×2048, ocean graded dark teal) and
drawn by the `map_texture {amount}` effect on the map's `<id>_sat` layer.
If it cannot be loaded the dark vector map underneath stays visible.
<!-- V3-D >>> -->
## V3-D: transitions, mood & character FX (documentary patterns 35–54)

New `transition` types (same op, same rules as V2-C: one undo step, eased keys, helper layers `tr_<to>_*`, default SFX peak on the cut; `sequence` picks them up too):

| type | params | when to use |
|---|---|---|
| `powder_burst` | `direction` right/left/center/top/bottom, `kind` snow/dust/sand/ash, `color`, `density` 80, `linger` 0.3 | signature cut for snowy/desert stories, in/out of the presenter; full cover 2–3 frames at the cut, flakes linger (powder_whoosh) |
| `debris_burst` | `kind` ice/snow/cloud/glass/dust/leaves, `from` (9 origins), `pre_roll` 1.2, `peak_cover` 100, `tail` 0.5, `tone`, `density` | the most frequent scene change: sparse shards, dense burst toward the lens, clears over the next shot (ice_crash) |
| `frost_shatter` | `corner` | cold/ice stories: frost grows from a corner, then the shot shatters with a radial blur |
| `zoom_blur` | `zoom` 2.5, `flash`, `grain`, `cx`, `cy` | evidence → reenactment, macro → presenter, leaving an archive photo |
| `eye_reflection` | `point` (pupil), `size` (15% w), `opacity` 70, `linger` 0.8 | event → witness reaction; incoming eye ECU pulls back 5× → 1× |
| `holes` | `count` 45, `size` 10, `rim` | harsh exit from a gruesome still |
| `shatter` | `tone` glass/ice/gold, `lead_in` 1.0, `shard_color`, `cx`, `cy` | impact: cracks spread, then the break |
| `slice` | `bands` 4, `stagger` 30 | fast topic changes |
| `slant_wipe` | `direction` (enters from), `angle` 10, `edge` 60 | a slanted panel slides in, the old shot compresses aside |
| `shrink_to_card` | `size` 0.45, `bg` grunge_red/none, `tilt`, `hold` 1.5, `border` | footage becomes an evidence card over the next shot |
| `emerge` | `target` / `point`, `from` 0.05 | next card grows out of a point/layer |
| `zoom_out_of_photo` | `layer` (photo in the incoming shot / precomp) or `photo_box` [x0,y0,x1,y1] or `point`+`size` | pull back from a full-frame photo into the article/book it is in |
| `slide_film` | `size` 0.55, `pink` 30 | reconstruction → real archive photo (35 mm slide carousel) |
| `exposure_in` | `from` 3.0, `color` | sun-glare entry |
| `punch_in` | — | presenter return: 150% blurred → 100% in 0.25 s |
| `cut_to_black` | `silence` true (duration = black hold) | crash → black + silence |
| `ink_bleed` | + `incoming`: "duotone_of_outgoing" (no `to` = split the outgoing at `at`) | turning point: navy duotone of the same image |

Ops (lib/core/commands/v3_fx_commands.dart):

| op | fields | when to use |
|---|---|---|
| `mood_flood` | `at`, `duration` 0.9, `hold` 2.5, `color` "#E0283A", `dark` "#5A0A10", `from` corner, `keep` [ids], `sfx` "braam" | dread/despair/negative twist: red monochrome ink flood from a corner, kept layers stay in colour (copies above the flood), hard end |
| `tint_wipe` | `at`, `color`, `amount` 70, `from`, `duration` 0.6, `hold` 2 | a colour mood sweeping across |
| `grade_swap` | `to` hope/warm/cold/dread/archive/normal, `at`, `duration` (0 = snap), `until` | story turns (hope = saturated green/warm); ends a running grade_swap |
| `spotlight_subject` | `keep` [ids], `layers` / `shot`, `others` {mono 100, dim 15, blur}, `tint` {color, amount}, `start`, `duration` 3, `attack` 0.25, `release` 0.5 | one person among many, injury/danger |
| `pulse` | `layer`, `effect` (tint default) / `prop`, `param`, `from`, `to`, `period` 1, `start`, `duration` 3, `sync` [ids], `sfx` | red pain pulse, blinking, heartbeat |
| `cut_to_black` | `at`, `hold` 1.5, `silence` true, `sfx` "impact" | crash → black + silence |
| `lightning` | `at` s or [s…], `bolt` true, `x` 0.62, `color`, `sfx` "thunder" | storms, shock flashes |
| `montage` | `media` [ids], `start`, `every` 0.35, `looks` [threshold, duotone_green, red_paint, magenta, grunge, crop], `zoom` 8, `sound` | one-breath recap before the presenter |
| `swap_layer` | `layer`, `with` (layer or media id), `at`, `transition` pop/cut/fade/flash, `duration`, `sfx` | an object/photo changes in place |
| `set_dof` | + `keys` [{`t`, `focus` px or 3D layer id}] | keyframed rack focus |

`animate_in` / `animate_out` presets: `punch_in`, `swing_in` {`rotation` 20, `scale_from` 2.5, `background` layer id blurred → sharp}, `exposure_in` {`from` 3.0, `color`}.

`speech_bubble` (add_component): `text` or `messages` [{`text`, `at`}], `style` comic/clean/radio (`classic` = the V1 bubble), `tail_to` [x,y] or layer id, `attach` layer id (parented, follows it), `cps` 30, `type_delay` 0.15, `caps` true, `exit` pop/puff/fade/none, `blink` period, `auto_fade`, `sound` (pop / radio_crackle + typing + puff). Pops 0 → 110 → 100 % in 0.2 s; Comic Neue (OFL, assets/fonts/comicneue) for comic.

Effects: `burst` (powder/debris engine: kind, origin, density, color, cut/rise/hold/clear/linger/pre_roll in s after the layer start, cover), `radial_blur` {amount, cx, cy}, `holes` {progress, count, size, rim}, `frost` {progress, corner, color}, `cracks` {progress, cx, cy, color}, `threshold` {level, softness, amount}, `red_paint` {amount, color}, `lightning` {flash, bolt, x, variant, color}, `slices` {progress, bands, stagger}, `slant_wipe` {progress, angle, side, softness, edge}, `slide_mount` {color, print, window, number}, `puff` {amount, color}. Particle kinds + `debris`, `snow_spray`, `ice`. Sounds + `thunder`, `powder_whoosh`, `ice_crash`, `puff`, `marker`, `radio_crackle`.
<!-- <<< V3-D -->
