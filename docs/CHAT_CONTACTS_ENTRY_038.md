# 1.0.38+39：聊天顶部通讯录入口

- 聊天页顶部改为“聊天  通讯录”，通讯录可直接点击。
- 从右上角加号菜单移除“通讯录 / 好友请求”重复入口。
- 复用原 contacts('directory') 页面；好友、请求、建群等功能保持原路由。
- 修改：lib/presentation/chat_page.dart、pubspec.yaml（版本号）。
- 无新增依赖、数据库表、SQL迁移或云端设置。
- flutter analyze lib/presentation/chat_page.dart：No issues found。

- Android debug 编译成功；Xiaomi 14T 覆盖安装成功，保留数据。
- APK：releases/huideng-counter-v1.0.38-39-contacts-entry.apk
