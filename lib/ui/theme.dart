import 'package:flutter/material.dart';

/// win-43: MotionAI "Obsidian & Gold" design system.
///
/// Deep graphite surfaces with a faint cool tint, one warm champagne-gold
/// accent (primary actions, focus, selection), a cool steel-blue for
/// values and live data, hairline borders, generous rhythm and Inter
/// type with tabular numbers. Every screen reads from these tokens.
class MA {
  // Surfaces (darkest → lightest)
  static const bg = Color(0xFF07080A);
  static const surface = Color(0xFF0F1114);
  static const surface2 = Color(0xFF15181C);
  static const surface3 = Color(0xFF1D2126);
  static const surface4 = Color(0xFF262B31);
  static const stroke = Color(0xFF23272D);
  static const strokeHi = Color(0xFF343A42);

  // Type
  static const text = Color(0xFFEDEDE8);
  static const textDim = Color(0xFF8D939C);
  static const textFaint = Color(0xFF5C626B);

  // Accent: champagne gold
  static const accent = Color(0xFFE2B65D);
  static const accentHi = Color(0xFFF4D592);
  static const accentLo = Color(0xFFB8863A);
  static const onAccent = Color(0xFF1A1206);

  // Secondary: steel blue (values, live data, links)
  static const accent2 = Color(0xFF7FB2E5);
  static const gold = Color(0xFFFFD54F); // keyframes

  // States
  static const success = Color(0xFF5FCB8B);
  static const warning = Color(0xFFF0B44C);
  static const danger = Color(0xFFEF6A6A);

  static const fontFamily = 'Inter';

  static const gradient = LinearGradient(
    colors: [accentHi, accent, accentLo],
    stops: [0, 0.55, 1],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  /// Very subtle top light on panels (glass edge).
  static const panelGradient = LinearGradient(
    colors: [Color(0xFF14171B), Color(0xFF0F1114)],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  static BoxDecoration card({double radius = 14, Color color = surface, bool border = true}) => BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(radius),
        border: border ? Border.all(color: stroke, width: 1) : null,
      );

  /// A workspace panel: gradient body, hairline border, soft depth.
  static BoxDecoration panel({double radius = 12}) => BoxDecoration(
        gradient: panelGradient,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: stroke, width: 1),
        boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 18, offset: Offset(0, 6))],
      );

  static ThemeData theme() {
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.dark,
      primary: accent,
      onPrimary: onAccent,
      secondary: accent2,
      surface: surface,
      onSurface: text,
      error: danger,
    );
    final base = ThemeData(colorScheme: scheme, useMaterial3: true, brightness: Brightness.dark, fontFamily: fontFamily);
    final rounded10 = RoundedRectangleBorder(borderRadius: BorderRadius.circular(10));
    return base.copyWith(
      scaffoldBackgroundColor: bg,
      visualDensity: VisualDensity.compact,
      splashFactory: InkSparkle.splashFactory,
      appBarTheme: const AppBarTheme(
        backgroundColor: bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        toolbarHeight: 52,
        titleTextStyle: TextStyle(fontFamily: fontFamily, fontSize: 15, fontWeight: FontWeight.w700, color: text, letterSpacing: 0.1),
      ),
      textTheme: base.textTheme.apply(bodyColor: text, displayColor: text, fontFamily: fontFamily),
      iconTheme: const IconThemeData(color: textDim, size: 20),
      dividerColor: stroke,
      dividerTheme: const DividerThemeData(color: stroke, thickness: 1, space: 1),
      cardTheme: const CardThemeData(color: surface2, elevation: 0, margin: EdgeInsets.zero),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: surface2,
        selectedColor: accent.withValues(alpha: 0.22),
        side: const BorderSide(color: stroke),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        labelStyle: const TextStyle(fontFamily: fontFamily, fontSize: 12, color: text),
        checkmarkColor: accent,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: onAccent,
          disabledBackgroundColor: surface3,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          shape: rounded10,
          textStyle: const TextStyle(fontFamily: fontFamily, fontWeight: FontWeight.w700, letterSpacing: 0.2),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: text,
          side: const BorderSide(color: strokeHi),
          shape: rounded10,
          textStyle: const TextStyle(fontFamily: fontFamily, fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: accent, shape: rounded10, textStyle: const TextStyle(fontFamily: fontFamily, fontWeight: FontWeight.w600)),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: textDim, hoverColor: const Color(0x14FFFFFF), shape: rounded10),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface2,
        isDense: true,
        hintStyle: const TextStyle(color: textFaint),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: stroke)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: stroke)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: accent, width: 1.4)),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: accent,
        inactiveTrackColor: surface4,
        thumbColor: accentHi,
        overlayColor: accent.withValues(alpha: 0.16),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6, elevation: 2),
        trackHeight: 2.5,
        valueIndicatorColor: surface4,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? onAccent : textDim),
        trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? accent : surface4),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? accent : Colors.transparent),
        checkColor: const WidgetStatePropertyAll(onAccent),
        side: const BorderSide(color: strokeHi, width: 1.4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
      radioTheme: RadioThemeData(fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? accent : textDim)),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: accent, linearTrackColor: surface3, circularTrackColor: Colors.transparent),
      tabBarTheme: const TabBarThemeData(
        labelColor: text,
        unselectedLabelColor: textDim,
        indicatorColor: accent,
        dividerColor: Colors.transparent,
        labelStyle: TextStyle(fontFamily: fontFamily, fontSize: 12, fontWeight: FontWeight.w700),
        unselectedLabelStyle: TextStyle(fontFamily: fontFamily, fontSize: 12, fontWeight: FontWeight.w500),
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 450),
        decoration: BoxDecoration(color: surface4, borderRadius: BorderRadius.circular(6), border: Border.all(color: strokeHi)),
        textStyle: const TextStyle(fontFamily: fontFamily, fontSize: 11.5, color: text),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: surface2,
        surfaceTintColor: Colors.transparent,
        elevation: 12,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: const BorderSide(color: stroke)),
        textStyle: const TextStyle(fontFamily: fontFamily, fontSize: 13, color: text),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: const WidgetStatePropertyAll(surface2),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: const BorderSide(color: stroke))),
        ),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.hovered) || s.contains(WidgetState.dragged) ? strokeHi : surface4),
        thickness: const WidgetStatePropertyAll(6),
        radius: const Radius.circular(3),
        crossAxisMargin: 2,
      ),
      listTileTheme: const ListTileThemeData(iconColor: textDim, dense: true, contentPadding: EdgeInsets.symmetric(horizontal: 12)),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        dragHandleColor: strokeHi,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface2,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: stroke)),
        titleTextStyle: const TextStyle(fontFamily: fontFamily, fontSize: 16, fontWeight: FontWeight.w700, color: text),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: surface4,
        contentTextStyle: const TextStyle(fontFamily: fontFamily, color: text),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: const BorderSide(color: strokeHi)),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(9))),
          side: const WidgetStatePropertyAll(BorderSide(color: stroke)),
          backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? accent.withValues(alpha: 0.18) : surface2),
          foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? accentHi : textDim),
          textStyle: const WidgetStatePropertyAll(TextStyle(fontFamily: fontFamily, fontSize: 12, fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }
}

/// Gold pill button used for primary actions (Export, Create).
class GradientButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final EdgeInsets padding;
  const GradientButton({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: onTap == null ? 0.5 : 1,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: MA.gradient,
          borderRadius: BorderRadius.circular(10),
          boxShadow: [BoxShadow(color: MA.accent.withValues(alpha: 0.28), blurRadius: 14, offset: const Offset(0, 3))],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onTap,
            child: Padding(
              padding: padding,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (icon != null) ...[Icon(icon, size: 17, color: MA.onAccent), const SizedBox(width: 6)],
                Text(label, style: const TextStyle(color: MA.onAccent, fontWeight: FontWeight.w800, letterSpacing: 0.2)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
