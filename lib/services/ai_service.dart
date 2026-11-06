import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/ai_models.dart';

/// 用户主动取消；独立于服务错误，不能作为工具失败吞掉或自动重试。
class AiRequestCancelled implements Exception {
  const AiRequestCancelled();

  @override
  String toString() => '任务已取消';
}

/// 一次 AI 请求的结果。
class AiChatResult {
  final String content;
  final int promptTokens;
  final int completionTokens;

  const AiChatResult({
    required this.content,
    this.promptTokens = 0,
    this.completionTokens = 0,
  });
}

/// 模型发出的一次工具调用（OpenAI function calling 的 tool_calls 条目）。
class AiToolCall {
  final String id;
  final String name;
  final String arguments; // 原始 JSON 字符串（执行前 jsonDecode）

  const AiToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });
}

/// 一轮对话的原始结果：正文 + 工具调用（工具循环用）。
class AiChatRound {
  final String content;
  final List<AiToolCall> toolCalls;
  final Map<String, dynamic> rawAssistantMessage; // 含 tool_calls 的原始 message
  final int promptTokens;
  final int completionTokens;

  const AiChatRound({
    required this.content,
    this.toolCalls = const [],
    this.rawAssistantMessage = const {},
    this.promptTokens = 0,
    this.completionTokens = 0,
  });
}

/// 一次工具调用循环里实际执行过的工具记录（AI 中心渲染「工具调用」卡片）。
class AiToolCallRecord {
  final String name;
  final String arguments;
  final String result;

  const AiToolCallRecord({
    required this.name,
    required this.arguments,
    required this.result,
  });
}

/// 工具循环的最终结果。
class AiToolLoopResult {
  final String content;
  final List<AiToolCallRecord> calls;

  const AiToolLoopResult({required this.content, this.calls = const []});
}

/// OpenAI 兼容协议的 AI 服务（DeepSeek / Kimi / Qwen 通用）。
///
/// 不引 langchain：那是为「一套 API 适配多家协议」设计的重型依赖，
/// 而我们只需要 OpenAI 兼容一种协议，dio 直连 + 手写 SSE 解析最可控
/// （还能精确控制流式增量、超时与重试行为）。
class AiService {
  AiService._();
  static final AiService instance = AiService._();

  @visibleForTesting
  AiService.testing();

  /// 流式聊天。onChunk 逐个收增量文本；返回全文与 token 估算。
  ///
  /// 失败兜底：流式请求在**收到任何内容前**就失败时，自动降级为一次
  /// 非流式请求重试（个别中转站不支持 stream:true）。
  Future<AiChatResult> chatStream({
    required AiProviderConfig provider,
    required String apiKey,
    required List<Map<String, String>> messages,
    required void Function(String delta) onChunk,
    String? systemPrompt,
    List<Map<String, dynamic>>? tools,
  }) async {
    final url = '${provider.baseUrl}/chat/completions';
    var gotAnyContent = false;
    final full = StringBuffer();

    try {
      await _streamOnce(
        url: url,
        apiKey: apiKey,
        provider: provider,
        messages: messages,
        systemPrompt: systemPrompt,
        tools: tools,
        onChunk: (delta) {
          gotAnyContent = true;
          full.write(delta);
          onChunk(delta);
        },
      );
      return AiChatResult(
        content: full.toString(),
        completionTokens: estimateTokens(full.toString()),
      );
    } catch (e) {
      // 已经吐过内容再失败 → 把已有内容抛回给 UI 层处理（宁可半截也不
      // 静默丢弃）；完全没吐过 → 走非流式兜底。
      if (gotAnyContent) rethrow;
      debugPrint('[AI] stream failed, fallback to non-stream: $e');
      return chatOnce(
        provider: provider,
        apiKey: apiKey,
        messages: messages,
        systemPrompt: systemPrompt,
        tools: tools,
      );
    }
  }

  /// 非流式聊天（流式失败时的兜底，也供后续工具调用循环复用）。
  Future<AiChatResult> chatOnce({
    required AiProviderConfig provider,
    required String apiKey,
    required List<Map<String, dynamic>> messages,
    String? systemPrompt,
    List<Map<String, dynamic>>? tools,
    CancelToken? cancelToken,
  }) async {
    final url = '${provider.baseUrl}/chat/completions';
    final body = <String, dynamic>{
      'model': provider.model,
      'messages': [
        if (systemPrompt != null && systemPrompt.isNotEmpty)
          {'role': 'system', 'content': systemPrompt},
        ...messages,
      ],
      'stream': false,
      // 推理模型（kimi-k2/k3 等）只接受 temperature=1。
      'temperature': provider.fixedTemperature ? 1 : provider.temperature,
    };
    if (tools != null && tools.isNotEmpty) body['tools'] = tools;

    final resp = await _postChat(url, apiKey, body, cancelToken: cancelToken);
    final data =
        resp is Map<String, dynamic> ? resp : jsonDecode(resp as String);
    final choices = (data['choices'] as List?) ?? [];
    if (choices.isEmpty) {
      throw const AiServiceException('模型没有返回内容，请换一个模型试试');
    }
    final message = (choices.first as Map)['message'] as Map? ?? {};
    final content = (message['content'] as String?) ?? '';
    final usage = (data['usage'] as Map?) ?? {};
    return AiChatResult(
      content: content,
      promptTokens: (usage['prompt_tokens'] as num?)?.toInt() ?? 0,
      completionTokens: (usage['completion_tokens'] as num?)?.toInt() ?? 0,
    );
  }

  /// 一轮对话（带工具调用解析；Phase 6 工具循环用）。
  ///
  /// 与 [chatOnce] 的区别：返回原始 assistant message（含 tool_calls
  /// 完整 JSON），工具循环要把这条原样回填进上下文再喂 tool 结果——
  /// 各家 OpenAI 兼容实现都要求 tool_calls 原样回传。
  Future<AiChatRound> chatRound({
    required AiProviderConfig provider,
    required String apiKey,
    required List<Map<String, dynamic>> messages,
    String? systemPrompt,
    List<Map<String, dynamic>>? tools,
    CancelToken? cancelToken,
  }) async {
    final url = '${provider.baseUrl}/chat/completions';
    final body = <String, dynamic>{
      'model': provider.model,
      'messages': [
        if (systemPrompt != null && systemPrompt.isNotEmpty)
          {'role': 'system', 'content': systemPrompt},
        ...messages,
      ],
      'stream': false,
      // 推理模型（kimi-k2/k3 等）只接受 temperature=1。
      'temperature': provider.fixedTemperature ? 1 : provider.temperature,
    };
    if (tools != null && tools.isNotEmpty) body['tools'] = tools;

    final resp = await _postChat(url, apiKey, body, cancelToken: cancelToken);
    final data =
        resp is Map<String, dynamic> ? resp : jsonDecode(resp as String);
    final choices = (data['choices'] as List?) ?? [];
    if (choices.isEmpty) {
      throw const AiServiceException('模型没有返回内容，请换一个模型试试');
    }
    final message = (choices.first as Map)['message'] as Map? ?? {};
    final content = (message['content'] as String?) ?? '';
    final rawCalls = (message['tool_calls'] as List?) ?? [];
    final toolCalls = <AiToolCall>[];
    for (final raw in rawCalls) {
      if (raw is! Map) continue;
      final fn = raw['function'];
      if (fn is! Map) continue;
      final name = fn['name']?.toString();
      if (name == null || name.isEmpty) continue;
      toolCalls.add(AiToolCall(
        id: raw['id']?.toString() ?? 'call_${toolCalls.length}',
        name: name,
        arguments: fn['arguments']?.toString() ?? '{}',
      ));
    }
    final usage = (data['usage'] as Map?) ?? {};
    return AiChatRound(
      content: content,
      toolCalls: toolCalls,
      rawAssistantMessage: Map<String, dynamic>.from(message),
      promptTokens: (usage['prompt_tokens'] as num?)?.toInt() ?? 0,
      completionTokens: (usage['completion_tokens'] as num?)?.toInt() ?? 0,
    );
  }

  /// 工具调用循环（Phase 6）：
  /// 模型发 tool_calls → 本地执行 → 结果回喂 → 再问，最多 5 轮；
  /// 拿到纯文本回答即结束。5 轮仍不完则去掉工具直接收尾一次。
  ///
  /// [executeTool] 由 AI 工具层提供（ai_tools.dart 按名字分发）。
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
    final msgs = <Map<String, dynamic>>[
      for (final m in messages) Map<String, dynamic>.from(m),
    ];
    final executed = <AiToolCallRecord>[];
    final allowedNames = {
      for (final tool in tools ?? <Map<String, dynamic>>[])
        (tool['function'] as Map?)?['name'],
    };
    for (var round = 0; round < 5; round++) {
      _checkCancelled(cancelToken);
      final resp = await chatRound(
        provider: provider,
        apiKey: apiKey,
        messages: msgs,
        systemPrompt: systemPrompt,
        tools: tools,
        cancelToken: cancelToken,
      );
      _checkCancelled(cancelToken);
      if (resp.toolCalls.isEmpty) {
        return AiToolLoopResult(content: resp.content, calls: executed);
      }
      // 回填 assistant 消息（保留 tool_calls 原始 JSON——供应商要求原样回传）。
      if (resp.rawAssistantMessage.isNotEmpty) {
        msgs.add(resp.rawAssistantMessage);
      } else {
        msgs.add({'role': 'assistant', 'content': resp.content});
      }
      for (final call in resp.toolCalls) {
        _checkCancelled(cancelToken);
        onToolCall?.call(call.name);
        _checkCancelled(cancelToken);
        String result;
        try {
          result = allowedNames.contains(call.name)
              ? await executeTool(call)
              : '工具未启用或不在本次任务的可用列表：${call.name}';
        } on AiRequestCancelled {
          rethrow;
        } catch (e) {
          result = '工具执行失败：$e';
        }
        _checkCancelled(cancelToken);
        executed.add(AiToolCallRecord(
            name: call.name, arguments: call.arguments, result: result));
        msgs.add({
          'role': 'tool',
          'tool_call_id': call.id,
          'content': result,
        });
      }
    }
    // 轮数用完：不带工具直接收尾，保证用户总能看到一句话回答。
    _checkCancelled(cancelToken);
    final last = await chatOnce(
      provider: provider,
      apiKey: apiKey,
      messages: msgs,
      systemPrompt: systemPrompt,
      cancelToken: cancelToken,
    );
    _checkCancelled(cancelToken);
    return AiToolLoopResult(content: last.content, calls: executed);
  }

  /// 拉取模型列表（GET {base}/models）。
  Future<List<String>> fetchModels({
    required AiProviderConfig provider,
    required String apiKey,
  }) async {
    final url = '${provider.baseUrl}/models';
    final dio = _newDio();
    try {
      final resp = await dio.get<dynamic>(
        url,
        options: Options(
          headers: {'Authorization': 'Bearer $apiKey'},
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      if (resp.statusCode == 401) {
        throw const AiServiceException('API Key 无效（401），请检查后重试');
      }
      if (resp.statusCode != 200) {
        throw AiServiceException(
            '获取模型列表失败（HTTP ${resp.statusCode}），请检查 API 地址与 Key');
      }
      final data =
          resp.data is String ? jsonDecode(resp.data as String) : resp.data;
      final models = (data is Map ? data['data'] : null) as List? ?? [];
      final ids = <String>[];
      for (final m in models) {
        final id = (m is Map ? m['id'] : m.toString()) as String?;
        if (id != null && id.isNotEmpty && !ids.contains(id)) ids.add(id);
      }
      ids.sort();
      return ids;
    } on DioException catch (e) {
      throw _mapDioError(e);
    } finally {
      dio.close();
    }
  }

  /// 粗略 token 估算：中日韩全角字符 ≈ 1 token/字，其余 ≈ 4 字符/ token。
  /// 只用于对话列表统计展示，不追求精确。
  static int estimateTokens(String text) {
    if (text.isEmpty) return 0;
    var cjk = 0;
    var other = 0;
    for (final rune in text.runes) {
      final isCjk = (rune >= 0x4E00 && rune <= 0x9FFF) ||
          (rune >= 0x3000 && rune <= 0x30FF) ||
          (rune >= 0xFF00 && rune <= 0xFFEF);
      if (isCjk) {
        cjk++;
      } else {
        other++;
      }
    }
    return (cjk + (other / 4).ceil()).clamp(1, 1 << 30);
  }

  // ── 内部 ───────────────────────────────────────────────────────────

  /// 单次流式请求（SSE 手写解析）。
  Future<void> _streamOnce({
    required String url,
    required String apiKey,
    required AiProviderConfig provider,
    required List<Map<String, String>> messages,
    String? systemPrompt,
    List<Map<String, dynamic>>? tools,
    required void Function(String delta) onChunk,
  }) async {
    final body = <String, dynamic>{
      'model': provider.model,
      'messages': [
        if (systemPrompt != null && systemPrompt.isNotEmpty)
          {'role': 'system', 'content': systemPrompt},
        ...messages,
      ],
      'stream': true,
      // 推理模型（kimi-k2/k3 等）只接受 temperature=1。
      'temperature': provider.fixedTemperature ? 1 : provider.temperature,
    };
    if (tools != null && tools.isNotEmpty) body['tools'] = tools;

    final dio = _newDio();
    try {
      final resp = await dio.post<ResponseBody>(
        url,
        data: body,
        options: Options(
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Accept': 'text/event-stream',
          },
          responseType: ResponseType.stream,
        ),
      );
      final stream = resp.data!.stream;
      const decoder = Utf8Decoder();
      var buffer = '';
      await for (final chunk in stream) {
        buffer += decoder.convert(chunk);
        // SSE 帧按行切；半行留在 buffer 等下一个 chunk。
        int idx;
        while ((idx = buffer.indexOf('\n')) >= 0) {
          final line = buffer.substring(0, idx).trimRight();
          buffer = buffer.substring(idx + 1);
          if (!line.startsWith('data:')) continue;
          final payload = line.substring(5).trim();
          if (payload.isEmpty) continue;
          if (payload == '[DONE]') return;
          try {
            final obj = jsonDecode(payload);
            if (obj is! Map) continue;
            final choices = obj['choices'];
            if (choices is List && choices.isNotEmpty) {
              final delta = (choices.first as Map?)?['delta'];
              if (delta is Map && delta['content'] is String) {
                onChunk(delta['content'] as String);
              }
            }
          } catch (_) {
            // 半行 JSON（chunk 边界切开）或非 JSON 帧：跳过，不中断流。
          }
        }
      }
      if (buffer.trim().isNotEmpty) {
        // 最后一行没有换行符（个别服务端）：再按 data: 解一次。
        final line = buffer.trimRight();
        if (line.startsWith('data:')) {
          final payload = line.substring(5).trim();
          if (payload.isNotEmpty && payload != '[DONE]') {
            try {
              final obj = jsonDecode(payload);
              final choices = obj['choices'];
              if (choices is List && choices.isNotEmpty) {
                final delta = (choices.first as Map?)?['delta'];
                if (delta is Map && delta['content'] is String) {
                  onChunk(delta['content'] as String);
                }
              }
            } catch (_) {}
          }
        }
      }
    } on DioException catch (e) {
      throw _mapDioError(e);
    } finally {
      dio.close();
    }
  }

  /// 聊天请求专用 POST：服务端若因 temperature 拒绝（推理模型只接受 1），
  /// 自动改成 temperature=1 重试一次——用户不勾「温度固定」也能自愈。
  Future<dynamic> _postChat(
      String url, String apiKey, Map<String, dynamic> body,
      {CancelToken? cancelToken}) async {
    try {
      return await _postWithRetry(url, apiKey, body, cancelToken: cancelToken);
    } on AiServiceException catch (e) {
      if (!e.message.contains('temperature')) rethrow;
      final temp = body['temperature'];
      if (temp is num && temp == 1) rethrow;
      debugPrint('[AI] server rejects temperature=$temp, retry with 1');
      final retry = Map<String, dynamic>.from(body)..['temperature'] = 1;
      return await _postWithRetry(url, apiKey, retry, cancelToken: cancelToken);
    }
  }

  /// POST + 重试：429 / 5xx / 超时指数退避重试 2 次，其余直接抛。
  Future<dynamic> _postWithRetry(
      String url, String apiKey, Map<String, dynamic> body,
      {CancelToken? cancelToken}) async {
    final dio = _newDio();
    DioException? last;
    try {
      for (var attempt = 0; attempt < 3; attempt++) {
        _checkCancelled(cancelToken);
        if (attempt > 0) {
          await _retryDelay(Duration(seconds: attempt * attempt), cancelToken);
        }
        _checkCancelled(cancelToken);
        try {
          final resp = await dio.post<dynamic>(
            url,
            data: body,
            cancelToken: cancelToken,
            options: Options(
              headers: {'Authorization': 'Bearer $apiKey'},
              validateStatus: (s) => s != null && s < 500,
            ),
          );
          if (resp.statusCode == 429) {
            last = DioException(
              requestOptions: resp.requestOptions,
              response: resp,
              type: DioExceptionType.badResponse,
            );
            continue;
          }
          if (resp.statusCode != 200) {
            throw _mapDioError(DioException(
              requestOptions: resp.requestOptions,
              response: resp,
              type: DioExceptionType.badResponse,
            ));
          }
          return resp.data;
        } on DioException catch (e) {
          if (CancelToken.isCancel(e)) throw const AiRequestCancelled();
          final retryable = e.type == DioExceptionType.connectionTimeout ||
              e.type == DioExceptionType.receiveTimeout ||
              e.type == DioExceptionType.sendTimeout ||
              (e.response?.statusCode != null &&
                  e.response!.statusCode! >= 500);
          if (!retryable) {
            throw _mapDioError(e);
          }
          last = e;
        }
      }
      throw _mapDioError(last!);
    } finally {
      dio.close();
    }
  }

  static void _checkCancelled(CancelToken? token) {
    if (token?.isCancelled == true) throw const AiRequestCancelled();
  }

  static Future<void> _retryDelay(Duration delay, CancelToken? token) async {
    final elapsed = Completer<void>();
    final timer = Timer(delay, elapsed.complete);
    try {
      await Future.any([
        elapsed.future,
        if (token != null) token.whenCancel.then((_) {}),
      ]);
      _checkCancelled(token);
    } finally {
      timer.cancel();
    }
  }

  Dio _newDio() {
    return Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 60),
      // 流式响应第一字节前会有一段时间静默，receiveTimeout 只卡两次
      // 数据包之间的间隔，不会误杀正常流。
    ));
  }

  /// 把 Dio 错误翻译成中文人话（网络层只抛异常，UI 层直接展示）。
  ///
  /// badResponse 一定要带上 HTTP 状态码和服务端返回的 error.message：
  /// 旧版把 400/413/422 等状态全塌缩成一句「badResponse」，用户看到
  /// 这个报错无从下手（Kimi 模型下线/拼错时就是这种表现）。
  AiServiceException _mapDioError(DioException e) {
    final status = e.response?.statusCode;
    String? serverMsg;
    try {
      final data = e.response?.data;
      if (data is Map) {
        final err = data['error'];
        if (err is Map && err['message'] is String) {
          serverMsg = (err['message'] as String).trim();
        } else if (data['message'] is String) {
          serverMsg = (data['message'] as String).trim();
        }
      } else if (data is String && data.trim().isNotEmpty) {
        serverMsg = _shortBody(data);
      }
    } catch (_) {
      // 响应体可能不是 JSON（如流式错误），拿不到就算了。
    }
    final detail =
        serverMsg != null && serverMsg.isNotEmpty ? '：$serverMsg' : '';

    if (status == 401) {
      return const AiServiceException('API Key 无效（401），请在设置里检查');
    }
    if (status == 402 || status == 403) {
      return AiServiceException('账号余额不足或无权限（$status）$detail，请到供应商后台检查');
    }
    if (status == 404) {
      return const AiServiceException('API 地址或模型名有误（404），请检查配置');
    }
    if (status == 429) {
      return const AiServiceException('请求太频繁（429），请稍后再试');
    }
    if (status == 400 || status == 413 || status == 422) {
      return AiServiceException('请求被拒绝（$status）$detail\n'
          '常见原因：模型名填错/已下线、上下文太长、'
          '或推理模型要求 temperature=1（供应商设置里可勾「温度固定为 1」）。');
    }
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
        return const AiServiceException('请求超时，请检查网络或 API 地址');
      case DioExceptionType.connectionError:
        return const AiServiceException('网络连接失败，请检查网络');
      default:
        if (status != null) {
          return AiServiceException('请求失败（HTTP $status）$detail');
        }
        return AiServiceException('请求失败：${e.message ?? e.type.name}');
    }
  }

  /// 非 JSON 错误响应体压成一行（最多 200 字符）。
  static String _shortBody(String s) {
    final one = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length <= 200 ? one : '${one.substring(0, 200)}…';
  }
}

/// 带中文文案的 AI 异常（UI 层直接 show 出来即可）。
class AiServiceException implements Exception {
  final String message;
  const AiServiceException(this.message);

  @override
  String toString() => message;
}
