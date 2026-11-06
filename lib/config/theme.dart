import 'package:flutter/material.dart';

/// 应用界面的统一圆角；文档正文与画布内容保留原始几何。
class AppRadii {
  AppRadii._();
  static const double control = 16;
  static const double card = 24;
  static const double overlay = 28;
}

/// 简约的柔和表面：用留白区分层级，减少描边，浅深色共用形状。
class AppTheme {
  AppTheme._();
  static const Color seedColor = Color(0xFF1B5E5E);
  static const Color paperWhite = Color(0xFFF5F7F8);

  static ThemeData light({Color? seed}) => _build(Brightness.light, seed);
  static ThemeData dark({Color? seed}) => _build(Brightness.dark, seed);

  static ThemeData _build(Brightness brightness, Color? seed) {
    final dark = brightness == Brightness.dark;
    final colors = ColorScheme.fromSeed(
      seedColor: seed ?? seedColor,
      brightness: brightness,
      surface: dark ? const Color(0xFF1B2223) : Colors.white,
    );
    final background = dark ? const Color(0xFF111718) : paperWhite;
    const control = RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(AppRadii.control)),
    );
    const card = RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(AppRadii.card)),
    );
    const overlay = RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(AppRadii.overlay)),
    );
    final input = OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadii.control),
      borderSide: BorderSide.none,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colors,
      scaffoldBackgroundColor: background,
      splashFactory: InkSparkle.splashFactory,
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.android: _SoftPageTransitionsBuilder(),
        TargetPlatform.iOS: _SoftPageTransitionsBuilder(),
        TargetPlatform.windows: _SoftPageTransitionsBuilder(),
        TargetPlatform.macOS: _SoftPageTransitionsBuilder(),
        TargetPlatform.linux: _SoftPageTransitionsBuilder(),
      }),
      appBarTheme: AppBarTheme(
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: background,
        foregroundColor: colors.onSurface,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: colors.onSurface,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: colors.surface,
        shape: card,
        surfaceTintColor: Colors.transparent,
        clipBehavior: Clip.antiAlias,
        margin: const EdgeInsets.only(bottom: 12),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? colors.surfaceContainerHigh : const Color(0xFFF0F3F4),
        border: input,
        enabledBorder: input,
        disabledBorder: input,
        focusedBorder: input.copyWith(
          borderSide: BorderSide(color: colors.primary, width: 1.4),
        ),
        errorBorder:
            input.copyWith(borderSide: BorderSide(color: colors.error)),
        focusedErrorBorder: input.copyWith(
          borderSide: BorderSide(color: colors.error, width: 1.4),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        hintStyle: TextStyle(color: colors.onSurfaceVariant),
      ),
      filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
        minimumSize: const Size(64, 48),
        shape: control,
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      )),
      elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
        minimumSize: const Size(64, 48),
        shape: control,
        elevation: 0,
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      )),
      outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 44),
        shape: control,
        side: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.6)),
      )),
      textButtonTheme:
          TextButtonThemeData(style: TextButton.styleFrom(shape: control)),
      iconButtonTheme:
          IconButtonThemeData(style: IconButton.styleFrom(shape: control)),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        elevation: 2,
        highlightElevation: 3,
        shape: card,
        backgroundColor: colors.primaryContainer,
        foregroundColor: colors.onPrimaryContainer,
      ),
      chipTheme: ChipThemeData(
        shape: const StadiumBorder(),
        side: BorderSide.none,
        backgroundColor: colors.surfaceContainerLow,
        selectedColor: colors.secondaryContainer,
        labelStyle: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
        shape: overlay,
        elevation: 4,
        titleTextStyle: TextStyle(
            fontSize: 19, fontWeight: FontWeight.w600, color: colors.onSurface),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
        clipBehavior: Clip.antiAlias,
        shape: const RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(AppRadii.overlay)),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        shape: control,
        color: colors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 3,
      ),
      menuTheme: MenuThemeData(
          style: MenuStyle(
        shape: const WidgetStatePropertyAll(control),
        backgroundColor: WidgetStatePropertyAll(colors.surface),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      )),
      drawerTheme: DrawerThemeData(
        backgroundColor: colors.surface,
        shape: overlay,
        endShape: overlay,
        surfaceTintColor: Colors.transparent,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: control,
        backgroundColor: colors.inverseSurface,
        contentTextStyle:
            TextStyle(color: colors.onInverseSurface, fontSize: 13),
        insetPadding: const EdgeInsets.all(16),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 68,
        elevation: 0,
        backgroundColor: colors.surface,
        indicatorShape: const StadiumBorder(),
        indicatorColor: colors.secondaryContainer,
        labelTextStyle: WidgetStatePropertyAll(
            TextStyle(fontSize: 11, color: colors.onSurface)),
      ),
      listTileTheme: const ListTileThemeData(shape: control),
      expansionTileTheme:
          const ExpansionTileThemeData(shape: control, collapsedShape: control),
      checkboxTheme: CheckboxThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
      toggleButtonsTheme: ToggleButtonsThemeData(
          borderRadius: BorderRadius.circular(AppRadii.control)),
      dividerTheme: DividerThemeData(
        color: colors.outlineVariant.withValues(alpha: 0.3),
        thickness: 0.6,
        space: 1,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
    );
  }
}

class _SoftPageTransitionsBuilder extends PageTransitionsBuilder {
  const _SoftPageTransitionsBuilder();
  @override
  Widget buildTransitions<T>(
      PageRoute<T> route,
      BuildContext context,
      Animation<double> animation,
      Animation<double> secondaryAnimation,
      Widget child) {
    return FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
      child: child,
    );
  }
}
