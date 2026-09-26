# 聊天 UI 第一阶段交付说明 — 1.0.22 (23)

## 范围与已实现
在现有 Flutter / SQLite / Supabase 聊天上增量修改，保留已经存在的群聊、撤回、拉黑、在线状态和 P2P。

- 聊天首页改为紧凑会话列表，顶部搜索/+，共用昵称入口保留，通讯录单独进入。
- 每行默认头像、昵称或群名、摘要、会话时间、未读数；免打扰会话用小红点；底部聊天导航显示总未读数。
- 置顶优先，其余按现有服务提供的会话最近更新时间倒序。群重命名等更新也可能改变该时间，尚未新增专门的最后消息时间字段。
- 长按：置顶/取消、免打扰/关闭、标记未读、删除会话。删除前确认；第一版只从本机列表移除，消息和草稿不删除，新消息或主动重新打开后恢复。
- + 菜单：发起聊天、添加好友、创建群聊；未放置不能使用的文件传输助手按钮。
- 通讯录：好友、新的好友、群聊。昵称排序；昵称/UUID/完整邮箱搜索、验证消息、接受/拒绝申请、好友资料/复制ID、发消息、删除好友、拉黑/解除。
- 搜索按联系人和群聊/会话分组。邮箱仅精确匹配，不返回邮箱字段；服务端每分钟限频。消息正文/文件名搜索未做。
- 好友关系需要接收方同意；已有会话不强制补好友才能继续发消息。注册用户仍可以从搜索资料页直接发消息。
- 文字多行输入、常用表情、有文字显示发送按钮。
- 相册、手机拍照、10MB 云端文件、3000MB 在线直传入口。
- 图片在后台 isolate 压缩成最长边1600px/JPEG质量82；GIF保留原文件；拒绝超过4000万像素的解码，避免超大图片占满内存。
- 图片缩略图、内置放大、左右查看已加载图片、保存到本机 App 文档目录。不等同于写入系统相册。
- 文件卡片名称、图标、大小（014 后的新附件从 Storage 元数据获得，旧附件可能无大小）、点击打开/下载。
- SQLite 草稿保存/恢复、列表草稿标记；发送失败按消息显示红色提示，点击重试沿用原UUID。
- 连续消息减少时间重复显示，自己撤回显示“你撤回了一条消息”。
- 保留本地先显示、再获取云端；修正定期刷新导致当前已加载较早消息消失的问题。
- 原有独立 P2P 传输页面补充实际接收确认字节的速度和预计剩余时间。

## 修改文件
- lib/presentation/chat_page.dart
- lib/presentation/chat_room_page.dart
- lib/presentation/app_shell.dart（仅聊天未读角标）
- lib/presentation/direct_transfer_page.dart
- lib/services/direct_transfer.dart
- lib/data/local/chat_store.dart
- lib/data/remote/chat_remote.dart
- lib/data/repositories/chat_repository.dart
- lib/presentation/my_page.dart、pubspec.yaml、pubspec.lock（版本/依赖）
- ios/Runner/Info.plist（未来 iOS 拍照/相册权限说明）
- Flutter 自动生成的平台插件注册文件

## 新增文件
- lib/presentation/chat_contacts_page.dart
- lib/presentation/chat_gallery_page.dart
- lib/services/chat_image.dart
- lib/domain/chat_view.dart
- test/chat_ui_data_test.dart
- supabase/migrations/202609170014_chat_contacts.sql
- 项目根目录 work/admin-sql-tests/chat-contacts.mjs

## 新依赖
image、image_picker；平台依赖由 pub 管理。

## 本地数据库升级
独立 chat_cache.sqlite 从 v1 升级至 v2，仅使用 ALTER TABLE 为 chat_outbox 增加可空 last_error。
草稿、手动未读和本机移除标记复用 chat_cache，按 user_id + room_id 隔离并在事务内合并。
计数、笔记及它们的数据库和同步逻辑未改动；无删库或重建。
置顶/免打扰仍在云端保存；草稿/手动未读/本机移除标记目前仅在本设备保存。

## Supabase SQL 和 RLS
执行 202609170014_chat_contacts.sql 一次。前提是 012 聊天基础已成功部署。
新增表：
1. chat_friend_requests：好友申请及处理状态。
2. chat_friends：双向好友关系，deleted_at 软删除。
3. chat_contact_lookups：只存搜索时间用于限频，不保存搜索内容或邮箱。
另给 chat_messages 增加可空 attachment_size；新增触发器从 Storage 对象元数据取大小。
不批量修改旧消息或私人正文。

三张新表均启用 RLS：申请仅收发双方可 SELECT，好友关系仅本人可 SELECT；限频记录不能由客户端直接读写。
写入一律通过 chat_contacts_v1，验证 Supabase Auth、非匿名/非暂停账号、拉黑关系、申请接收方及限频。
客户端不能直接 INSERT/UPDATE 新表，也不能自行接受别人收到的申请。
未增加后台浏览私聊正文接口；现有消息 RLS 仍仅允许会话成员读取。管理员身份本身不会获得私人聊天正文权限；服务端 service_role 的能力不应授予管理端客户端。

## Realtime
014 自动将 chat_friend_requests 和 chat_friends 加到已有 supabase_realtime publication（若该 publication 存在）。
012 原有 chat_messages/chat_members/chat_rooms 配置保留。
若项目尚未开启该 publication，请在 Dashboard 的 Database → Publications 中启用上述表。客户端订阅仍受 SELECT RLS 限制。
好友被删除是软删除 UPDATE，可按各自 RLS 推送，无全表删除事件泄露。
在线状态/直传另外依赖 013。014 不替代 013，不增加 TURN 或云端大文件容量。

## 测试证据
- 12 个相关 Dart 文件静态检查通过。
- 10 项 Flutter 自动测试通过：v1→v2 升级保留消息/缓存；草稿持久化与账号隔离；并发补丁不覆盖草稿；置顶排序、手动未读、会话重新出现；图片压缩；已有消息幂等/缓存；P2P 成功/损坏/取消；底部导航回归。
- 本地 PostgreSQL 兼容环境运行真实 SQL：邮箱精确查询且不返回邮箱、好友申请去重、仅接收方接受、双方关系、RLS 陌生人隔离、软删除、拉黑、匿名拒绝；Storage 大小触发器测试通过。
- 这些不是线上两账号端到端测试；用户已回复“014成功”；尚未进行实际账号端到端验证。

## 未完成/后续
- 自定义头像上传、个性签名、拼音索引、完整联系人分页。
- 云端草稿/手动未读同步，真正清空聊天记录（当前明确保留数据）。
- 消息收藏、转发、多选、单条本地删除、聊天正文/文件名搜索。
- 群公告、群管理员、成员禁言、群头像、二维码、举报处理。
- 撤回时限后台配置：目前仍沿用原有两分钟限制。
- 网盘选文件、语音消息、文件传输助手、系统 Push。
- TURN 中继和 P2P 失败后的云端大文件回退；直传仍要求双方前台，尚未改成会话内进度卡片。
- 相册保存入口目前保存到 App 文档目录，不是系统相册入库。
- Windows/iOS 本次未构建或真机验证；手机拍照入口在 Windows 不显示。

## 真机验收建议
两台手机都装新版并使用不同账号；执行014后搜索对方完整邮箱、申请、接受；发文字并核对会话/底部未读；进入后清零。
输入草稿返回并重启，再打开核对正文；断网发消息后重试确认不重复。
验证置顶/免打扰、删除会话确认、新消息恢复会话；相册图片、拍照、文件及图片大图浏览。
管理员/第三账号不应读取其他成员私聊。

## 本次构建与安装记录
- Android debug APK 编译成功（Gradle 364.4 秒）。
- 产物：releases/huideng-counter-v1.0.22-23-chat-ui.apk。
- Xiaomi 14T（MFZ999VCM7AMNBJF）使用 adb install -r 覆盖安装，返回 Success，未清除应用数据。
- 安装后读取系统包信息：versionName=1.0.22、versionCode=23。
- 打开应用成功；本次读取的最近 AndroidRuntime/flutter 错误日志未见输出。这不等于已完成各聊天功能真机验收。
- 两账号好友申请、消息收发、未读变化及真实大文件传输尚未完成真机端到端测试。
