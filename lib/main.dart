import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/presets/world_map.dart';
import 'remote/remote_control.dart'; // MCP (Agent P)
import 'remote/remote_ui.dart'; // MCP (Agent P)
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
  RemoteControl.instance.init().catchError((_) {}); // MCP (Agent P): Claude control server (if enabled)
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
      navigatorKey: RemoteControl.instance.navigatorKey, // MCP (Agent P)
      builder: (context, child) => RemoteBadge(child: child ?? const SizedBox.shrink()), // MCP (Agent P): "Claude connected"
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
