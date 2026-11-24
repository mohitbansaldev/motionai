import 'anim_prop.dart';

/// off  = no camera; 3D layers still use a fixed default perspective.
/// twoD = screen-space camera (pan / zoom / rotate / shake) over everything.
/// threeD = real perspective camera in 3D space (After Effects style).
enum CameraMode { off, twoD, threeD }

CameraMode cameraModeFromName(String name) {
  final n = name.replaceAll('_', '').toLowerCase();
  if (n == '2d' || n == 'twod') return CameraMode.twoD;
  if (n == '3d' || n == 'threed') return CameraMode.threeD;
  if (n == 'off' || n == 'none') return CameraMode.off;
  throw FormatException('Unknown camera mode "$name"');
}

class CamProps {
  // 2D camera
  static const pan = 'pan'; // [x, y] comp point at the screen center
  static const zoom2d = 'zoom2d'; // [%]
  static const rotation2d = 'rotation2d'; // [°]
  static const shake = 'shake'; // [amplitude px]
  static const shakeSpeed = 'shakeSpeed'; // [Hz-ish]

  // 3D camera
  static const position = 'position'; // [x, y, z]
  static const poi = 'poi'; // point of interest [x, y, z]
  static const zoom = 'zoom'; // focal distance in pixels (AE "Zoom")
  static const roll = 'roll'; // [°] rotation around view axis
  static const focus = 'focus'; // focus distance (px) for depth of field
  static const aperture = 'aperture'; // blur strength; 0 = depth of field off

  static const twoDProps = [pan, zoom2d, rotation2d, shake, shakeSpeed];
  static const threeDProps = [position, poi, zoom, roll, focus, aperture];
}

/// Default AE-like zoom for a comp width (≈ 50mm lens, 39.6° horizontal FOV).
double defaultZoomFor(double compWidth) => compWidth * 1.38889;

class CameraRig {
  CameraMode mode;
  final Map<String, AnimProp> props;

  CameraRig({this.mode = CameraMode.off, Map<String, AnimProp>? props}) : props = props ?? {};

  factory CameraRig.defaults(double w, double h) {
    final r = CameraRig();
    r.ensureDefaults(w, h);
    return r;
  }

  void ensureDefaults(double w, double h) {
    final z = defaultZoomFor(w);
    props.putIfAbsent(CamProps.pan, () => AnimProp([w / 2, h / 2]));
    props.putIfAbsent(CamProps.zoom2d, () => AnimProp([100]));
    props.putIfAbsent(CamProps.rotation2d, () => AnimProp([0]));
    props.putIfAbsent(CamProps.shake, () => AnimProp([0]));
    props.putIfAbsent(CamProps.shakeSpeed, () => AnimProp([2]));
    props.putIfAbsent(CamProps.position, () => AnimProp([w / 2, h / 2, -z]));
    props.putIfAbsent(CamProps.poi, () => AnimProp([w / 2, h / 2, 0]));
    props.putIfAbsent(CamProps.zoom, () => AnimProp([z]));
    props.putIfAbsent(CamProps.roll, () => AnimProp([0]));
    props.putIfAbsent(CamProps.focus, () => AnimProp([z]));
    props.putIfAbsent(CamProps.aperture, () => AnimProp([0]));
  }

  AnimProp prop(String key) {
    final p = props[key];
    if (p == null) throw ArgumentError('Camera has no property "$key"');
    return p;
  }

  List<double> allKeyframeTimes() {
    final s = <double>{};
    for (final p in props.values) {
      for (final k in p.keyframes) {
        s.add(k.time);
      }
    }
    return s.toList()..sort();
  }

  CameraRig copy() => CameraRig(mode: mode, props: props.map((k, v) => MapEntry(k, v.copy())));

  Map<String, dynamic> toJson() => {
        'mode': mode.name,
        'props': props.map((k, v) => MapEntry(k, v.toJson())),
      };

  static CameraRig fromJson(Map<String, dynamic> j) => CameraRig(
        mode: CameraMode.values.firstWhere((m) => m.name == j['mode'], orElse: () => CameraMode.off),
        props: (j['props'] as Map<String, dynamic>? ?? {})
            .map((k, v) => MapEntry(k, AnimProp.fromJson(v as Map<String, dynamic>))),
      );
}
