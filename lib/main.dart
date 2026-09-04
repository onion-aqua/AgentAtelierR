import 'dart:ui';

import 'package:alarm/alarm.dart';
import 'package:flutter/material.dart';
import 'package:spine_flutter/spine_flutter.dart' hide Color;

import 'src/app_controller.dart';
import 'src/app_localization.dart';
import 'src/app_shell.dart';
import 'src/runtime_log.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RuntimeLog.instance.initialize();
  FlutterError.onError = (details) {
    RuntimeLog.instance.error(
      'Flutter',
      details.exception,
      details.stack ?? StackTrace.current,
    );
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stackTrace) {
    RuntimeLog.instance.error('Platform', error, stackTrace);
    return false;
  };
  RuntimeLog.instance.info('App', '应用启动，版本 0.5.0+14');
  try {
    await initSpineFlutter(enableMemoryDebugging: false);
    await Alarm.init();
    final controller = await AppController.load();
    runApp(RyzaChatApp(controller: controller));
  } on Object catch (error, stackTrace) {
    RuntimeLog.instance.error('Startup', error, stackTrace);
    rethrow;
  }
}

class RyzaChatApp extends StatelessWidget {
  const RyzaChatApp({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    const ink = Color(0xFF262521);
    const paper = Color(0xFFF6F3ED);
    const darkSurface = Color(0xFF171A1A);
    final lightTheme = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF2D796A),
        brightness: Brightness.light,
        surface: paper,
      ),
      scaffoldBackgroundColor: paper,
      textTheme: ThemeData.light().textTheme.apply(
        bodyColor: ink,
        displayColor: ink,
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: InputBorder.none,
        isDense: true,
      ),
    );
    final darkTheme = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF78C8B4),
        brightness: Brightness.dark,
        surface: darkSurface,
      ),
      scaffoldBackgroundColor: darkSurface,
      inputDecorationTheme: const InputDecorationTheme(
        border: InputBorder.none,
        isDense: true,
      ),
    );

    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Ryza Chat Prototype',
        theme: lightTheme,
        darkTheme: darkTheme,
        themeMode: switch (controller.themePreference) {
          AppThemePreference.system => ThemeMode.system,
          AppThemePreference.light => ThemeMode.light,
          AppThemePreference.dark => ThemeMode.dark,
        },
        home: AppShell(controller: controller),
      ),
    );
  }
}
