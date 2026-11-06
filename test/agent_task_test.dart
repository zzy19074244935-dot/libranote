import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:libranote/models/models.dart';
import 'package:libranote/screens/agent_task_screen.dart';
import 'package:libranote/services/agent_task_engine.dart';

class _FakePathProvider extends Fake with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  final String base;
  _FakePathProvider(this.base);

  @override
  Future<String?> getApplicationDocumentsPath() async => p.join(base, 'docs');

  @override
  Future<String?> getTemporaryPath() async => p.join(base, 'tmp');
}

void main() {
  test('parsePlan 从模型输出提取步骤', () {
    // 标准 JSON 数组。
    expect(
      AgentTaskEngine.parsePlan('["第一步", "第二步", "第三步"]'),
      ['第一步', '第二步', '第三步'],
    );
    // ```json 围栏 + 前后杂文。
    expect(
      AgentTaskEngine.parsePlan('好的，计划如下：\n```json\n'
          '["打开书", "搜索关键词", "写摘要"]\n```\n请确认。'),
      ['打开书', '搜索关键词', '写摘要'],
    );
    // 非字符串元素被过滤。
    expect(
      AgentTaskEngine.parsePlan('["步骤一", 123, "步骤二"]'),
      ['步骤一', '步骤二'],
    );
    // 无 JSON → 按行兜底（去掉方括号行）。
    expect(
      AgentTaskEngine.parsePlan('步骤一\n步骤二\n[]'),
      ['步骤一', '步骤二'],
    );
    // 空输入。
    expect(AgentTaskEngine.parsePlan(''), isEmpty);
  });

  test('AiTask 步骤序列化往返', () {
    const task = AiTask(
      id: 1,
      goal: '测试任务',
      status: 'running',
      steps: [
        AiTaskStep(text: '第一步', status: 'done', toolName: 'book_search'),
        AiTaskStep(text: '第二步'),
      ],
    );
    final round = AiTask.fromJson(task.toJson());
    expect(round.goal, '测试任务');
    expect(round.steps.length, 2);
    expect(round.steps[0].toolName, 'book_search');
    expect(round.steps[1].status, 'pending');
  });

  testWidgets('Agent 任务页冒烟渲染', (tester) async {
    final base = Directory.systemTemp.createTempSync('agent_task_test');
    addTearDown(() {
      try {
        base.deleteSync(recursive: true);
      } catch (_) {}
    });
    PathProviderPlatform.instance = _FakePathProvider(base.path);
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: AgentTaskScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Agent 任务'), findsOneWidget);
    expect(find.text('任务历史'), findsOneWidget);
    expect(find.text('开始任务'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
