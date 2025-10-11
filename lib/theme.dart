import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class LightModeColors {
  static const lightPrimary = Color(0xFF1976D2);
  static const lightOnPrimary = Color(0xFFFFFFFF);
  static const lightPrimaryContainer = Color(0xFFD3E4FD);
  static const lightOnPrimaryContainer = Color(0xFF001D35);
  static const lightSecondary = Color(0xFF2C2418);
  static const lightOnSecondary = Color(0xFFFFFFFF);
  static const lightTertiary = Color(0xFF00BCD4);
  static const lightOnTertiary = Color(0xFFFFFFFF);
  static const lightError = Color(0xFFFF5252);
  static const lightOnError = Color(0xFFFFFFFF);
  static const lightErrorContainer = Color(0xFFFFDAD6);
  static const lightOnErrorContainer = Color(0xFF410002);
  static const lightInversePrimary = Color(0xFFB5B0FF);
  static const lightShadow = Color(0xFF000000);
  static const lightSurface = Color(0xFFFAFAFC);
  static const lightOnSurface = Color(0xFF1A1A1A);
  static const lightAppBarBackground = Color(0xFFFFFFFF);
}

class DarkModeColors {
  static const darkPrimary = Color(0xFF42A5F5);
  static const darkOnPrimary = Color(0xFF001D35);
  static const darkPrimaryContainer = Color(0xFF004B87);
  static const darkOnPrimaryContainer = Color(0xFFD3E4FD);
  static const darkSecondary = Color(0xFF4A3828);
  static const darkOnSecondary = Color(0xFFFFFFFF);
  static const darkTertiary = Color(0xFF4DD0E1);
  static const darkOnTertiary = Color(0xFF00363D);
  static const darkError = Color(0xFFFF8A80);
  static const darkOnError = Color(0xFF690005);
  static const darkErrorContainer = Color(0xFF93000A);
  static const darkOnErrorContainer = Color(0xFFFFDAD6);
  static const darkInversePrimary = Color(0xFF6C63FF);
  static const darkShadow = Color(0xFF000000);
  static const darkSurface = Color(0xFF1A1A1A);
  static const darkOnSurface = Color(0xFFE8E8E8);
  static const darkAppBarBackground = Color(0xFF242424);
}

class FontSizes {
  static const double displayLarge = 57.0;
  static const double displayMedium = 45.0;
  static const double displaySmall = 36.0;
  static const double headlineLarge = 32.0;
  static const double headlineMedium = 28.0;
  static const double headlineSmall = 24.0;
  static const double titleLarge = 22.0;
  static const double titleMedium = 18.0;
  static const double titleSmall = 16.0;
  static const double labelLarge = 16.0;
  static const double labelMedium = 14.0;
  static const double labelSmall = 12.0;
  static const double bodyLarge = 16.0;
  static const double bodyMedium = 14.0;
  static const double bodySmall = 12.0;
}

ThemeData get lightTheme => ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.light(
    primary: LightModeColors.lightPrimary,
    onPrimary: LightModeColors.lightOnPrimary,
    primaryContainer: LightModeColors.lightPrimaryContainer,
    onPrimaryContainer: LightModeColors.lightOnPrimaryContainer,
    secondary: LightModeColors.lightSecondary,
    onSecondary: LightModeColors.lightOnSecondary,
    tertiary: LightModeColors.lightTertiary,
    onTertiary: LightModeColors.lightOnTertiary,
    error: LightModeColors.lightError,
    onError: LightModeColors.lightOnError,
    errorContainer: LightModeColors.lightErrorContainer,
    onErrorContainer: LightModeColors.lightOnErrorContainer,
    inversePrimary: LightModeColors.lightInversePrimary,
    shadow: LightModeColors.lightShadow,
    surface: LightModeColors.lightSurface,
    onSurface: LightModeColors.lightOnSurface,
  ),
  brightness: Brightness.light,
  scaffoldBackgroundColor: LightModeColors.lightSurface,
  appBarTheme: AppBarTheme(
    backgroundColor: LightModeColors.lightAppBarBackground,
    foregroundColor: LightModeColors.lightOnSurface,
    elevation: 0,
    centerTitle: true,
  ),
  textTheme: TextTheme(
    displayLarge: GoogleFonts.poppins(fontSize: FontSizes.displayLarge, fontWeight: FontWeight.w700),
    displayMedium: GoogleFonts.poppins(fontSize: FontSizes.displayMedium, fontWeight: FontWeight.w600),
    displaySmall: GoogleFonts.poppins(fontSize: FontSizes.displaySmall, fontWeight: FontWeight.w600),
    headlineLarge: GoogleFonts.poppins(fontSize: FontSizes.headlineLarge, fontWeight: FontWeight.w600),
    headlineMedium: GoogleFonts.poppins(fontSize: FontSizes.headlineMedium, fontWeight: FontWeight.w600),
    headlineSmall: GoogleFonts.poppins(fontSize: FontSizes.headlineSmall, fontWeight: FontWeight.w600),
    titleLarge: GoogleFonts.poppins(fontSize: FontSizes.titleLarge, fontWeight: FontWeight.w600),
    titleMedium: GoogleFonts.poppins(fontSize: FontSizes.titleMedium, fontWeight: FontWeight.w500),
    titleSmall: GoogleFonts.poppins(fontSize: FontSizes.titleSmall, fontWeight: FontWeight.w500),
    labelLarge: GoogleFonts.inter(fontSize: FontSizes.labelLarge, fontWeight: FontWeight.w500),
    labelMedium: GoogleFonts.inter(fontSize: FontSizes.labelMedium, fontWeight: FontWeight.w500),
    labelSmall: GoogleFonts.inter(fontSize: FontSizes.labelSmall, fontWeight: FontWeight.w500),
    bodyLarge: GoogleFonts.inter(fontSize: FontSizes.bodyLarge, fontWeight: FontWeight.normal),
    bodyMedium: GoogleFonts.inter(fontSize: FontSizes.bodyMedium, fontWeight: FontWeight.normal),
    bodySmall: GoogleFonts.inter(fontSize: FontSizes.bodySmall, fontWeight: FontWeight.normal),
  ),
);

ThemeData get darkTheme => ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.dark(
    primary: DarkModeColors.darkPrimary,
    onPrimary: DarkModeColors.darkOnPrimary,
    primaryContainer: DarkModeColors.darkPrimaryContainer,
    onPrimaryContainer: DarkModeColors.darkOnPrimaryContainer,
    secondary: DarkModeColors.darkSecondary,
    onSecondary: DarkModeColors.darkOnSecondary,
    tertiary: DarkModeColors.darkTertiary,
    onTertiary: DarkModeColors.darkOnTertiary,
    error: DarkModeColors.darkError,
    onError: DarkModeColors.darkOnError,
    errorContainer: DarkModeColors.darkErrorContainer,
    onErrorContainer: DarkModeColors.darkOnErrorContainer,
    inversePrimary: DarkModeColors.darkInversePrimary,
    shadow: DarkModeColors.darkShadow,
    surface: DarkModeColors.darkSurface,
    onSurface: DarkModeColors.darkOnSurface,
  ),
  brightness: Brightness.dark,
  scaffoldBackgroundColor: DarkModeColors.darkSurface,
  appBarTheme: AppBarTheme(
    backgroundColor: DarkModeColors.darkAppBarBackground,
    foregroundColor: DarkModeColors.darkOnSurface,
    elevation: 0,
    centerTitle: true,
  ),
  textTheme: TextTheme(
    displayLarge: GoogleFonts.poppins(fontSize: FontSizes.displayLarge, fontWeight: FontWeight.w700),
    displayMedium: GoogleFonts.poppins(fontSize: FontSizes.displayMedium, fontWeight: FontWeight.w600),
    displaySmall: GoogleFonts.poppins(fontSize: FontSizes.displaySmall, fontWeight: FontWeight.w600),
    headlineLarge: GoogleFonts.poppins(fontSize: FontSizes.headlineLarge, fontWeight: FontWeight.w600),
    headlineMedium: GoogleFonts.poppins(fontSize: FontSizes.headlineMedium, fontWeight: FontWeight.w600),
    headlineSmall: GoogleFonts.poppins(fontSize: FontSizes.headlineSmall, fontWeight: FontWeight.w600),
    titleLarge: GoogleFonts.poppins(fontSize: FontSizes.titleLarge, fontWeight: FontWeight.w600),
    titleMedium: GoogleFonts.poppins(fontSize: FontSizes.titleMedium, fontWeight: FontWeight.w500),
    titleSmall: GoogleFonts.poppins(fontSize: FontSizes.titleSmall, fontWeight: FontWeight.w500),
    labelLarge: GoogleFonts.inter(fontSize: FontSizes.labelLarge, fontWeight: FontWeight.w500),
    labelMedium: GoogleFonts.inter(fontSize: FontSizes.labelMedium, fontWeight: FontWeight.w500),
    labelSmall: GoogleFonts.inter(fontSize: FontSizes.labelSmall, fontWeight: FontWeight.w500),
    bodyLarge: GoogleFonts.inter(fontSize: FontSizes.bodyLarge, fontWeight: FontWeight.normal),
    bodyMedium: GoogleFonts.inter(fontSize: FontSizes.bodyMedium, fontWeight: FontWeight.normal),
    bodySmall: GoogleFonts.inter(fontSize: FontSizes.bodySmall, fontWeight: FontWeight.normal),
  ),
);
