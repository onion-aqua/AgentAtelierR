import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/chat_segments.dart';
import 'package:ryza_chat_mvp/src/fish_mcp_service.dart';
import 'package:ryza_chat_mvp/src/settings_screen.dart';

void main() {
  final service = FishMcpService.instance;
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  const companionChannel = MethodChannel('agent_atelier_r/companion_runtime');
  const companionEvents = MethodChannel(
    'agent_atelier_r/companion_runtime/events',
  );

  setUpAll(() {
    messenger.setMockMethodCallHandler(companionChannel, (call) async {
      if (call.method == 'openBackgroundSettings') return {'opened': true};
      if (!const {
        'getState',
        'start',
        'stop',
        'setAudioActive',
      }.contains(call.method)) {
        fail('Unexpected companion method in MCP settings: ${call.method}');
      }
      return {
        'running': call.method != 'stop',
        'starting': false,
        'stopRequested': call.method == 'stop',
        'muted': false,
        'callActive': false,
        'notificationsAllowed': true,
        'phoneStatePermission': false,
        'manufacturer': 'local-test',
        'lastError': '',
      };
    });
    messenger.setMockMethodCallHandler(companionEvents, (_) async => null);
  });

  tearDownAll(() {
    messenger.setMockMethodCallHandler(companionChannel, null);
    messenger.setMockMethodCallHandler(companionEvents, null);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({
      'fish_mcp_client_id_v1': 'local-widget-test-client',
    });
    await service.disconnect(clearError: true);
    service.lastDiscoveryAt = null;
  });

  tearDown(() async {
    await service.disconnect(clearError: true);
    service.lastDiscoveryAt = null;
  });

  Future<void> openMcpPage(WidgetTester tester) async {
    final entry = find.byKey(const ValueKey('tts-settings-fishAudioMcp'));
    await tester.scrollUntilVisible(
      entry,
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();
  }

  Future<AppController> openSettings(
    WidgetTester tester, {
    bool expandAdvanced = true,
  }) async {
    final controller = (await tester.runAsync(AppController.load))!;
    addTearDown(controller.dispose);
    tester.view.physicalSize = const Size(360, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          controller: controller,
          onMenuPressed: () {},
          initialSection: SettingsSection.audio,
        ),
      ),
    );
    await openMcpPage(tester);
    if (!expandAdvanced) return controller;
    final advanced = find.text('高级选项与连接诊断');
    await tester.ensureVisible(advanced);
    await tester.tap(advanced);
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('fish-mcp-normal-voice')),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  Map<String, dynamic> studioSchema(String name) => {
    'type': 'object',
    'properties': switch (name) {
      'studio_create_project' => {
        'name': {'type': 'string'},
        'roster': {'type': 'array'},
        'default_voice_id': {'type': 'string'},
        'chapters': {'type': 'array'},
      },
      'studio_update_project' => {
        'project_id': {'type': 'string'},
        'default_backend': {'type': 'string'},
        'scene_preset': {'type': 'string'},
      },
      'studio_project' => {
        'project_id': {'type': 'string'},
      },
      'studio_write_blocks' => {
        'project_id': {'type': 'string'},
        'ops': {'type': 'array'},
      },
      'studio_generate' => {
        'project_id': {'type': 'string'},
        'blocks': {'type': 'array'},
        'dry_run': {'type': 'boolean'},
      },
      _ => <String, dynamic>{},
    },
  };

  void discover({
    required Map<String, dynamic> schema,
    bool withStudio = false,
  }) {
    service.tools = [
      FishMcpToolInfo(
        name: 'text_to_speech',
        description: 'Test tool; no network request is made.',
        inputSchema: schema,
      ),
      if (withStudio)
        for (final name in const [
          'studio_help',
          'studio_create_project',
          'studio_update_project',
          'studio_write_blocks',
          'studio_project',
          'studio_generate',
        ])
          FishMcpToolInfo(
            name: name,
            description: 'Studio fixture; no network request is made.',
            inputSchema: studioSchema(name),
          ),
    ];
    service.ttsToolName = 'text_to_speech';
    service.state = FishMcpConnectionState.toolsDiscovered;
    service.lastDiscoveryAt = DateTime.utc(2026, 10, 15);
  }

  testWidgets('advanced diagnostics are folded and drafts survive toggling', (
    tester,
  ) async {
    await openSettings(tester, expandAdvanced: false);
    expect(find.text('退出授权'), findsNothing);
    final field = find.byKey(const ValueKey('fish-mcp-normal-voice'));
    await tester.enterText(field, 'draft-voice');
    final advanced = find.text('高级选项与连接诊断');
    await tester.ensureVisible(advanced);
    await tester.tap(advanced);
    await tester.pumpAndSettle();
    expect(find.text('退出授权'), findsOneWidget);
    await tester.ensureVisible(advanced);
    await tester.tap(advanced);
    await tester.pumpAndSettle();
    expect(find.text('退出授权'), findsNothing);
    expect(tester.widget<TextField>(field).controller!.text, 'draft-voice');
    expect(tester.takeException(), isNull);
  });

  testWidgets('OAuth state changes refresh MCP settings without another tap', (
    tester,
  ) async {
    await openSettings(tester);
    expect(find.text('状态：未连接'), findsOneWidget);
    // A saved mock client ID avoids registration; launchLogin false avoids
    // opening a browser. This only prepares local PKCE state.
    await tester.runAsync(() => service.beginAuthorization(launchLogin: false));
    await tester.pump();
    expect(find.text('状态：等待 Fish Audio 授权'), findsOneWidget);
    expect(find.text('等待浏览器授权…'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('MCP settings follows asynchronous connection notifications', (
    tester,
  ) async {
    discover(
      schema: {
        'type': 'object',
        'properties': {
          'text': {'type': 'string'},
        },
      },
    );
    await openSettings(tester);
    expect(find.text('状态：工具已探测'), findsOneWidget);
    final model = tester.widget<DropdownButtonFormField<String>>(
      find.byKey(const ValueKey('fish-mcp-model-')),
    );
    expect(model.onChanged, isNotNull);
    expect(find.text('生成路径：text_to_speech'), findsOneWidget);
    expect(find.text('服务默认使用 text_to_speech，不指定模型。'), findsOneWidget);

    // A service notification outside this route (such as an OAuth callback)
    // must rebuild it without another user tap.
    await service.disconnect();
    await tester.pump();
    expect(find.text('状态：未连接'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('fish-mcp-tool-text_to_speech')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('official schema routes an explicit model through Studio MCP', (
    tester,
  ) async {
    final tool = jsonDecode(
      File('test/fixtures/fish_mcp_text_to_speech_2026-10-16.json')
          .readAsStringSync(),
    ) as Map<String, dynamic>;
    discover(
      schema: tool['inputSchema'] as Map<String, dynamic>,
      withStudio: true,
    );
    SharedPreferences.setMockInitialValues({'fish_mcp_model': 'drama-3'});
    final controller = await openSettings(tester);
    expect(
      find.text(
        '通过 Studio MCP 将所选模型写入项目的 default_backend，并核对云端项目配置。配置确认不等于验证实际推理模型。',
      ),
      findsOneWidget,
    );
    expect(find.text('生成路径：Studio MCP（项目后端配置）'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('fish-mcp-studio-cloud-notice')),
      findsOneWidget,
    );
    expect(find.textContaining('additionalProperties=true'), findsNothing);
    final dropdown = tester.widget<DropdownButtonFormField<String>>(
      find.byKey(const ValueKey('fish-mcp-model-drama-3')),
    );
    expect(dropdown.onChanged, isNotNull);
    await tester.tap(find.text('保存并使用 MCP'));
    await tester.pumpAndSettle();
    expect(controller.fishMcpModel, 'drama-3');
    expect(tester.takeException(), isNull);
  });

  testWidgets('MCP model dropdown keeps presets selectable without schema', (
    tester,
  ) async {
    discover(
      schema: {
        'type': 'object',
        'properties': {
          'text': {'type': 'string'},
        },
      },
    );
    final controller = await openSettings(tester);
    final dropdown = find.byKey(const ValueKey('fish-mcp-model-'));
    await tester.ensureVisible(dropdown);
    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    for (final label in ['服务默认（不指定模型）', 's2.1-pro', 'drama-3']) {
      expect(find.text(label).hitTestable(), findsOneWidget);
    }
    expect(find.text('s2.1-pro-free'), findsNothing);
    await tester.tap(find.text('drama-3').hitTestable());
    await tester.pumpAndSettle();
    expect(find.text('生成路径：暂不可用'), findsOneWidget);
    expect(find.textContaining('且缺少 Studio MCP 工具：'), findsOneWidget);
    expect(find.textContaining('此情况保留 MCP 错误，不启用 REST 回退。'), findsOneWidget);
    expect(find.text('清空未受支持的模型设置'), findsNothing);
    await tester.tap(find.text('保存并使用 MCP'));
    await tester.pumpAndSettle();
    expect(controller.fishMcpModel, 'drama-3');
    expect(controller.fishMcpAutoFallback, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Studio without declared dry_run is shown as unavailable', (
    tester,
  ) async {
    discover(
      schema: {
        'type': 'object',
        'properties': {
          'text': {'type': 'string'},
        },
      },
      withStudio: true,
    );
    service.tools = [
      for (final tool in service.tools)
        if (tool.name == 'studio_generate')
          FishMcpToolInfo(
            name: tool.name,
            description: tool.description,
            inputSchema: const {
              'type': 'object',
              'properties': {
                'project_id': {'type': 'string'},
                'blocks': {'type': 'array'},
              },
            },
          )
        else
          tool,
    ];
    SharedPreferences.setMockInitialValues({'fish_mcp_model': 'drama-3'});
    await openSettings(tester);
    expect(service.missingStudioTools, isEmpty);
    expect(service.studioAvailable, isFalse);
    expect(find.text('生成路径：暂不可用'), findsOneWidget);
    expect(
      find.textContaining('Studio MCP 参数不兼容：studio_generate 未声明字段 dry_run'),
      findsNWidgets(2),
    );
    expect(find.textContaining('Studio MCP：所需工具齐全'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'service default stays on ordinary TTS when Studio is available',
    (tester) async {
      discover(
        schema: {
          'type': 'object',
          'properties': {
            'text': {'type': 'string'},
          },
        },
        withStudio: true,
      );
      await openSettings(tester);
      expect(find.text('生成路径：text_to_speech'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('fish-mcp-studio-cloud-notice')),
        findsNothing,
      );
      final dropdown = find.byKey(const ValueKey('fish-mcp-model-'));
      await tester.ensureVisible(dropdown);
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('drama-3').hitTestable());
      await tester.pumpAndSettle();
      expect(find.text('生成路径：Studio MCP（项目后端配置）'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('fish-mcp-studio-cloud-notice')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('MCP dropdown preserves a previously saved custom model', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'fish_mcp_model': 'custom-model'});
    final controller = await openSettings(tester);
    final dropdown = tester.widget<DropdownButtonFormField<String>>(
      find.byKey(const ValueKey('fish-mcp-model-custom-model')),
    );
    expect(dropdown.initialValue, 'custom-model');
    final button = tester.widget<DropdownButton<String>>(
      find.descendant(
        of: find.byKey(const ValueKey('fish-mcp-model-custom-model')),
        matching: find.byType(DropdownButton<String>),
      ),
    );
    expect(button.items!.map((item) => item.value), [
      '',
      's2.1-pro',
      'drama-3',
      'custom-model',
    ]);
    await tester.tap(find.text('保存并使用 MCP'));
    await tester.pumpAndSettle();
    expect(controller.fishMcpModel, 'custom-model');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'MCP model changes need saving and reopen with the saved choice',
    (tester) async {
      SharedPreferences.setMockInitialValues({'fish_mcp_model': 's2.1-pro'});
      final controller = await openSettings(tester);
      expect(find.text('保存后，下次语音请求生效。'), findsOneWidget);
      expect(find.text('云端返回模型：未返回模型标识，无法确认已切换'), findsOneWidget);

      Future<void> selectModel(String current, String next) async {
        final dropdown = find.byKey(ValueKey('fish-mcp-model-$current'));
        await tester.ensureVisible(dropdown);
        await tester.tap(dropdown);
        await tester.pumpAndSettle();
        await tester.tap(find.text(next).hitTestable());
        await tester.pumpAndSettle();
      }

      await selectModel('s2.1-pro', 'drama-3');
      expect(controller.fishMcpModel, 's2.1-pro');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await openMcpPage(tester);
      expect(
        tester
            .widget<DropdownButtonFormField<String>>(
              find.byKey(const ValueKey('fish-mcp-model-s2.1-pro')),
            )
            .initialValue,
        's2.1-pro',
      );

      await selectModel('s2.1-pro', '服务默认（不指定模型）');
      await tester.tap(find.text('保存并使用 MCP'));
      await tester.pumpAndSettle();
      expect(controller.fishMcpModel, '');
      await openMcpPage(tester);
      expect(
        tester
            .widget<DropdownButtonFormField<String>>(
              find.byKey(const ValueKey('fish-mcp-model-')),
            )
            .initialValue,
        '',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('stored model and editable voice survive missing schema fields', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'fish_mcp_model': 'drama-3',
      'fish_mcp_voice': 'stored-voice-id',
      'tts_voice_settings_revision_v1': 1,
    });
    discover(
      schema: {
        'type': 'object',
        'properties': {
          'text': {'type': 'string'},
        },
      },
    );
    final controller = await openSettings(tester);
    final voice = find.byKey(const ValueKey('fish-mcp-normal-voice'));
    expect(tester.widget<TextField>(voice).enabled, isNot(false));
    expect(tester.widget<TextField>(voice).controller!.text, isEmpty);
    expect(find.text('stored-voice-id'), findsNothing);
    expect(find.text('清空未受支持的模型设置'), findsNothing);
    await tester.enterText(voice, 'updated-voice-id');
    await tester.tap(find.text('保存并使用 MCP'));
    await tester.pumpAndSettle();
    expect(controller.fishMcpModel, 'drama-3');
    expect(controller.fishMcpVoice, 'updated-voice-id');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'MCP saves independent normal and ASMR voices and shows Klaudia',
    (tester) async {
      final controller = await openSettings(tester);
      final voice = find.byKey(const ValueKey('fish-mcp-normal-voice'));
      final asmrVoice = find.byKey(const ValueKey('fish-mcp-asmr-voice'));
      expect(tester.widget<TextField>(voice).enabled, isNot(false));
      expect(tester.widget<TextField>(asmrVoice).enabled, isNot(false));
      expect(find.text(klaudiaFishAudioReferenceId), findsNothing);
      expect(find.text('已内置，无需填写'), findsOneWidget);
      await tester.enterText(voice, 'normal-voice-id');
      await tester.enterText(asmrVoice, 'asmr-voice-id');
      await tester.tap(find.text('保存并使用 MCP'));
      await tester.pumpAndSettle();
      expect(controller.fishMcpVoice, 'normal-voice-id');
      expect(controller.fishMcpAsmrVoice, 'asmr-voice-id');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('MCP preserves a saved ASMR voice without schema restrictions', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'fish_mcp_voice': 'normal-voice-id',
      'fish_mcp_asmr_voice': 'stored-asmr-id',
      'tts_voice_settings_revision_v1': 1,
    });
    final controller = await openSettings(tester);
    final asmrVoice = find.byKey(const ValueKey('fish-mcp-asmr-voice'));
    expect(tester.widget<TextField>(asmrVoice).controller!.text, isEmpty);
    expect(find.text('stored-asmr-id'), findsNothing);
    await tester.tap(find.text('保存并使用 MCP'));
    await tester.pumpAndSettle();
    expect(controller.fishMcpVoice, 'normal-voice-id');
    expect(controller.fishMcpAsmrVoice, 'stored-asmr-id');
    expect(tester.takeException(), isNull);
  });

  testWidgets('MCP tool schema is expandable and copied without a tool call', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'fish_mcp_model': 's2-pro'});
    final schema = <String, dynamic>{
      'type': 'object',
      'properties': {
        'text': {'type': 'string'},
        'voice_id': {'type': 'string'},
        'model': {
          'type': 'string',
          'enum': ['s2-pro'],
        },
      },
      'required': ['text'],
    };
    discover(schema: schema);
    await openSettings(tester);
    expect(
      find.text('字段：model；schema 列出：s2-pro；实际可用性由云端服务判断。'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<SwitchListTile>(
            find.widgetWithText(SwitchListTile, 'MCP 失败时允许回退现有 Fish API'),
          )
          .value,
      isFalse,
    );
    final tile = find.byKey(const ValueKey('fish-mcp-tool-text_to_speech'));
    await tester.ensureVisible(tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    final copy = find.text('复制工具与完整 inputSchema');
    await tester.ensureVisible(copy);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
    await tester.tap(copy);
    await tester.pump();
    final decoded = jsonDecode(copied!) as Map<String, dynamic>;
    expect(decoded['name'], 'text_to_speech');
    expect(decoded['inputSchema'], schema);
    expect(find.textContaining('Studio MCP：缺少 Studio MCP 工具'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
