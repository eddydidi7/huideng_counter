# Supabase 客户端接入记录

日期：2026-09-15。基于现有 Flutter 工程增量修改。服务端项目仍为 `huideng-counter-test`，没有重建项目或重新执行初始 SQL。

## 本次代码范围

| 文件或目录 | 用途 |
|---|---|
| lib/core/cloud_controller.dart | Auth 登录、注册、退出、恢复账号、前后台同步调度、冲突选择 |
| lib/data/remote/secure_auth_storage.dart | 使用 flutter_secure_storage 持久化会话；不把 token 放入 SQLite |
| lib/data/remote/supabase_sync_gateway.dart | 三个 RPC 的真实网络实现、私有图片上传下载、账号校验 |
| lib/data/local/account_database_manager.dart | 每账号独立数据库、访客记录认领与重复导入去重 |
| lib/data/local/migrations/migration_v4.dart | 追加云图片映射、远端文档缓存、有符号余额、访客认领表、事件冻结负载列与图片队列触发器 |
| lib/data/sync/snapshot_builder.dart | 原数据库记录转换为协议负载；项目元数据不带总数或本机图片路径 |
| lib/data/sync/remote_projector.dart | 云端事件补回本地历史、今日计数、累计余额；恢复项目、排序和设置 |
| lib/data/sync/local_sync_store.dart、sync_coordinator.dart | 队列 ACK、失败重试、图片完成后提交元数据、游标事务与账号切换隔离 |
| lib/presentation/account_panel.dart、app_shell.dart | “我的”登录表单、导入、状态、冲突界面，中英双语 |
| lib/presentation/counter_page.dart、project_editor.dart | 操作绑定原账号仓库；计数页监听合并结果；图片按账号存放 |
| lib/data/repositories/sqlite_counter_repository.dart、lib/domain/models.dart | 读取完整事件余额，保留旧 total 列；不自动关闭其他设备的进行中会话 |
| lib/main.dart、lib/core/app_controller.dart | 启动云服务与切换账号时重建导航 |
| android/app/src/main/AndroidManifest.xml | 添加正式网络权限 |
| pubspec.yaml、pubspec.lock | 添加 supabase_flutter、flutter_secure_storage、crypto |
| test/sync_projection_test.dart、test/account_ui_test.dart | SQLite 双设备同步、图片竞争、访客隔离、双语登录与切换账号测试 |

旧项目、会话、计数、校正及设置表保留。打开旧库前执行备份，数据库版本升级为 4；新增表不替换原数据。没有卸载手机应用或删除手机数据。

## 数据流

1. 本地 SQLite 事务保存每个 UUID 事件并入队，网络请求在计数事务之外。
2. 登录后打开 `accounts/<user_id>/huideng.sqlite`。访客库仍在原位置，登录不自动上传访客数据。
3. “导入本地访客记录”在用户确认后复制项目、图片、历史。保留原 UUID 与已知 device_id；每个访客项目只能归属一个账号。原访客记录不删除。
4. 项目先上传元数据，事件以 UUID 去重；项目/设置/排序/会话使用服务端版本比较。事件合计来自所有 delta，count_after 只是当时的观察值。
5. 图片使用私有 `counter-images/<user_id>/<project_id>/<sha256>.<extension>`。重复上传校验已有内容；下载校验摘要后写入账号缓存，不覆盖下载期间新选的图片。
6. 应用前台每 15 秒检查同步，失败按指数退避重试，恢复前台后继续；不承诺后台或锁屏常驻同步。last_sync_at 只在完整拉取且队列清空后更新。

手动“设置为 N”以执行时本地余额计算 delta；另一台设备随后上传的计数仍会加入。并发减少导致负数时，界面显示真实负余额，保留全部事件并提示人工追加校正；不会偷偷归零。极端超范围余额也保留原始字符串，无法用单条合法校正解决时需人工审计账本。

## 真实手机与 Windows 验收步骤

1. 覆盖安装本次成功构建的 APK，保持相同应用 ID 和签名；不要卸载旧版，以保留设备本地数据。
2. 在“我的”注册并确认邮箱，再登录；或者使用已经确认的测试账号。密码直接填入 APP，不要发到聊天。
3. 登录后会显示账号项目；需要保留原访客记录到云端时，选择“导入本地访客记录”。
4. 新建项目、选图片、计数后点击“立即同步”，检查待同步归零、完整同步时间更新。
5. 第二台设备登录同一账号，核对项目、图片、排序和历史。两台各断网计数，恢复网络后应合并增量，无重复事件。
6. 用第二个账号验证无法看到第一个账号的项目；退出后显示访客库，再次登录原账号恢复其离线库。
7. 两台同时改名称或排序，确认出现可选择的冲突；不要对计数事件做覆盖选择。

## 仍待完成的外部配置与验收

- **SMTP**：当前默认服务只向项目团队邮箱发信，普通用户注册前必须配置发信服务。控制台 Authentication → Email → SMTP Settings 填入发信地址、名称、host、port、用户名和密码；密码由用户在控制台输入。参考 [Supabase 官方 SMTP 文档](https://supabase.com/docs/guides/auth/auth-smtp)。没有关闭邮箱确认来绕过此限制。
- **邮件确认落地页与找回密码**：当前采用邮箱确认后回 APP 密码登录；尚未配置产品落地页、深链接或找回密码流程。默认确认链接可能跳转到未设置的 Site URL，需要在真实注册验收时配置。
- **真实端到端测试**：自动测试使用独立 SQLite 和模拟 RPC 协议；服务端已做数据库角色级隔离测试。真实 Auth HTTP、图片上传下载、双设备和跨运营商网络仍需实测，不能据此宣称已全部通过。
- **Windows/iOS**：协议和 Dart 代码共用；Windows 还需 C++ 工作负载、Windows SDK、开发者模式及实际打包；iOS 需 macOS/Xcode、签名与安全存储真机验收。本次未生成 Windows 或 iOS 安装包。
- **地区**：当前实际为 Supabase 东京托管项目，并非阿里云香港自建。尚未验证中国大陆所有运营商的 Auth/API/Storage 可达性。
- **藏历与论坛**：仍打开已有外部网站。Supabase 账号不会自动登录第三方论坛；网站统一身份认证需要网站方另行接入。

## 构建配置

公开测试 URL/key 已在 CloudController 中提供默认值，可使用 `--dart-define-from-file=config/supabase.test.json` 指定公开配置。应用中不包含 service_role、secret key 或数据库密码。发布正式环境前应替换公开配置并完成上述验收。

构建与最终验证结果以本次交付消息为准；目录中旧 APK 的存在不能证明新版已构建成功。
