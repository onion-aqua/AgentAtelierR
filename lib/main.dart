import 'package:alarm/alarm.dart';
import 'package:flutter/material.dart';
import 'package:spine_flutter/spine_flutter.dart' hide Color;

import 'src/app_controller.dart';
import 'src/app_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initSpineFlutter(enableMemoryDebugging: false);
  await Alarm.init();
  final controller = await AppController.load();
  runApp(RyzaChatApp(controller: controller));
}

class RyzaChatApp extends StatelessWidget {
  const RyzaChatApp({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    const ink = Color(0xFF262521);
    const paper = Color(0xFFF6F3ED);

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Ryza Chat Prototype',
      theme: ThemeData(
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
      ),
      home: AppShell(controller: controller),
    );
  }
}
