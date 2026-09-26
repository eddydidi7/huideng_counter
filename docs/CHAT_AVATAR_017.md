# 聊天头像（1.0.27+28）

- 默认头像使用用户提供的原始四臂观音图片，随 App 打包；不需要网络。界面用圆形头像显示，原图文件未改写。
- 接入会话列表（个人会话）、通讯录、个人资料和消息标题。群头像保留群图标。
- 聊天 → ＋ → 我的头像：从相册选择、恢复默认。
- 自定义图片压缩为 JPEG，源图片最大10MB，处理后最大2MB；通过已有 Supabase Auth 保存自己的 avatar_path，其他登录用户读取当前头像。
- 头像短期缓存约一分钟。无网络或加载失败回退到默认图；并未实现自定义头像的永久离线图片缓存。
- 恢复默认只清除自己账号的头像引用，不删除旧上传文件或其他数据。签发的访问链接最多五分钟后过期。

## 文件
新增 assets/images/default_chat_avatar.png、lib/presentation/chat_avatar.dart、supabase/migrations/202609170017_chat_avatars.sql、本文及 work/admin-sql-tests/chat-avatars.mjs。
修改 chat_page.dart、chat_contacts_page.dart、chat_room_page.dart、pubspec.yaml；my_page.dart 仅版本号。
没有新增 Flutter package、SQLite 表或计数／笔记迁移。

## SQL 与安全
017 增加 chat_profiles.avatar_path、私有 chat-avatars 桶及 chat_avatar_v1。只能上传自己账号目录，并且仅能将已存在、大小合规的自己图片设置为头像。匿名请求不能设置头像。
默认图片无需017；更换头像和跨账号查看自定义头像需要017。

## 验证
四个 Dart 文件静态检查通过。本地 PostgreSQL 兼容环境测试通过：自己的上传、未启用图片隐私、已启用头像读取、跨账号设置被拒、恢复默认、匿名修改被拒。
尚未完成两账号真机头像上传／同步验收。

2026-09-17：用户确认“017成功”。Android debug APK 编译成功（223.3秒），归档至 releases/huideng-counter-v1.0.27-28-chat-avatar.apk。已使用 adb install -r 覆盖安装至 Xiaomi 14T，返回 Success；设备核实 versionName=1.0.27、versionCode=28。冷启动 Status: ok，本次读取的启动错误日志无输出。尚未实测相册选择及两账号头像同步。
