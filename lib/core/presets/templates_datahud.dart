import 'templates.dart';

/// V3-C: one-click templates for the data / HUD overlays (gallery + AI).
List<SceneTemplate> dataHudTemplates() => [
      SceneTemplate(
        id: 'stat_title', name: 'Stat title', category: 'Captions',
        subtitle: 'Small line + big number line (1.6×), red outline or yellow drop',
        duration: 4, previewTime: 1.6, needsComponents: const ['stat_title'],
        slots: const [
          TemplateSlot('line1', 'Line 1', initial: 'HE SURVIVED'),
          TemplateSlot('line2', 'Number line', initial: '72 DAYS'),
          TemplateSlot('style', 'Style (red_outline / yellow / white)', initial: 'red_outline'),
        ],
        builder: (c) => [
          {
            'op': 'add_component', 'type': 'stat_title', 'id': 'stat', 'start': c.t(0), 'duration': 4,
            'line1': c.s('line1', 'HE SURVIVED'), 'line2': c.s('line2', '72 DAYS'), 'style': c.s('style', 'red_outline'),
          },
        ],
      ),
      SceneTemplate(
        id: 'date_stamp', name: 'Date / time stamp', category: 'Lower thirds',
        subtitle: 'Italic digital date typed bottom-left, blinking colon',
        duration: 4, previewTime: 2.0, needsComponents: const ['clock_stamp'],
        slots: const [
          TemplateSlot('line1', 'Line 1', initial: 'DAY 61'),
          TemplateSlot('line2', 'Line 2', initial: '12 DEC 1972'),
          TemplateSlot('line3', 'Line 3', initial: '03:21 PM'),
        ],
        builder: (c) => [
          {
            'op': 'add_component', 'type': 'clock_stamp', 'id': 'stamp', 'start': c.t(0), 'duration': 4,
            'lines': [for (final k in ['line1', 'line2', 'line3']) if (c.s(k).trim().isNotEmpty) c.s(k)],
          },
        ],
      ),
      SceneTemplate(
        id: 'day_counter', name: 'Calendar day counter', category: 'Showcases',
        subtitle: '3D tear-off calendar flipping through the days',
        duration: 5, previewTime: 2.5, needsComponents: const ['calendar_flip'],
        slots: const [
          TemplateSlot('to', 'Last day', initial: '72'),
          TemplateSlot('caption', 'Caption', initial: 'DAYS IN THE ANDES'),
          TemplateSlot('bg', 'Background', kind: 'color', initial: '#10161F'),
        ],
        builder: (c) => [
          c.rect('bg', c.w, c.h, c.w / 2, c.h / 2, c.s('bg', '#10161F'), fill2: '#05070A', du: 5, name: 'Background'),
          {'op': 'add_effect', 'layer': 'bg', 'effect': 'vignette', 'params': {'amount': 65}},
          {
            'op': 'add_component', 'type': 'calendar_flip', 'id': 'cal', 'start': c.t(0), 'duration': 5,
            'from': 1, 'to': c.n('to', 72).round(), 'rate': 14, 'caption': c.s('caption'),
          },
        ],
      ),
      SceneTemplate(
        id: 'passenger_tally', name: 'Unit chart tally', category: 'Showcases',
        subtitle: 'Pictograms pop row by row, coloured groups labelled at the left',
        duration: 6, previewTime: 3.0, needsComponents: const ['unit_chart'],
        slots: const [
          TemplateSlot('label', 'Total label', initial: '45 PASSENGERS'),
          TemplateSlot('a', 'Group 1 label', initial: 'DIED IN THE CRASH'),
          TemplateSlot('b', 'Group 2 label', initial: 'SURVIVED'),
        ],
        builder: (c) => [
          {
            'op': 'add_component', 'type': 'unit_chart', 'id': 'units', 'start': c.t(0), 'duration': 6, 'total_label': c.s('label', '45 PASSENGERS'),
            'groups': [
              {'count': 29, 'color': '#9E9E9E', 'label': c.s('a', 'DIED IN THE CRASH')},
              {'count': 16, 'color': '#E53935', 'label': c.s('b', 'SURVIVED')},
            ],
          },
        ],
      ),
      SceneTemplate(
        id: 'social_bug', name: 'Social bug', category: 'Endings',
        subtitle: 'Platform icon + "JOIN US ON" swoosh, breaks into pixels',
        duration: 3.5, previewTime: 1.2, needsComponents: const ['social_bug'],
        slots: const [
          TemplateSlot('platform', 'Platform (youtube, whatsapp, instagram…)', initial: 'youtube'),
          TemplateSlot('handle', 'Handle', initial: 'Mohitflix'),
        ],
        builder: (c) => [
          {'op': 'add_component', 'type': 'social_bug', 'id': 'bug', 'start': c.t(0), 'platform': c.s('platform', 'youtube'), 'handle': c.s('handle', 'Mohitflix')},
        ],
      ),
    ];
