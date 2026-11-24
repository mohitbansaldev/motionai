/// Starter templates: ready-made animated scenes built only from edit
/// commands, so they work without any media and stay fully editable.
class ProjectTemplate {
  final String id;
  final String name;
  final String subtitle;
  final double width, height;
  final double duration;
  final List<Map<String, dynamic>> Function(double w, double h) commands;
  const ProjectTemplate(this.id, this.name, this.subtitle, this.width, this.height, this.duration, this.commands);
}

class Templates {
  static final all = <ProjectTemplate>[
    ProjectTemplate('doc_intro', 'Documentary Intro', 'Cinematic 3D title, slow push', 1920, 1080, 7, (w, h) => [
          {'op': 'add_layer', 'type': 'solid', 'id': 'bg', 'name': 'Background', 'color': '#0E1420', 'is3d': true, 'width': w * 1.6, 'height': h * 1.6},
          {'op': 'add_effect', 'layer': 'bg', 'effect': 'light_leak', 'params': {'amount': 35, 'speed': 0.6}},
          {'op': 'add_effect', 'layer': 'bg', 'effect': 'grain', 'params': {'amount': 22}},
          {'op': 'add_effect', 'layer': 'bg', 'effect': 'vignette', 'params': {'amount': 70}},
          {'op': 'add_layer', 'type': 'text', 'id': 'title', 'text': 'THE FORGOTTEN FORT', 'font_size': 140, 'font_weight': 900, 'is3d': true, 'animator': 'fade_up', 'anim_duration': 1.6, 'start': 0.4, 'duration': 6.6},
          {'op': 'add_layer', 'type': 'text', 'id': 'sub', 'text': 'A documentary', 'font_size': 54, 'font_weight': 400, 'is3d': true, 'position': [w / 2, h / 2 + 130, 0], 'animator': 'typewriter', 'anim_duration': 1.2, 'start': 1.6, 'duration': 5.4, 'text_color': '#C9D1E0'},
          {'op': 'parallax_rig', 'layers': ['bg', 'sub', 'title'], 'depth': 450, 'push': 380, 'start': 0, 'duration': 7},
          {'op': 'animate_out', 'layer': 'title', 'preset': 'blur', 'duration': 0.8},
          {'op': 'animate_out', 'layer': 'sub', 'preset': 'fade', 'duration': 0.8},
        ]),
    ProjectTemplate('shorts_hook', 'Shorts Hook', 'Punchy 9:16 opener with shake', 1080, 1920, 4, (w, h) => [
          {'op': 'add_layer', 'type': 'solid', 'id': 'bg', 'name': 'Background', 'color': '#1B0F3A'},
          {'op': 'add_effect', 'layer': 'bg', 'effect': 'light_leak', 'params': {'amount': 60, 'speed': 2}},
          {'op': 'add_effect', 'layer': 'bg', 'effect': 'gradient', 'params': {'amount': 50, 'top': 30}},
          {'op': 'add_layer', 'type': 'text', 'id': 'hook', 'text': 'YOU WON\'T BELIEVE THIS', 'font_size': 130, 'font_weight': 900, 'width': w * 0.9, 'height': 600, 'animator': 'word_pop', 'anim_duration': 0.9, 'highlight_color': '#FFD54F'},
          {'op': 'add_layer', 'type': 'text', 'id': 'cta', 'text': 'watch till the end', 'font_size': 56, 'box_color': '#CC000000', 'position': [w / 2, h * 0.72, 0], 'start': 1.2, 'duration': 2.8, 'animator': 'slide_up', 'anim_duration': 0.4},
          {'op': 'camera_move', 'preset': 'zoom_in_2d', 'start': 0, 'duration': 4, 'amount': 12},
          {'op': 'camera_move', 'preset': 'shake', 'start': 0.9, 'duration': 0.5, 'amount': 14},
        ]),
    ProjectTemplate('quote', 'Quote Card', 'Typewriter quote, warm grain', 1080, 1080, 6, (w, h) => [
          {'op': 'add_layer', 'type': 'solid', 'id': 'bg', 'name': 'Background', 'color': '#2A1E14'},
          {'op': 'add_effect', 'layer': 'bg', 'effect': 'grain', 'params': {'amount': 35}},
          {'op': 'add_effect', 'layer': 'bg', 'effect': 'vignette', 'params': {'amount': 65}},
          {'op': 'add_layer', 'type': 'text', 'id': 'q', 'text': '"History is not the past. It is the present."', 'font_size': 72, 'font_weight': 600, 'width': w * 0.82, 'height': 500, 'animator': 'typewriter', 'anim_duration': 2.5, 'text_color': '#F6E7CF'},
          {'op': 'add_layer', 'type': 'text', 'id': 'a', 'text': '— Your Name', 'font_size': 44, 'position': [w / 2, h * 0.78, 0], 'start': 2.6, 'duration': 3.4, 'animator': 'fade_up', 'anim_duration': 0.8, 'text_color': '#D9B98C'},
          {'op': 'camera_move', 'preset': 'zoom_in_2d', 'start': 0, 'duration': 6, 'amount': 6},
        ]),
    ProjectTemplate('title_3d', '3D Title Orbit', 'Title floating in 3D space', 1920, 1080, 6, (w, h) => [
          {'op': 'add_layer', 'type': 'solid', 'id': 'bg', 'name': 'Background', 'color': '#06080D'},
          {'op': 'add_effect', 'layer': 'bg', 'effect': 'light_leak', 'params': {'amount': 25, 'speed': 1}},
          {'op': 'add_layer', 'type': 'text', 'id': 't', 'text': 'MOTION AI', 'font_size': 220, 'font_weight': 900, 'is3d': true, 'animator': 'word_pop', 'anim_duration': 0.8},
          {'op': 'add_effect', 'layer': 't', 'effect': 'glow', 'params': {'amount': 55, 'radius': 24}},
          {'op': 'add_layer', 'type': 'text', 'id': 't2', 'text': 'create anything', 'font_size': 60, 'is3d': true, 'position': [w / 2, h / 2 + 170, -200], 'start': 0.8, 'duration': 5.2, 'animator': 'fade_up', 'text_color': '#3DD6E0'},
          {'op': 'camera_move', 'preset': 'orbit', 'start': 0, 'duration': 6, 'amount': 28},
        ]),
  ];
}
