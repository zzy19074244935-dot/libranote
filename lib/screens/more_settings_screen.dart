import 'package:flutter/material.dart';

import 'ai_settings_screen.dart';
import 'appearance_settings_screen.dart';
import 'cache_settings_screen.dart';
import 'countdown_settings_screen.dart';
import 'download_path_settings_screen.dart';
import 'reading_settings_screen.dart';
import 'shot_library_screen.dart';
import 'sync_settings_screen.dart';
import 'translation_settings_screen.dart';
import 'tts_settings_screen.dart';

/// 「更多设置」入口页：各功能模块入口（Phase 5 全部开放）。
class MoreSettingsScreen extends StatelessWidget {
  const MoreSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('更多设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _tile(context, colors, Icons.photo_library_outlined, '截图库',
              '框选截图保存的图片都在这里：查看 / 分享 / 删除', () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ShotLibraryScreen()),
            );
          }),
          _tile(context, colors, Icons.psychology_outlined, 'AI 配置设置',
              '供应商开关 / API Key / 模型 / 推理强度 / 提示词 / AI 工具', () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AiSettingsScreen()),
            );
          }),
          _tile(context, colors, Icons.translate, '翻译设置',
              '翻译开关 / 目标语言 / API 翻译（与 AI 共用 API）/ 测试', () {
            Navigator.of(context).push(
              MaterialPageRoute(
                  builder: (_) => const TranslationSettingsScreen()),
            );
          }),
          _tile(context, colors, Icons.record_voice_over_outlined, '朗读（TTS）',
              '语音引擎 / 音色 / 语速 / 音高 / 试听', () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const TtsSettingsScreen()),
            );
          }),
          _tile(context, colors, Icons.cloud_sync_outlined, '同步设置',
              '坚果云 WebDAV / 自动同步 / 同步范围 / 配置导入导出', () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SyncSettingsScreen()),
            );
          }),
          _tile(context, colors, Icons.menu_book_outlined, '阅读设置',
              '字号 / 行距 / 页边距 / 主题 / 翻页 / 沉浸式', () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ReadingSettingsScreen()),
            );
          }),
          _tile(context, colors, Icons.folder_outlined, '下载路径设置',
              '书籍保存文件夹（与云同步联动）', () {
            Navigator.of(context).push(
              MaterialPageRoute(
                  builder: (_) => const DownloadPathSettingsScreen()),
            );
          }),
          _tile(context, colors, Icons.palette_outlined, '外观总设置',
              '浅色 / 深色 / 跟随系统 / 主色调', () {
            Navigator.of(context).push(
              MaterialPageRoute(
                  builder: (_) => const AppearanceSettingsScreen()),
            );
          }),
          _tile(context, colors, Icons.cleaning_services_outlined, '缓存设置',
              '缓存大小 / 坚果云空间 / 清除缓存', () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const CacheSettingsScreen()),
            );
          }),
          _tile(context, colors, Icons.timer_outlined, '倒计时设置',
              '学习倒计时时长 / 开始暂停 / 到点提醒', () {
            Navigator.of(context).push(
              MaterialPageRoute(
                  builder: (_) => const CountdownSettingsScreen()),
            );
          }),
        ],
      ),
    );
  }

  Widget _tile(BuildContext context, ColorScheme colors, IconData icon,
      String title, String subtitle, VoidCallback onTap) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(icon, color: colors.primary),
        title: Text(title,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
