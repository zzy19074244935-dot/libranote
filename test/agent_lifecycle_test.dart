import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:libranote/models/models.dart';
import 'package:libranote/providers/app_providers.dart';
import 'package:libranote/screens/agent_task_screen.dart';
import 'package:libranote/services/agent_task_engine.dart';
import 'package:libranote/services/ai_provider_config.dart';
import 'package:libranote/services/ai_service.dart';
import 'package:libranote/services/storage_service.dart';

class _Storage extends StorageService {
  final Map<int, AiTask> tasks = {};
  int memoWrites = 0;

  @override
  Future<int> insertAiTask(AiTask task) async {
    final id = tasks.length + 1;
    tasks[id] = task.copyWith(id: id);
    return id;
  }

  @override
  Future<void> updateAiTask(AiTask task) async {
    tasks[task.id!] = task;
  }

  @override
  Future<List<AiTask>> listAiTasks({bool onlyActive = false}) async =>
      tasks.values.where((t) => !onlyActive || t.isRunning).toList();

  @override
  Future<int> insertMemo(Memo memo) async {
    memoWrites++;
    return 1;
  }
}

class _Ai extends AiService {
  _Ai() : super.testing();
  bool failStep = false;
  bool writeMemo = false;
  Completer<void>? planningGate;
  Completer<void>? summaryGate;
  int summaries = 0;

  @override
  Future<AiChatRound> chatRound({
    required AiProviderConfig provider,
    required String apiKey,
    required List<Map<String, dynamic>> messages,
    String? systemPrompt,
    List<Map<String, dynamic>>? tools,
    CancelToken? cancelToken,
  }) async {
    if (planningGate != null) {
      await Future.any([planningGate!.future, cancelToken!.whenCancel]);
      if (cancelToken.isCancelled) throw const AiRequestCancelled();
    }
    return const AiChatRound(content: '["保存摘要"]');
  }

  @override
  Future<AiToolLoopResult> runToolLoop({
    required AiProviderConfig provider,
    required String apiKey,
    required List<Map<String, String>> messages,
    String? systemPrompt,
    List<Map<String, dynamic>>? tools,
    required Future<String> Function(AiToolCall call) executeTool,
    void Function(String name)? onToolCall,
    CancelToken? cancelToken,
  }) async {
    if (failStep) throw const AiServiceException('模拟步骤请求失败');
    if (writeMemo) {
      await executeTool(const AiToolCall(
        id: 'memo',
        name: 'create_memo',
        arguments: '{"title":"摘要","content":"测试内容"}',
      ));
    }
    return const AiToolLoopResult(content: '步骤结束');
  }

  @override
  Future<AiChatResult> chatOnce({
    required AiProviderConfig provider,
    required String apiKey,
    required List<Map<String, dynamic>> messages,
    String? systemPrompt,
    List<Map<String, dynamic>>? tools,
    CancelToken? cancelToken,
  }) async {
    summaries++;
    if (summaryGate != null) {
      await Future.any([summaryGate!.future, cancelToken!.whenCancel]);
      if (cancelToken.isCancelled) throw const AiRequestCancelled();
    }
    return const AiChatResult(content: '汇总');
  }
}

Future<void> _until(AgentTaskEngine engine, bool Function() condition) async {
  if (condition()) return;
  final done = Completer<void>();
  void listener() {
    if (condition() && !done.isCompleted) done.complete();
  }

  engine.addListener(listener);
  try {
    await done.future.timeout(const Duration(seconds: 3));
  } finally {
    engine.removeListener(listener);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Ai ai;
  late _Storage storage;
  late AgentTaskEngine engine;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await AiProviderStore.instance.save(const AiProviderConfig(
      id: 'test',
      name: 'test',
      baseUrl: 'http://unused',
      model: 'test',
      enabled: true,
    ));
    await AiProviderStore.instance.setApiKey('test', 'fake-test-key');
    ai = _Ai();
    storage = _Storage();
    engine = AgentTaskEngine.testing(aiService: ai);
  });

  tearDown(() async {
    engine.cancel();
    await _until(engine, () => !engine.running);
    engine.dispose();
  });

  test('即时确认计划不会丢失，确认后持久化 running 状态', () async {
    final statuses = <String>[];
    engine.addListener(() {
      statuses.add(engine.task?.status ?? '');
      if (engine.task?.status == 'awaiting_confirm') engine.confirmPlan();
    });
    await engine.startTask(goal: '测试', storage: storage);
    await _until(engine, () => !engine.running);
    expect(statuses, contains('running'));
    expect(storage.tasks.values.single.status, 'done');
  });

  test('规划中取消中断请求且不进入执行', () async {
    ai.planningGate = Completer<void>();
    await engine.startTask(goal: '测试', storage: storage);
    engine.cancel();
    await _until(engine, () => !engine.running);
    expect(storage.tasks.values.single.status, 'cancelled');
    expect(ai.summaries, 0);
  });

  test('总结期间取消不会被覆盖为已完成', () async {
    ai.summaryGate = Completer<void>();
    await engine.startTask(goal: '测试', storage: storage);
    await _until(engine, () => engine.task?.status == 'awaiting_confirm');
    engine.confirmPlan();
    await _until(engine, () => engine.activity == '生成任务总结…');
    engine.cancel();
    await _until(engine, () => !engine.running);
    expect(storage.tasks.values.single.status, 'cancelled');
  });

  test('步骤异常时最终状态为失败', () async {
    ai.failStep = true;
    await engine.startTask(goal: '测试', storage: storage);
    await _until(engine, () => engine.task?.status == 'awaiting_confirm');
    engine.confirmPlan();
    await _until(engine, () => !engine.running);
    expect(engine.task!.status, 'failed');
    expect(engine.task!.steps.single.status, 'failed');
  });

  test('后台即时确认不丢失，审批后恢复 running', () async {
    ai.writeMemo = true;
    final statuses = <String>[];
    engine.addListener(() {
      statuses.add(engine.task?.status ?? '');
      if (engine.task?.status == 'awaiting_confirm') engine.confirmPlan();
      if (engine.pendingApproval != null) {
        engine.resolveApproval(true, approval: engine.pendingApproval!);
      }
    });
    await engine.startTask(goal: '测试', storage: storage);
    await _until(engine, () => !engine.running);
    expect(statuses, contains('waiting_approval'));
    expect(statuses.lastIndexOf('running'),
        greaterThan(statuses.indexOf('waiting_approval')));
    expect(storage.memoWrites, 1);
  });

  test('取消后台审批后不写入数据', () async {
    ai.writeMemo = true;
    await engine.startTask(goal: '测试', storage: storage);
    await _until(engine, () => engine.task?.status == 'awaiting_confirm');
    engine.confirmPlan();
    await _until(engine, () => engine.pendingApproval != null);
    final approval = engine.pendingApproval!;
    engine.cancel();
    engine.resolveApproval(true, approval: approval);
    await _until(engine, () => !engine.running);
    expect(engine.task!.status, 'cancelled');
    expect(storage.memoWrites, 0);
    expect(engine.pendingApproval, isNull);
  });

  test('前台审批取消后迟到的允许不写入数据', () async {
    ai.writeMemo = true;
    final approval = Completer<bool>();
    final asked = Completer<void>();
    engine.approvalHandler = (_) {
      asked.complete();
      return approval.future;
    };
    await engine.startTask(goal: '测试', storage: storage);
    await _until(engine, () => engine.task?.status == 'awaiting_confirm');
    engine.confirmPlan();
    await asked.future.timeout(const Duration(seconds: 3));
    engine.cancel();
    await _until(engine, () => !engine.running);
    approval.complete(true);
    await Future<void>.delayed(Duration.zero);
    expect(engine.task!.status, 'cancelled');
    expect(storage.memoWrites, 0);
  });

  test('并发启动只允许创建一个任务', () async {
    final first = engine.startTask(goal: '一', storage: storage);
    await expectLater(engine.startTask(goal: '二', storage: storage),
        throwsA(isA<FormatException>()));
    await first;
    expect(storage.tasks.length, 1);
  });

  test('旧任务的审批结果不能批准新任务', () async {
    ai.writeMemo = true;
    await engine.startTask(goal: '旧任务', storage: storage);
    await _until(engine, () => engine.task?.status == 'awaiting_confirm');
    engine.confirmPlan();
    await _until(engine, () => engine.pendingApproval != null);
    final oldApproval = engine.pendingApproval!;
    engine.cancel();
    await _until(engine, () => !engine.running);

    await engine.startTask(goal: '新任务', storage: storage);
    await _until(engine, () => engine.task?.status == 'awaiting_confirm');
    engine.confirmPlan();
    await _until(engine, () => engine.pendingApproval != null);
    final currentApproval = engine.pendingApproval!;
    engine.resolveApproval(true, approval: oldApproval);
    await Future<void>.delayed(Duration.zero);
    expect(engine.task!.status, 'waiting_approval');
    expect(storage.memoWrites, 0);
    engine.resolveApproval(true, approval: currentApproval);
    await _until(engine, () => !engine.running);
    expect(storage.memoWrites, 1);
  });

  test('进程启动时把遗留任务标中断，已完成记录不受影响', () async {
    await storage.insertAiTask(const AiTask(goal: '遗留', status: 'running'));
    await storage.insertAiTask(const AiTask(goal: '历史', status: 'done'));
    await AgentTaskEngine.markStaleTasks(storage);
    expect(storage.tasks[1]!.status, 'failed');
    expect(storage.tasks[2]!.status, 'done');
  });

  testWidgets('重进任务页不修改后台任务且不允许删除进行中的历史', (tester) async {
    await storage.insertAiTask(const AiTask(goal: '后台任务', status: 'running'));
    for (var i = 0; i < 2; i++) {
      await tester.pumpWidget(ProviderScope(
        overrides: [storageServiceProvider.overrideWithValue(storage)],
        child: const MaterialApp(home: AgentTaskScreen()),
      ));
      await tester.pumpAndSettle();
      expect(storage.tasks[1]!.status, 'running');
      final deleteButton = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.delete_outline),
      );
      expect(deleteButton.onPressed, isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    }
    expect(tester.takeException(), isNull);
  });
}
