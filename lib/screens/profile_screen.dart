import 'package:flutter/material.dart';
import '../widgets/app_shell.dart';
import 'settings_screen.dart';
import 'more_settings_screen.dart';
import 'word_card_list_screen.dart';
import 'photo_translate_screen.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('我的'), actions: const [
        Padding(padding: EdgeInsets.only(right: 16), child: AppAvatar()),
      ]),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
                color: colors.primaryContainer,
                borderRadius: BorderRadius.circular(24)),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Libranote',
                  style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w600,
                      color: colors.onPrimaryContainer)),
              const SizedBox(height: 8),
              Text('阅读、思考与记录',
                  style: TextStyle(color: colors.onPrimaryContainer)),
            ])),
        const SizedBox(height: 16),
        _entry(context, Icons.settings_outlined, '应用设置', '阅读偏好与隐私',
            const SettingsScreen()),
        _entry(context, Icons.tune_rounded, '更多设置', 'AI、翻译、外观、备份与同步',
            const MoreSettingsScreen()),
        _entry(context, Icons.style_outlined, '单词卡片', '需自行部署后端并配置服务',
            const WordCardListScreen()),
        _entry(context, Icons.translate_rounded, '拍照翻译', '图片识别与按需翻译',
            const PhotoTranslateScreen()),
        const Padding(
            padding: EdgeInsets.all(16),
            child: Text('本地阅读无需账号。AI、翻译和云同步仅在配置并使用相应功能时连接外部服务。')),
      ]),
    );
  }

  Widget _entry(BuildContext context, IconData icon, String title,
          String subtitle, Widget screen) =>
      Card(
          child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => screen)),
      ));
}
