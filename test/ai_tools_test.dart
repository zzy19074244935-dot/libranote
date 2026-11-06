import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:libranote/services/ai_service.dart';
import 'package:libranote/services/ai_tools.dart';
import 'package:libranote/services/storage_service.dart';

/// AI 工具（Phase 6）单元测试：
/// 覆盖不依赖网络/数据库的工具执行路径 + 工具注册完整性。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  AiToolContext context() => AiToolContext(storage: StorageService());

  test('内置工具注册完整且名字唯一', () {
    final tools = AiTools.all();
    final names = tools.map((t) => t.name).toSet();
    expect(names.length, tools.length,
        reason: '工具名必须唯一（function calling 按名分发）');
    expect(
        names,
        containsAll([
          'calculator',
          'bookshelf_list',
          'save_note',
          'edit_note',
          'delete_note',
          'create_memo',
          'move_books_to_folder'
        ]));
    for (final t in tools) {
      expect(t.toToolJson()['function']['name'], t.name);
    }
  });

  test('计算器：四则运算与幂', () async {
    final calc = AiTools.byName('calculator')!;
    final r1 = await calc.execute({'expression': '3.14*2^5'}, context());
    expect(r1, contains('100.48'));

    final r2 = await calc.execute({'expression': 'sqrt(144)+12'}, context());
    expect(r2, contains('24'));

    final r3 = await calc.execute({'expression': '1/0'}, context());
    expect(r3, isNotEmpty);
  });

  test('当前时间：返回年月日', () async {
    final tool = AiTools.byName('current_time')!;
    final result = await tool.execute({}, context());
    final now = DateTime.now();
    expect(result, contains('${now.year} 年'));
    expect(result, contains('星期'));
  });

  test('思维导图：产出带 mindmap 标记的 JSON', () async {
    final tool = AiTools.byName('mind_map')!;
    final result = await tool.execute({
      'title': '测试主题',
      'nodes': [
        {
          'text': '根',
          'children': [
            {'text': '子'},
          ],
        },
      ],
    }, context());
    final map = jsonDecode(result) as Map<String, dynamic>;
    expect(map['mindmap'], true);
    expect(map['title'], '测试主题');
    expect((map['nodes'] as List).length, 1);
  });

  test('按 Href 取章节：无书时给出可读提示', () async {
    final tool = AiTools.byName('get_chapter_by_href')!;
    final result = await tool.execute({'ref': '3'}, context());
    expect(result, contains('没找到章节'));
  });

  test('查看书架：存储不可用时工具给出可读提示而不是崩', () async {
    // 测试环境没有 path_provider 插件，DB 打不开——executeCall 必须兜底。
    final result = await AiTools.executeCall(
      const AiToolCall(id: 'x', name: 'bookshelf_list', arguments: '{}'),
      context(),
    );
    expect(result, isNotEmpty);
    expect(result, contains('失败'));
  });

  test('未知工具名 → executeCall 返回错误文本', () async {
    final result = await AiTools.executeCall(
      const AiToolCall(id: 'x', name: 'no_such_tool', arguments: '{}'),
      context(),
    );
    expect(result, contains('未知工具'));
  });

  test('AI 工具开关存储：默认全开，关掉后列表不含它', () async {
    final disabled = await AiToolsStore.instance.disabledNames();
    expect(disabled, isEmpty);
    await AiToolsStore.instance.setDisabled('calculator', true);
    final enabled = await AiToolsStore.instance.enabledTools();
    expect(enabled.any((t) => t.name == 'calculator'), isFalse);
    await AiToolsStore.instance.setDisabled('calculator', false);
    final enabled2 = await AiToolsStore.instance.enabledTools();
    expect(enabled2.any((t) => t.name == 'calculator'), isTrue);
  });
}
