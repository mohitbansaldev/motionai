# Reference style breakdown: Hindi documentary explainer

Source: 29 reference clips in `C:\YT\Tools\Ref\clips` (13 sampled frame-by-frame:
02, 03, 04, 08, 09, 10, 11, 12, 14, 16, 18, 22, 25). Techniques only: MotionAI
rebuilds them with its own graphics, not their footage, logos or artwork.

## The format
- **A-roll**: presenter in a warm, low-key room (lamp, bokeh), mid shot. Cuts to B-roll every 5–15 s.
- **B-roll**: almost every sentence gets a visual: map, source card, photo card, badge, diagram or a staged/AI scene.
- **Grade**: warm interiors, dark grunge backgrounds, desaturated archive photos, strong vignette.
- **Pacing**: elements pop in on the spoken word; nothing sits static for more than ~2 s (slow push, drift, particles).

## Recurring building blocks (→ what MotionAI needs)

| # | Block | Seen in | How it moves | MotionAI feature needed |
|---|---|---|---|---|
| 1 | **Satellite / paper map with highlighted country** (solid or flag fill, stroke, labels) | 02, 03, 07, 10, 12 | Zoom world → country → river/street; country fill pops; neighbour labels | Map kit: country shapes, fill/flag fill, stroke, glow, labels, zoom presets |
| 2 | **Animated route arrows** (curved, dashed or solid, white) | 02, 03, 10 | Line draws on from A to B, arrowhead last | Shape paths with trim-path (draw-on), dash, arrowhead |
| 3 | **Pins & distance callouts** ("13 KM", street name tags) | 02, 09, 11 | Pop in with small bounce; dotted line between pins | Pin/label component, measure line |
| 4 | **Source card** (torn paper / white card: source URL, headline, body text) | 03, 04, 08, 09, 10, 14, 16, 18 | Slides/pops in; **yellow highlighter sweeps** across key lines; **red hand-drawn circle** around a date/word | Source-card component, highlight sweep animator, circle-draw annotation |
| 5 | **Lower-third source line** ("Source: …" + 2–3 lines, highlighted words) | 03, 11 | Types/fades in at bottom-left | Lower-third preset with highlighted spans |
| 6 | **Emblem badge** (circle, ring, label pill under it) | 03, 04, 10, 12 | Pops in; later **shatters into debris** | Badge component + shatter/particle effect |
| 7 | **Photo cards** (white border / torn edges, caption, tilt) + dashed curved connector arrows | 03, 10, 12 | Slide in with rotation, drop shadow | Photo-frame styles, caption, connector arrows |
| 8 | **Cut-out with stroke** (subject with thick yellow/white outline) | 11, 14 | Pops out of scene, slight scale | AI cut-out + outline stroke effect |
| 9 | **Text behind subject** (big outline/neon glow word behind people) | 03, 14 | Glow flicker on | Outline + glow text, depth sandwich (cut-out on top) |
| 10 | **Big numbers / counters** ("3 MILLION BARREL OIL", "$1.1B", "95%") | 11, 14 | Count up, neon glow | Number counter animator, neon text style |
| 11 | **Timeline ruler** (decades, moving marker, date pill "APR 1941") | 04, 11, 25 | Marker slides to the date | Timeline component |
| 12 | **Organisation diagram** (central badge, icons connected by arrows/lines) | 12 | Lines draw from centre outward | Connector lines + icon nodes |
| 13 | **Speech bubbles / quote cards** | 09, 12, 18, 25 | Pop with overshoot | Speech-bubble component |
| 14 | **Line chart** ("GDP over the years") | 14 | Line draws left → right | Chart component (line, %, bar) |
| 15 | **Cutaway diagram** (ground cross-section, drilling) | 22 | Camera pans, layers slide | Shapes + masks (Phase 1) |
| 16 | **TV frame / screen-break transition** | 16 | Content inside an old TV, glass shatters to next scene | Frame overlays, shatter transition |
| 17 | **Newspaper / book page zooms** with red-underlined phrases | 04, 08, 16 | Push in, underline draws | Page component + underline draw |
| 18 | **CTA pop** (join/subscribe pill) on A-roll | 04, 18 | Slides in from the side, bounces | CTA preset |
| 19 | **Eye censor bars** (red bars over eyes in archive images) | 02, 03, 04, 08, 11 | Fixed or tracked | Rect shape + motion tracking (later) |
| 20 | **Particles**: dust, embers, debris | 04, 08 | Ambient drift; burst on badge break | Particle effect |

## Build phases for MotionAI

1. **Shapes + paths (foundation)**: shape layers, pen paths, stroke/dash/arrowheads,
   trim-path draw-on, fill/gradient, drop shadow, outline stroke on any layer.
2. **Documentary kit components** (each = one tap + AI command):
   source card (highlight sweep, circle annotation), lower-third source line, badge,
   photo card, pin + label, route arrow, speech bubble, timeline ruler, CTA, number counter.
3. **Map kit**: bundled world country outlines (public-domain Natural Earth data),
   country fill/flag fill/stroke/glow/label, pins, distance callouts, world→country zoom presets.
   Users bring their own satellite/paper map images (or we provide stylised map backgrounds).
4. **Effects**: shatter/particles, neon/outline text, glow flicker, grunge/paper textures,
   TV/frame overlays, screen-break transition.
5. **AI script mode**: paste the script; the AI tags each sentence (place → map, citation →
   source card, organisation → badge, number → counter, date → timeline) and builds the
   B-roll automatically, cutting between A-roll and B-roll.
