# MotionAI V2 — "Claude-controlled documentary editor"

Integration branch: `integ/v2` (from `integ/v1` @ 023276e). Each helper works on its own
`feat/v2-*` branch from `integ/v2`, pushes it (Check branch CI = analyze + tests) and the
lead merges into `integ/v2`. Windows builds publish `win-N` from `integ/v2`.

## Workstreams and file ownership

| Helper | Branch | Owns (new files preferred) |
|---|---|---|
| A Bridge | feat/v2-bridge | lib/remote/** , docs/CLAUDE_CONTROL.md |
| B Shots & sequences | feat/v2-shots | lib/core/commands/shot_commands.dart, lib/core/presets/shots.dart, default layer duration |
| C Documentary transitions | feat/v2-transitions | lib/core/presets/doc_transitions.dart, lib/core/commands/transition_commands.dart |
| D Realism | feat/v2-realism | lib/core/presets/realism.dart, lib/ui/preview/fx/realism_painters.dart, blur-on-3D fix |
| E Depth from photo | feat/v2-depth | lib/platform/windows_ai/depth.dart, lib/core/commands/depth_commands.dart |
| F Asset pipeline | feat/v2-assets | lib/library/** import/clean, Devanagari scramble fix (lib/ui/preview/fx/text_fx.dart) |

Shared files (edit only inside your own marked block `// V2-X >>>` … `// <<< V2-X`):
`lib/core/commands/edit_commands.dart` (dispatcher), `lib/ai/command_spec.dart` (append your
section), `lib/core/effects_catalog.dart`, `lib/remote/remote_tools.dart` (A owns; others ask A
via run_commands ops instead of new tools).

## Bugs found while testing win-24 via MCP (25 Nov)
1. Blur effect on a 3D layer makes the layer invisible (D).
2. `scramble` text animator breaks Devanagari conjuncts ("राजस्थान" → "ज  न") (F).
3. New layers default to 5 s, so 3D sets go black mid-shot; layers added without `start`
   start at the playhead (B: default to comp duration / shot span; spec must say so).
4. "Add to Claude Desktop" didn't make tools appear (Claude Desktop reported no local MCP
   servers) — check config path (MSIX package path) and server start (A).
