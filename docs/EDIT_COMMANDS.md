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
