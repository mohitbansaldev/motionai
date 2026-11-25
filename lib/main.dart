import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/presets/world_map.dart';
import 'ui/home_screen.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: MA.bg,
  ));
  // Country outlines for the map kit (loaded in the background).
  rootBundle.loadString('assets/world_countries.json').then(WorldMap.load).catchError((_) {});
  runApp(const MotionAIApp());
}

class MotionAIApp extends StatelessWidget {
  const MotionAIApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MotionAI',
      debugShowCheckedModeBanner: false,
      theme: MA.theme(),
      // Mouse and trackpad can drag horizontal lists on the PC too.
      scrollBehavior: const _AllPointersScroll(),
      home: const HomeScreen(),
    );
  }
}

class _AllPointersScroll extends MaterialScrollBehavior {
  const _AllPointersScroll();

  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
        PointerDeviceKind.invertedStylus,
      };
}
