import 'package:flutter/material.dart';
import '../config/app_config.dart';
import '../services/screenshot_flag.dart';
import 'more_settings_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('应用设置')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          Card(
              child: ListTile(
                  leading: const Icon(Icons.tune_rounded),
                  title: const Text('阅读、AI 与同步'),
                  subtitle: const Text('外观、阅读偏好、服务配置和备份'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const MoreSettingsScreen())))),
          Card(
              child: SwitchListTile(
                  title: const Text('允许截屏'),
                  value: AppConfig.instance.allowScreenshot,
                  onChanged: (value) {
                    setState(() => AppConfig.instance.allowScreenshot = value);
                    ScreenshotFlag.apply();
                  })),
          Card(
              child: ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text('关于 Libranote'),
                  subtitle: const Text('个人实践项目 · 1.1.0'),
                  onTap: () => showAboutDialog(
                      context: context,
                      applicationName: 'Libranote',
                      applicationVersion: '1.1.0',
                      children: [const Text('本地阅读与笔记。网络服务由使用者按需配置。')]))),
        ]),
      );
}
