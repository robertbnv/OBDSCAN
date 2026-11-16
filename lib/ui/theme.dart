import 'package:material_ui/material_ui.dart';

import '../monitor/agent.dart';

const Color kBackground = Color(0xFF0D1117);
const Color kSurface = Color(0xFF161B22);
const Color kSurfaceHigh = Color(0xFF212934);
const Color kOutline = Color(0xFF2A3340);
const Color kAccent = Color(0xFF2DD4BF);
const Color kWarn = Color(0xFFF5A524);
const Color kCritical = Color(0xFFF2555A);
const Color kOk = Color(0xFF3FB950);
const Color kMuted = Color(0xFF8B949E);
const Color kText = Color(0xFFE6EDF3);

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: kAccent, brightness: Brightness.dark).copyWith(
    primary: kAccent,
    onPrimary: const Color(0xFF04201C),
    surface: kBackground,
    onSurface: kText,
    onSurfaceVariant: kMuted,
    surfaceContainer: kSurface,
    surfaceContainerHigh: kSurfaceHigh,
    surfaceContainerHighest: kSurfaceHigh,
    outline: kOutline,
    outlineVariant: kOutline,
    error: kCritical,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: kBackground,
    appBarTheme: const AppBarTheme(
      backgroundColor: kBackground,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      titleTextStyle: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: kText),
    ),
    cardTheme: CardThemeData(
      color: kSurface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: kOutline),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: kSurface,
      indicatorColor: kAccent.withValues(alpha: 0.18),
      surfaceTintColor: Colors.transparent,
      height: 68,
    ),
    dividerTheme: const DividerThemeData(color: kOutline, space: 1, thickness: 1),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: kSurfaceHigh,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      isDense: true,
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

Color severityColor(Severity severity) => switch (severity) {
  Severity.critical => kCritical,
  Severity.warning => kWarn,
  Severity.info => kAccent,
};

IconData severityIcon(Severity severity) => switch (severity) {
  Severity.critical => Icons.error_rounded,
  Severity.warning => Icons.warning_amber_rounded,
  Severity.info => Icons.info_outline_rounded,
};

/// Numbers that change many times per second must not jiggle sideways.
const List<FontFeature> kTabularFigures = [FontFeature.tabularFigures()];

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title.toUpperCase(),
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.1, color: kMuted),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
