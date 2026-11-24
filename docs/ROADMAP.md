# Roadmap

## Milestone 1 — core editor (this build)
Data model, keyframes, 2D/3D camera, parallax rig, timeline, preview,
4 effects, undo/redo, JSON edit commands. Preview renders on the GPU
through Flutter (Impeller).

## V2 — done
AI assistant, captions, MP4 export (Android), 3D photo cut-out, text animators, transitions, looks, masks, audio layers, graph editor.

## V3 — native render engine
(previously milestone 2; export now works via Flutter rendering + MediaCodec, the GPU engine makes it faster and adds the items below)
Why it's separate: a frame-exact export needs frame-accurate decoding and
GPU compositing that Flutter widgets and `video_player` can't provide.

- C++ core shared by Android and iOS (Vulkan / Metal), called from Dart via FFI
- The engine consumes the same project JSON and `Evaluator` logic (ported to C++)
- Hardware decode (MediaCodec / AVFoundation) with frame-exact seeking
- Export H.264 / HEVC up to 4K60, transparent PNG sequence, platform presets
- Proxy generation for smooth 4K editing
- Blend modes, motion blur, the full effects list (glow, light leaks, grain,
  chromatic aberration, displacement, particles, transitions)

## Milestone 3 — audio + text + masks
- Audio tracks, waveform, keyframed volume, voiceover recording, beat detection
- Auto-captions (Hindi, Hinglish, Devanagari, English) with word highlighting
- Text animators (per character / word / line), 3D extruded text
- Shape and bezier masks, chroma key, AI subject cut-out, motion tracking, stabilization
- Nested compositions (pre-comps)

## Milestone 4 — AI agent
- On-device analysis: shot detection, transcription, objects/faces,
  quality flags, depth maps (one-tap photo parallax from a single image)
- Script-to-edit: script + style prompt → batch of edit commands
- Chat with the edit, before/after preview, accept / reject per change
- Model connection:
  - "Sign in with ChatGPT" (needs OpenAI partner approval; apply early)
  - Bring-your-own API key (Anthropic or OpenAI)
  - Note: Claude Pro/Max subscriptions cannot be used by third-party apps
    under Anthropic's terms, so Claude goes through an API key
