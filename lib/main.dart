import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ui/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const MotionAIApp());
}

class MotionAIApp extends StatelessWidget {
  const MotionAIApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF4FC3F7), brightness: Brightness.dark);
    return MaterialApp(
      title: 'MotionAI',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF101215),
        appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF16181C), elevation: 0),
        sliderTheme: const SliderThemeData(thumbShape: RoundSliderThumbShape(enabledThumbRadius: 7)),
      ),
      home: const HomeScreen(),
    );
  }
}
