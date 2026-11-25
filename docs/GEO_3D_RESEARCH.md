# Geo layers + After Effects 3D: research and MotionAI plan (win-40)

Researched 26 Nov 2026 for Mohitflix documentaries. Sources are listed at the end.

## 1. GEOlayers 3 (aescripts, Markus Bergelt): what it does

GEOlayers 3 is the reference tool for animated maps in After Effects. Its features, grouped:

| Area | What GEOlayers 3 does |
|---|---|
| **Map comps** | A "mapcomp" is a comp whose imagery is rendered from online map data for the current view. You scroll, zoom, pitch and rotate the map in 3D and keyframe it; GEOlayers renders the imagery for every frame of the move. |
| **Data sources** | Image tile servers (MapTiler Cloud basemaps, Bing imagery), Natural Earth imagery, water masks and data, local tile directories, TMS servers, georeferenced imagery (e.g. NASA Visible Earth). |
| **Styling** | Colours, line widths and fonts; hillshading; show/hide feature groups; separate oceans / lakes / rivers; styles created from the comp's colours, an image or a swatch file. Full styling needs a MapTiler Cloud account. |
| **3D** | Pitch + rotate maps; one-click 3D landscapes from real elevation (with Helium, FreeForm Pro, Plexus or Mir); extruded 3D buildings; a globe sample project (built with Video Copilot Orb, not a built-in globe). |
| **Features** | Online search (countries, cities, buildings, POIs) in Natural Earth / OSM / MapTiler; import polygons, lines and points; draw features to AE shape layers (borders, rivers, roads, buildings, regions); merge / subtract / simplify; lines from polygons; export GeoJSON. |
| **Shape styles** | Dashed strokes with round caps, auto stroke width, stroke outlines, blending modes, animated data-driven styles, time offsets per feature, line mesh of shared borders. |
| **Labels** | One-click automatic labels from templates (any comp can be a template), icon and locator templates, multi-language labels, time offsets, animated text. |
| **Routes / lines** | Driving / cycling / walking routes, animate the view along features, arrows from paths, pin layers by latitude / longitude / height with a progress slider. |
| **Data viz** | CSV / TSV import, choropleth and gradient styles, property diagrams, time-based data. |
| **Scripts** | Scale bars, north needle, blinking, staggered layers, line patterns, arrows, distance circles, 3D scene + camera setup, motion blur for mapcomps. |
| **Licensing** | Provider attribution shown on maps; commercial map data via a MapTiler Cloud subscription. |

What reference documentaries (Nitish Rajput style) actually use from this toolbox: country highlight
with glow borders, a camera fly from the world to a country, pitched 3D maps with depth of field,
animated route arrows, pins with labels, a globe spin, and satellite / relief imagery. Labels are
big, condensed and few.

## 2. After Effects 3D: cameras, views, renderers, glow

**Cameras**
- One-node camera: orients around itself (no point of interest). Best for realistic handheld / dolly
  moves; usually parented to a null.
- Two-node camera (AE default): has a point of interest and always looks at it. Best for orbits and
  shots with one focus. Equivalent to Auto-Orient → Orient towards point of interest.
- Lens presets (15 mm … 200 mm, default 50 mm) set Angle of View, Zoom, Focus Distance, Focal Length
  and Aperture together. Zoom + film size + focal length decide the angle of view.
- Depth of field: Focus Distance, Aperture (F-Stop), Blur Level. Shallow focus = long lens, short
  focus distance, big aperture. "Link Focus Distance to Point of Interest" keeps the POI sharp.

**Views (Composition panel)**
- View layouts: 1 view, 2 views (Active camera + Default camera), 4 views (Active camera, Top,
  Front, Right). Older AE also had one big view + three small ones.
- 3D views: Active Camera, Default Camera, Custom View 1-3 (perspective, orbitable without a
  camera), and orthographic Front / Left / Top / Back / Right / Bottom. Working views show only 3D
  layers and draw the camera, its POI and its frame so you can place it.

**Renderers and lights**
- Classic 3D (layers are "postcards in space"), Cinema 4D, and Advanced 3D (GPU, 3D models GLB /
  GLTF / OBJ / FBX, environment lights from HDRI, shadows, materials, in-engine depth of field,
  depth data extraction).
- Light types: ambient, point, spot, parallel, environment; shadows with darkness and diffusion.

**Glow**
- The look editors want is Deep Glow (Plugin Everything): physically based inverse-square falloff,
  HDR threshold, glow spread, aspect ratio, chromatic aberration, tint, downsample quality.

## 3. Map data we can use legally in MotionAI

| Source | Use | Terms |
|---|---|---|
| Natural Earth vectors + rasters | Country shapes, relief shading | Public domain. India point-of-view borders already bundled. |
| NASA Blue Marble Next Generation | Satellite-colour Earth (21600 × 10800) | Free; credit "NASA Earth Observatory". |
| OpenStreetMap tiles (tile.openstreetmap.org) | Street-level reference | Data free (credit OSM contributors); the public tile server is donation-funded, heavy use forbidden. Use only for light previews, or bring your own tile server. |
| CARTO Positron / Dark Matter / Voyager | Clean light / dark basemaps | Needs a free API key; commercial use free to 1 M tile requests a month; CARTO + OSM attribution must stay visible. |
| MapTiler / Mapbox | Full styled basemaps, terrain, buildings | Paid / keyed; what GEOlayers itself uses for commercial data. |

Rule for MotionAI: offline styles are built from public-domain data inside the app; online tiles
are opt-in, use the user's own key or template URL, cache tiles, and always add the provider's
attribution line. **India is always drawn with India's official boundary** (Natural Earth India
point-of-view data).

## 4. Gap analysis: MotionAI before win-40

| Capability | Before | win-40 |
|---|---|---|
| Live map that re-projects while the camera flies | No (static plates + shape outlines) | **Geo layer**: live vector map, animatable centre / zoom / progress |
| Projections | Equirectangular only | Equirectangular, Mercator, Natural Earth, Orthographic globe |
| Map styles | Satellite plate + a few colours | 12 premium presets (dark political, satellite relief, paper vintage, blueprint, neon, clean light, newsprint ink, documentary gold, night lights, hologram, clay, military ops) |
| 3D country look | Flat fill | Extruded "slab" with side shading, inner glow, glow border, drop shadow |
| Routes | Shape path arrows | Great-circle routes, draw-on progress, glow, dash, arrowheads, arc height on globes |
| Globe | No | Orthographic globe with atmosphere rim, terminator shading, spin |
| Camera | Two-node only, zoom px | One-node / two-node, lens presets in mm, focus linked to POI, blur level |
| Viewer | One view | 1 / 2 / 4 / 1+3 view layouts, orthographic Front / Top / Left / Right / Back / Bottom + 3 orbit custom views, camera frustum + POI gizmo, ground grid |
| Glow | Gaussian glow, bloom | **Deep Glow**: multi-scale falloff, threshold, tint, aspect ratio, chromatic aberration |

## 5. Roadmap after win-40
1. Online tile maps (user key / template URL, cache, attribution), streets / city zoom.
2. Real elevation 3D terrain mesh (DEM → displaced grid) and building extrusion from OSM.
3. Lights (spot / point / parallel) with cast shadows on 3D layers.
4. GeoJSON / CSV import with data-driven choropleth styles.
5. Label templates (any comp as a label), multi-language names.

## Sources
- GEOlayers 3 product page and feature list: https://aescripts.com/geolayers/
- GEOlayers globe sample project: https://aescripts.com/learn/working-with-the-globe-sample-project-in-geolayers-3
- MapTiler for GEOlayers: https://docs.maptiler.com/guides/maps-apis/maps-platform/maptiler-cloud-maps-for-adobe-after-effects-via-geolayers-3-plugin/
- Adobe: Cameras, lights and points of interest: https://helpx.adobe.com/after-effects/using/cameras-lights-points-interest.html
- Adobe: Modifying and using views: https://helpx.adobe.com/in/after-effects/using/modifying-using-views.html
- Adobe community: 3D view layout defaults: https://community.adobe.com/t5/after-effects-beta-discussions/feedback-request-changes-to-3d-view-settings-for-new-comps/m-p/12216674
- Adobe: Advanced 3D renderer: https://helpx.adobe.com/after-effects/using/advanced-3d-renderer.html
- School of Motion: one-node vs two-node cameras: https://schoolofmotion.com/blog/cameras-after-effects
- Deep Glow: https://aescripts.com/deep-glow/
- OSM tile usage policy: https://operations.osmfoundation.org/policies/tiles/
- OSM licence FAQ: https://osmfoundation.org/wiki/Licence_and_Legal_FAQ
- CARTO basemaps FAQ / terms: https://docs.carto.com/faqs/carto-basemaps
- NASA Blue Marble Next Generation: https://science.nasa.gov/earth/earth-observatory/blue-marble-next-generation/
