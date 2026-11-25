import 'dart:ui' show PlatformDispatcher, PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/presets/world_map.dart';
import 'services/app_log.dart';
import 'services/memory_guard.dart'; // win-30
import 'remote/remote_control.dart'; // MCP (Agent P)
import 'remote/remote_ui.dart'; // MCP (Agent P)
import 'ui/depth_tools.dart'; // V2-E
import 'ui/home_screen.dart';
import 'ui/theme.dart';
import 'core/presets/doc_transitions.dart'; // V2-lead
import 'core/presets/transition_registry.dart'; // V2-lead
import 'ui/preview/fx/map_texture.dart'; // V3-A

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // win-30: keep errors for MCP get_logs (and still show them as before).
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    AppLog.error('flutter', '${details.exceptionAsString()}\n${details.stack.toString().split('\n').take(8).join('\n')}');
    previous?.call(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    AppLog.error('async', '$error\n${stack.toString().split('\n').take(8).join('\n')}');
    return false; // keep the default handling
  };
  MemoryGuard.install(); // win-30: image cache cap + trim when RAM grows
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: MA.bg,
  ));
  // Country outlines for the map kit (loaded in the background).
  rootBundle.loadString('assets/world_countries.json').then(WorldMap.load).catchError((_) {});
  MapTexture.load(); // V3-A: satellite map texture (maps fall back to the dark style without it)
  RemoteControl.instance.init().catchError((_) {}); // MCP (Agent P): Claude control server (if enabled)
  DepthTools.install(); // V2-E: photo_to_3d / depth_map background jobs
  TransitionRegistry.addRegistrar(DocTransitions.registerAll); // V2-lead: documentary transitions for sequence
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
