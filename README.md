# MotionAI

**Install on your phone:** open the latest build on the
[Releases page](https://github.com/mohitbansaldev/motionai/releases) and
download `MotionAI.apk`. Every push to `main` builds a new APK on GitHub.

## What's new in V2
- **AI edit assistant** (AI ✨ tab): describe an edit; it edits the timeline. Uses your OpenAI or Claude API key (AI tab → ⚙).
- **Auto captions** (AI tab → Captions): Hindi, Hinglish (Roman), English; word highlight / word pop / plain box. Needs an OpenAI key.
- **Export MP4** (share icon): 720p / 1080p / 4K, audio from clips and music, saved to Gallery → Movies/MotionAI.
- **3D Photo (AI)**: on-device subject cut-out → parallax shot from a single photo.
- **Text animations**, **Animate in/out** transitions, **Looks** (one-tap styles), **masks**, **music/voiceover layers** with volume, new effects (glow, grain, light leak, gradient, letterbox), **custom easing curves** (long-press a keyframe ◆ → Custom curve).

# Milestone 1 (core editor)

A mobile motion-graphics video editor (Flutter, Android + iOS) in the
spirit of After Effects / Alight Motion, built so an AI agent can edit
projects through JSON commands.

## What's in this milestone

| Area | Included |
|---|---|
| Projects | New project presets (16:9, 9:16, 1:1, 4:5, 4K), 24/25/30/60 fps, auto-save, project list |
| Media | Import videos and images (copied into app storage), video playback synced to the timeline |
| Layers | Video, image, text, solid, null; 2D/3D switch, parenting, visibility, lock, rename, duplicate, split, delete, reorder |
| Timeline | Drag to move, drag edges to trim, pinch to zoom, snapping (playhead, clip edges, frames), keyframe diamonds, camera row |
| Keyframes | Every transform property, camera property and effect parameter; Linear, Hold, Ease In/Out, Easy Ease, Bounce, Elastic, Back, custom bezier (via commands) |
| 3D | Real perspective rendering of 3D layers, depth sorting, X/Y/Z rotation, near-plane culling |
| 3D camera | Position, point of interest, zoom, roll, depth of field (aperture + focus distance) |
| 2D camera | Pan, zoom, rotation, camera shake |
| Camera moves | Push In, Pull Out, Orbit, Dolly Zoom, Drone Reveal, Truck, Pedestal, 2D Pan/Zoom/Rotate/Shake |
| Parallax | One-tap parallax rig: spreads layers in depth, auto-compensates scale so frame 1 looks unchanged, then pushes the camera |
| Effects | Gaussian Blur, Color Adjust (brightness/contrast/saturation), Tint, Vignette — all keyframeable |
| Editing | Undo/redo (100 steps), on-canvas drag / pinch-scale / rotate of the selected layer |
| AI-ready | Every edit goes through the JSON command layer (`lib/core/commands`). The **terminal icon** in the editor opens a console where you can paste agent-style commands. See `docs/EDIT_COMMANDS.md` |

**Not in this milestone (on purpose):** video export, audio tracks, and
the AI agent itself. See `docs/ROADMAP.md` for why and when.

## Set up on Windows with Android Studio

1. **Install Flutter** (if you haven't): download the Flutter SDK zip for
   Windows from flutter.dev, extract to `C:\src\flutter`, add
   `C:\src\flutter\bin` to your PATH, then run `flutter doctor` in a new
   terminal and fix anything it reports (Android SDK, licenses:
   `flutter doctor --android-licenses`).
2. In Android Studio install the **Flutter** and **Dart** plugins
   (Settings → Plugins), then restart.
3. Unzip this project, e.g. to `C:\dev\motionai`.
4. Open a terminal in that folder and generate the Android/iOS platform
   folders (this does **not** touch `lib/`):

   ```
   flutter create --org com.mohitflix --project-name motionai --platforms=android,ios .
   flutter pub get
   ```

   `video_player` needs Android API 24+. If the build complains about
   `minSdk`, open `android/app/build.gradle.kts` and set `minSdk = 24`.
5. Run the checks:

   ```
   flutter analyze
   flutter test
   ```

6. Plug in your phone (Developer options → USB debugging on), pick it in
   Android Studio's device menu, open `lib/main.dart` and press **Run**.
   Or from the terminal: `flutter run`.

> This code was written without access to a Flutter toolchain, so the
> first `flutter analyze` is the real compile check. If it reports
> errors, paste the output back to me and I'll fix them.

If `flutter pub get` complains about package versions, run
`flutter pub upgrade --major-versions`.

## Try it in 2 minutes

1. New project → YouTube 16:9.
2. **Add → Image** and pick a landscape photo. Then **Add → Text**.
3. **Add → Parallax** → Create. Press play: the text floats in front of
   the photo as the camera pushes in.
4. **Camera** tab → tap **Orbit** or **Dolly Zoom** at a later playhead time.
5. Select the text → **Layer** tab → tap the ◇ next to *Opacity* at 0 s,
   move the playhead, drag the slider. Long-press the ◆ to change easing.
6. Tap the **terminal icon** and press **Run** on the sample commands.

## Project layout

```
lib/
  core/                  pure Dart, no Flutter imports → reusable by the agent & engine
    model/               Project, Composition, Layer, AnimProp/Keyframe, Easing, Camera, effects catalog
    engine/evaluator.dart  evaluates a frame: transforms, parenting, 3D projection, depth sort, DOF
    presets/             camera moves + parallax rig
    commands/            the JSON edit-command API (atomic batches, agent-friendly errors)
  state/                 EditorController (undo, playback clock), VideoPool (video sync)
  services/              project storage, media import
  ui/                    home, editor, preview, timeline, panels, command console
test/core_test.dart      unit tests for easing, keyframes, 3D math, parallax, commands
docs/                    EDIT_COMMANDS.md, ROADMAP.md
```

## Third-party data
Country outlines: [Natural Earth](https://www.naturalearthdata.com/) (public domain), India point-of-view boundaries, simplified.
