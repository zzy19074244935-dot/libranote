import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// 选中文字 →「搜索」：直接跳到系统浏览器网页搜索。
///
/// 用户要求：不再打开 App 内的「发现图书」搜索页，改为浏览器搜索
/// （默认 Bing 国内版，Google 在国内不可达）。失败时复制搜索链接提示。
Future<void> openWebSearch(String text, {BuildContext? context}) async {
  final q = text.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (q.isEmpty) return;
  final uri = Uri.parse(
      'https://cn.bing.com/search?q=${Uri.encodeQueryComponent(q)}');
  try {
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok) throw Exception('launchUrl returned false');
  } catch (e) {
    debugPrint('[WebSearch] open failed: $e');
    // 失败兜底：复制搜索词，用户手动粘贴到浏览器。
    await Clipboard.setData(ClipboardData(text: q));
    if (context != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('无法打开浏览器，搜索词「$q」已复制，请手动粘贴搜索'),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }
}
