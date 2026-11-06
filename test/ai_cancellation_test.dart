import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libranote/models/ai_models.dart';
import 'package:libranote/services/ai_service.dart';

const _provider = AiProviderConfig(
  id: 'test',
  name: 'test',
  baseUrl: 'unused',
  model: 'test',
);

class _ScriptedAi extends AiService {
  _ScriptedAi(this.rounds) : super.testing();
  final List<AiChatRound> rounds;
  int requests = 0;

  @override
  Future<AiChatRound> chatRound({
    required AiProviderConfig provider,
    required String apiKey,
    required List<Map<String, dynamic>> messages,
    String? systemPrompt,
    List<Map<String, dynamic>>? tools,
    CancelToken? cancelToken,
  }) async =>
      rounds[requests++];
}

const _call = AiToolCall(id: 'one', name: 'write', arguments: '{}');
final _tools = [
  {
    'type': 'function',
    'function': {'name': 'write'}
  },
];

void main() {
  test('取消后同一轮的后续工具和下一次模型请求都不执行', () async {
    final ai = _ScriptedAi([
      const AiChatRound(content: '', toolCalls: [_call, _call]),
    ]);
    final token = CancelToken();
    var writes = 0;
    await expectLater(
        ai.runToolLoop(
          provider: _provider,
          apiKey: 'test',
          messages: [],
          tools: _tools,
          cancelToken: token,
          executeTool: (_) async {
            writes++;
            token.cancel();
            return 'saved';
          },
        ),
        throwsA(isA<AiRequestCancelled>()));
    expect(writes, 1);
    expect(ai.requests, 1);
  });

  test('工具等待审批时取消异常不会被当成失败吞掉后继续执行', () async {
    final ai = _ScriptedAi([
      const AiChatRound(content: '', toolCalls: [_call, _call]),
    ]);
    var calls = 0;
    await expectLater(
        ai.runToolLoop(
          provider: _provider,
          apiKey: 'test',
          messages: [],
          tools: _tools,
          executeTool: (_) async {
            calls++;
            throw const AiRequestCancelled();
          },
        ),
        throwsA(isA<AiRequestCancelled>()));
    expect(calls, 1);
  });

  test('已取消的任务不发起请求', () async {
    final ai = _ScriptedAi([]);
    final token = CancelToken()..cancel();
    await expectLater(
        ai.runToolLoop(
          provider: _provider,
          apiKey: 'test',
          messages: [],
          tools: _tools,
          cancelToken: token,
          executeTool: (_) async => '不应执行',
        ),
        throwsA(isA<AiRequestCancelled>()));
    expect(ai.requests, 0);
  });

  test('模型不能执行未提供或已关闭的工具', () async {
    final ai = _ScriptedAi([
      const AiChatRound(content: '', toolCalls: [_call]),
      const AiChatRound(content: '工具不可用'),
    ]);
    var calls = 0;
    final result = await ai.runToolLoop(
      provider: _provider,
      apiKey: 'test',
      messages: [],
      tools: [],
      executeTool: (_) async {
        calls++;
        return '不应执行';
      },
    );
    expect(calls, 0);
    expect(result.calls.single.result, contains('工具未启用'));
  });

  test('取消真正终止正在等待响应的 HTTP 请求', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final received = Completer<void>();
    server.listen((request) async {
      await request.drain<void>();
      received.complete();
      // 故意不响应；客户端必须通过取消退出，而不是等 60 秒超时。
    });
    final token = CancelToken();
    final request = AiService.instance.chatRound(
      provider: _provider.copyWith(baseUrl: 'http://127.0.0.1:${server.port}'),
      apiKey: 'test',
      messages: [],
      cancelToken: token,
    );
    final check = expectLater(request, throwsA(isA<AiRequestCancelled>()));
    await received.future.timeout(const Duration(seconds: 5));
    token.cancel();
    await check.timeout(const Duration(seconds: 2));
  });

  test('限流退避期间取消不重发请求', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final responded = Completer<void>();
    var requests = 0;
    server.listen((request) async {
      requests++;
      await request.drain<void>();
      request.response.statusCode = 429;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'error': {'message': 'busy'}
      }));
      await request.response.close();
      if (!responded.isCompleted) responded.complete();
    });
    final token = CancelToken();
    final request = AiService.instance.chatOnce(
      provider: _provider.copyWith(baseUrl: 'http://127.0.0.1:${server.port}'),
      apiKey: 'test',
      messages: [],
      cancelToken: token,
    );
    final check = expectLater(request, throwsA(isA<AiRequestCancelled>()));
    await responded.future.timeout(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    token.cancel();
    await check.timeout(const Duration(milliseconds: 500));
    expect(requests, 1);
  });
}
