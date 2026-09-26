# 聊天与论坛共用昵称 — 1.0.21 (22)

## 原因与修改
聊天原本已经将昵称保存在 chat_profiles.nickname，但论坛发帖/回复使用独立空白昵称输入框。
现在登录账号的发帖和回复均读取 chat_profiles 的同一份昵称。发布页面只读显示共用昵称，需修改时到聊天顶部修改。
发布前再次读取当前账号昵称，避免缓存或输入参数中的旧名字导致两处不一致；账号变化会拒绝该请求。
本地预览复用按 user_id 隔离的 own_profile 缓存。远程读取失败不使用虚构默认名发布，输入正文保留供重试。
历史帖子的 author_name 快照保留，不批量覆盖旧数据。游客原有输入界面保留；本次没有新增游客发布权限。

## 文件
修改 lib/data/remote/forum_remote.dart、lib/presentation/forum_compose_page.dart。
版本更新 pubspec.yaml、lib/presentation/my_page.dart。
新增 test/forum_shared_name_test.dart。
无新 package，无 SQLite 或 Supabase 表结构修改，无新 SQL。

## 验证
原有论坛 4 项测试通过，改动 Dart 文件静态检查通过。
专项测试覆盖发帖/回复采用最新共享昵称、保留 UUID、昵称不可用时不发送发布请求。
真实账号跨设备改名后的发布显示仍需人工交互验证。
