# 后台群发文件 + 版本发布：服务端契约与联调说明

本次改动覆盖了下面这张图里的三段：

```
【后台管理APP】  ×（不在本仓库，我碰不到，见下方"人工配置"）
        ↓
【服务端 / Supabase】  ✅ 本次已完成（migration + RPC）
        ↓
【Android 用户APP】    ✅ 本次已完成（lib/ 内代码）
        ↓
【Windows 用户APP】    ✅ 本次已完成（同一套 Flutter 代码）
```

第一段（后台管理APP，`huideng_admin`/`文殊计数器后台管理`）只存在于本地
`C:\Users\eddyd\Documents\Codex\2026-09-15\...`，没有推送到本会话能访问的
GitHub 仓库，所以这份文档同时充当"服务端 API 契约"，供那边的开发（无论是你
自己还是另一个 Codex 会话）对接。

## 一、需要人工执行的部分（不能跳过）

这几个 SQL 文件已经写在仓库里，但**没有**在这次会话里被部署到你的 Supabase
项目——我没有你生产库的连接权限。你需要自己登录 Supabase 控制台的
**SQL Editor**，按顺序粘贴执行（和之前 074/075 的部署方式一样）：

1. `supabase/migrations/202609290076_admin_broadcast.sql`
   —— 新建群发文件系统（表、RLS、Storage 桶、RPC、Realtime）
2. `supabase/migrations/202609290077_app_releases_platform.sql`
   —— 给版本发布表加 `platform` 字段（Android / Windows 分开）

**验证方法**：执行完后在 SQL Editor 里跑：

```sql
select to_regprocedure('public.huideng_admin_broadcast(uuid,text,jsonb,uuid)') is not null as broadcast_rpc,
       to_regprocedure('public.broadcast_inbox_v1(text,jsonb)') is not null as inbox_rpc,
       exists(select 1 from information_schema.columns where table_name='app_releases' and column_name='platform') as platform_column;
```

三个都应该是 `true`。

此外，`huideng_admin_broadcast` 和 `huideng_admin_releases` 都要求调用者在
`admin_private.members` 里有一条 `role in ('super_admin','admin')` 且
`enabled=true` 的记录——这张表本身不在本仓库的 migration 历史里（是当初在
控制台手动建的），所以确认一下你用来调后台接口的管理员账号已经在这张表里，
否则会收到 `forbidden` 错误。

## 二、后台管理APP 需要对接的接口（服务端契约）

后台管理APP 用 **service_role key** 直连 Supabase（和现有的
`huideng_admin_releases`、`huideng_admin_jieyuan` 完全一样的方式，绕过 RLS），
调用下面这个新 RPC：

```
select public.huideng_admin_broadcast(
  actor := '<管理员的 auth.users.id>'::uuid,
  action := '<见下表>',
  payload := '<jsonb>'::jsonb,
  request_id := gen_random_uuid()  -- 每次点击生成新的，重复点击用同一个 id 幂等
);
```

| action | payload | 说明 |
|---|---|---|
| `levels.set` | `{"user_id": "...", "level": 1-5}` | 设置一个用户的群发分级（`app_broadcast_levels`，与结缘等级完全独立）。没设置过的用户默认 level=1。 |
| `send` | 见下 | 发起一次群发，见下方详细说明。 |
| `list` | `{}` | 返回最近 200 条群发记录，含 `recipient_count`/`read_count`/`downloaded_count`。 |
| `detail` | `{"broadcast_id": "..."}` | 返回某次群发的完整收件人列表及各自的 `read_at`/`downloaded_at`。 |

### `send` 的 payload

```json
{
  "title": "可选标题",
  "note": "可选说明",
  "file_name": "test.pdf",
  "target_type": "all | users | level",
  "target_ids": ["user-uuid", "..."],   // 仅 target_type=users 时必填，最多 5000 个
  "target_level": 3,                     // 仅 target_type=level 时必填，1-5

  // 文件来源二选一，不能同时给，也不能都不给：

  // 方式 A：新上传的文件（先用 service_role 把文件上传到 Storage 的
  // broadcast-files 桶，路径随意，比如 "2026/xxx.pdf"，再传路径）
  "storage_path": "2026/xxx.pdf",

  // 方式 B：复用一个已有的 https 链接（不占用新的 Storage 空间，
  // 典型用法：复用某个已发布版本的 download_url，见下方"55 条"的
  // "群发与新版联动"）
  "download_url": "https://.../huideng-1.0.72.apk",
  "file_size": 12345678,   // 方式 B 必填；方式 A 会自动从 Storage 对象读取
  "sha256": "64位十六进制，可选但强烈建议"
}
```

返回：`{"broadcast_id": "...", "recipient_count": 128, "target_type": "all", "failed": 0}`。
`failed` 只在 `target_type="users"` 时有意义，表示 `target_ids` 里有多少个 id
没能解析成真实用户（不存在或已封禁）。

### 群发与新版联动（对应你原始需求的第 54 条）

不要把 APK 重新上传一份到 `broadcast-files`。做法：先调用已有的
`huideng_admin_releases` 的 `releases.list`，拿到目标版本那一行的
`download_url` / `apk_size` / `sha256` / `version_name`，直接作为
`send` 的 `download_url` / `file_size` / `sha256` / `file_name` 传进去——
服务端两边引用的是同一个文件，不会重复占用存储。

## 三、用户端（Android / Windows）如何接收

- 服务端：`public.broadcast_inbox_v1(p_action, p_data)`，`authenticated` 角色可调，
  三个 action：`list`（`{"limit": 200}`）、`mark_read`（`{"broadcast_id":"..."}`）、
  `mark_downloaded`（同上）。
- 客户端：`lib/services/broadcast_inbox.dart` 的 `BroadcastInbox` 单例。
  由 `lib/presentation/content_link_host.dart` 在登录状态变化时自动
  `ensure()`/`stop()`，内部开一个 Realtime 频道监听
  `admin_broadcast_recipients`（按 `user_id` 过滤），同时保留 30 秒轮询兜底
  离线补同步。
- UI：`lib/presentation/file_assistant_page.dart` 顶部会列出后台群发的文件
  （下载 → 校验 SHA-256 → `OpenFilex.open`），"聊天"页的"文件传输助手"
  入口徽标数字会包含未读群发数（`lib/presentation/chat_page.dart`）。
- Android 和 Windows 用的是同一份 Dart 代码（这个仓库本身就是跨平台
  Flutter 项目），所以两端天然共享同一套逻辑，不存在"Android 做了
  Windows 没接"的问题。

## 四、版本发布：Android / Windows 分开

- `app_releases` 新增 `platform` 列（`android`/`windows`/`ios`），
  `version_code` 仍然是全局唯一的主键——**没有改成按平台复用号段**，
  为了不动现有主键。发布 Windows 版本时请使用和 Android 不重叠的
  `version_code` 区间（建议 Windows 从 100000 起步），否则会因为
  主键冲突发布失败。
- `huideng_admin_releases` 的 `releases.save` 现在接受 `payload.platform`
  （不传默认 `android`，向后兼容你现有的调用）。
- 撤回发布（对应第 49 条）：**不需要新接口**，就是再调一次 `releases.save`，
  把同一个 `version_code` 的 `is_published` 设为 `false`。客户端每次都是
  实时查询 `is_published=true` 的最新版本，撤回后未更新用户的"新版本"
  提示会在下次检查时自动消失（Android 首页每 10 秒轮询一次；见
  `lib/presentation/app_update_host.dart`）。
- 客户端现在用 `latest_app_version(p_platform)` 按平台查询；旧的零参数
  `latest_app_version()` 保留并固定指向 `platform='android'`，不会因为
  你发布了 Windows 版本就把 Windows 的更新提示推给 Android 用户。
- Windows 端之前完全没有接入更新检查（硬编码 `if (!Platform.isAndroid) return;`），
  这次已打通：`lib/presentation/app_update_host.dart` / `app_update_page.dart`
  两端都改成跨平台。Windows 没有"静默自更新"能力——下载完成并校验
  SHA-256 后，用 `OpenFilex.open()` 打开下载好的安装包，由 Windows
  安装程序自己的界面完成安装（这是桌面应用的标准做法，不是偷懒）。

### 已知限制（如实说明，不是"做完了"）

- 首页的"新版本"提示复用的是已有的"公告"面板
  （`lib/presentation/notices_page.dart` 里 `release_version_code` 不为空
  的公告会跳转到更新页），我**没有**新增一个独立的可关闭横幅组件，也
  **没有**给公告加平台过滤——如果后台同时给 Android 和 Windows 发布了
  更新公告，两边用户理论上都会在公告列表里看到对方平台的那条公告文字
  （标题/说明），但点进去后 `AppUpdatePage` 一定是按当前设备自己的平台
  去查版本，不会真的把 Windows 安装包推给 Android 设备，也不会出现
  错误安装。如果你觉得公告文字交叉出现是问题，需要再加一次迁移给
  `app_notices` 加 `platform` 过滤，目前没做。
- 群发文件下载走的是普通一次性下载（`lib/services/generic_download.dart`），
  没有像"文件传输助手"设备互传那样做断点续传；对公告类文件（文档、
  安装包）够用，但如果后台群发几个 GB 的大文件、用户中途断网，需要
  重新下载，不会从中断处继续。

## 五、现场联调测试步骤

### 测试群发文件

1. 后台管理APP：用有 `super_admin`/`admin` 权限的账号登录（对应
   `admin_private.members` 里的记录）
2. 调 `huideng_admin_broadcast`，`action="send"`，`target_type="users"`，
   `target_ids` 填一个测试账号的 `auth.users.id`，上传/复用一个小文件
   （比如 100KB 的 test.pdf）
3. 观察返回值：`recipient_count` 应该是 1，`failed` 应该是 0
4. Android 测试账号登录后：打开"聊天"页，"文件传输助手"入口应该出现
   未读徽标数字；点进去顶部能看到这条群发，点下载能存下来并自动打开
5. Windows 用同一账号登录：同样在"聊天 → 文件传输助手"能看到同一条，
   下载后已读/已下载状态会互相同步（`admin_broadcast_recipients.read_at`
   / `downloaded_at`）
6. 换 `target_type="all"` 或 `"level"` 重复，确认没勾选到的账号收不到
   （用另一个未被选中的测试账号验证）

### 测试新版本

1. 后台：仍走已有的 `huideng_admin_releases`，`action="releases.save"`，
   `payload.platform="android"`（或 `"windows"`），填
   `version_code`（记得和另一平台不冲突）、`version_name`、
   `download_url`、`release_notes`、`apk_size`、`sha256`，
   `is_published=true`
2. Android/Windows 客户端：首页会在最多 10 秒内自动弹出"发现新版本"
   对话框（`app_update_host.dart` 的定时检查），或者手动去
   "设置 → 检查更新" 进入 `AppUpdatePage`
3. 点"立即更新"：Android 走系统安装确认；Windows 会下载后自动打开
   安装程序，按安装程序提示完成
4. 撤回测试：再调一次 `releases.save`，同一 `version_code`，
   `is_published=false`；未更新的账号下次检查（≤10 秒或手动进入更新页）
   后提示消失

## 六、调试日志

Debug 模式下已经打了这几类日志（`debugPrint`，不影响 Release 包的正常
使用体验，也没有输出任何密码/token/文件内容，只有 UUID 和数字）：

- `[FILE_RECEIVE] inbox refreshed user_id=... count=... unread=...`
  —— 客户端每次刷新群发收件箱
- `[FILE_RECEIVE] downloaded broadcast_id=... path=...`
  —— 客户端下载完成
- `[UPDATE_CHECK] currentVersionCode=... latestVersionCode=... updateAvailable=...`
  —— 客户端每次检查版本
- `[UPDATE_DOWNLOAD] download=NN%`
  —— 客户端下载更新包的进度

`[ADMIN_BROADCAST]` 这一类日志（后台发起群发）需要在后台管理APP那边自己
加——我这边碰不到那个项目的代码。建议格式：
`[ADMIN_BROADCAST] 创建群发任务成功 broadcast_id=... recipient_count=...`，
直接用 `huideng_admin_broadcast` 的返回值拼出来就行。
