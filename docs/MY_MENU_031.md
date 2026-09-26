# 我的菜单排序（1.0.31+32）

用户确认：将现有云同步与存储改名为网盘并移动，非新增文件管理功能。
顺序：供佛/供灯、论坛、共修、网盘、收藏、账号与同步、关于与联系、设置。
StorageStatusPage标题同步改为网盘。原有页面目标、连接测试和本地备份恢复均保留。
修改my_page.dart及pubspec.yaml；无数据库、依赖、同步变更。
静态检查通过。逐项核对入口与原功能保持对应。

Android构建成功（255.9秒）。Xiaomi 14T覆盖安装Success，核实versionName=1.0.31/versionCode=32，冷启动Status: ok。APK归档releases/huideng-counter-v1.0.31-32-my-menu.apk。未自动操作菜单做视觉验收。
