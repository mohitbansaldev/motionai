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

## Reference analysis — "Balochistan Issue Explained" (20 clips, ~14 min sampled, win-30)

Screen time (approx.): presenter A-roll 35–40 % · maps 25–30 % · evidence (articles, quote cards, documents) ~25 % · illustrated story scenes 20–25 % · archival photo frames / symbolic graphics ~10 %.
Pacing: B-roll shots 3–8 s, presenter returns every 10–20 s, a new element every 1–2 s, the camera never stops.

- **Maps**: oblique 3D terrain (hill-shade relief), flat bold fills (yellow / purple / maroon / teal / green), thick light borders, huge standing 3D labels with shadow ("WEST PAKISTAN"), condensed caps place names, red pins dropping, leader-line callouts ("1871 Goldsmid Line" red year badge), dotted routes, emblems and evidence cards placed on the map, stamp slamming "INDEPENDENT", low continuous flyover.
- **Evidence**: browser screenshots with dark vignette + blur edges, slow push / scroll, yellow highlight sweeping word by word; quote cards (source logo, title, highlighted body) over illustrated scenes; torn-paper strips (DAWN); newspaper front pages; documents falling onto a wooden desk under a spotlight.
- **Story scenes**: rich warm AI illustrations (treaty signing, council, fighters in mountains), faces anonymised with black / red bars, name label in a colour box + year, crowd cut-outs layered in rows sliding in (parallax), slow push.
- **A-roll overlays**: timeline ruler with a dated marker (8 DEC 1876), "Join us on" social CTA, handle bug.
- **Look**: warm tungsten A-roll, dark vignettes, high contrast, light grain; heavy condensed white caps, highlighter yellow, red accents. Very little free text — labels and highlighted sources carry the words.

## Reference analysis — "flydubai hijack" (20 clips, ~7.5 min sampled)

Same skeleton (presenter ~40 %, returns every 10–20 s; B-roll 3–8 s; element every 1–2 s), more photographic:
- **Photoreal AI story frames** (hospital, classroom, airport, cockpit), "Generative AI" tag bottom-left; often **selective colour**: subject black-and-white over a red / colour background; **sticker cut-outs** with a thick orange / red / white outline over a texture or map.
- **Source block lower third** on almost every B-roll shot: "SOURCE: WWW.BBC.COM", bold headline, body with red / yellow underline or highlight. Torn-paper notes with highlighted lines on the right.
- **Maps**: flat paper-texture maps with bold country fills (red / blue), big rotated country names, **photo insets in a polygon frame with an orange stroke** on the map, plane icon flying a glowing route, 3D terrain map with a giant figure placing a toy plane (scale play), dotted route lines between airports.
- **Investigation board**: cork board, pinned photos, red string, circular spotlight vignette.
- **Fake UI**: airline app / crew roster on a laptop or monitor, a tweet card, a police portal search with "no record found", stamped "CLEARED".
- **Symbol shots**: hand holding a money bag with an animated price tag ($83,455 → $250,000), burning half-face for "EXTREMISM", grunge stamped words ("SECONDARY EDUCATION", "RESIGN").
- **Logo nodes** linked by dashed lines (Oman Air → GCAA → flydubai) with photo bubbles.
- A-roll overlays: dated timeline ruler (2013 / 2014 / 30 SEP 2026), "Join us on" WhatsApp / Instagram, "Click the LINK in Description" ticker.

## Motion timings (non-AI-video parts, measured at 4–5 fps) — build targets
- **No fades, no black**: every change of picture is a camera move — whip pan / fast push / pull-out with motion blur, 0.2–0.5 s.
- **Map state changes** (Balochistan 08): country fills wipe in ~0.5 s, borders draw, quote card pops (0.25 s, small→full), red callout line grows 0.5 s then "1871" badge, then a 0.25 s blurred zoom-out to a wider map. Camera drifts the whole time.
- **Map flyover** (14 @30.5): 0.2 s whip from a document; ~2 s accelerating push + tilt from flat to ~50° oblique; big standing labels; pins drop one by one ~0.4 s apart with a bounce, names type on.
- **Timeline ruler** (08 @9.6): fades up at the bottom over a dark gradient, the decade scale slides ~1.2 s to the era, a dot lands, "8 DEC 1876" pops above in red.
- **Source montage** (18 @6.5): 10–12 article screenshots in 4 s (0.2–0.4 s each), each pushing in, white-vignette blurred edges, the same keyword highlighted yellow in every one.
- **Torn note on map** (10 @9): crumpled paper flies in rotating and unfolds 0.75 s, settles; highlight sweeps line by line (~0.5 s / line); the next note unfolds elsewhere while the first leaves; a small name tag pops.
- **Newspaper** (14 @23.5): the previous frame turns B&W and pulls back to become the photo on a front page (0.5 s), headline bar slides in, fast push into the column, highlight sweeps 3–4 lines over ~1.5 s, blurred whip to the next document, red underline draws under the key line.
- Every shot: slow drift (+3–5 % scale), something new each 1–2 s, enters with fast ease-out (0.25–0.5 s) and a slight overshoot.
