# 聊天在线状态与文件直传 — 1.0.20 (21)

## 本次实现
- 首页“消息”改为“好友”；列出已有会话和可聊天的注册学友，点击进入对话。群聊保留。
- 保留会话未读数量与实时刷新。当前仍是注册学友互相可见，没有新增好友申请/双向好友审核系统。
- 名字旁绿点在线、红点离线；无法确认时灰点，避免把网络故障当作对方离线。
- 按设备心跳判断在线，45 秒超时；多设备同账号只要有一台在线即在线。
- 对话“+ → 在线直传”：选择本地文件/视频/音频，最大 3,000,000,000 字节（3000MB）。
- 接收方在聊天首页或对话内看到发送人、文件名和大小，可接收/拒绝。群内选择一位在线成员接收。
- 双方确认接收后建立 WebRTC 可靠有序数据通道。STUN 辅助直连，没有 TURN 中继，也不自动转为云存储上传。
- 16KiB 分块、1MiB 在途窗口、接收写入确认、SHA-256 校验；只有校验后的接收确认才显示完成。
- 进度、取消、2 分钟无进展超时、断线/转入后台失败提示、未完成临时文件清理。
- 接收文件保存在本机 App 文档目录，右上角“已接收文件”可再次打开。
- 既有 10MB 云端附件发送入口继续保留。

## 云端部署
在同一个 Supabase 项目的 SQL Editor 执行：
`supabase/migrations/202609170013_chat_live.sql`
前提：012 已成功执行。013 是一次性增量迁移；成功后不要重复执行。
新增 chat_presence、chat_transfers、chat_transfer_signals 三张表，以及 chat_live_v1 RPC。
RLS 全部开启；普通客户端无表直接访问权限，只通过验证账号/会话成员/收发双方/接收设备的 RPC 操作。
只存在线状态和协商信息，不存大文件内容。不需要新 API Key，无 service_role、TURN 密码写入 App。
不修改或删除计数、笔记、论坛、已有聊天表及数据。SQLite 复用 chat_cache 保存接收文件索引，无升级表结构。

## 修改/新增文件
修改：lib/presentation/chat_page.dart、chat_room_page.dart、my_page.dart、pubspec.yaml、pubspec.lock。
新增：lib/data/remote/chat_live.dart、lib/services/direct_transfer.dart、lib/presentation/direct_transfer_page.dart。
新增迁移：supabase/migrations/202609170013_chat_live.sql。
新增测试：test/direct_transfer_test.dart、项目根目录 work/admin-sql-tests/chat-live.mjs。
新直接依赖：flutter_webrtc、open_filex；平台插件注册文件由 Flutter 自动更新。

## 已做验证与限制
- SQL 在本地 PostgreSQL 兼容测试环境运行：匿名/第三方访问拒绝、多设备在线、离线、3GB 大小限制、单设备接收、信令重试去重、只有接收方可确认完成。
- 模拟有序数据通道传输 2.5MB 文件，经过多个窗口，校验接收内容一致。
- 模拟文件损坏：不得显示成功，临时文件移除。
- 文件名路径安全与取消测试；既有聊天缓存/消息幂等测试。
- 新增和修改 Dart 文件静态检查通过。
- 尚未执行真实两台手机跨网络传输，也未实际传输 3000MB；不能据此宣称任意网络都能成功。
- Windows/iOS 使用同一实现，但尚未本次构建和真机测试。
- 第一版要求双方保持前台；中断后重新发送，尚无断点续传。Android 选文件可能产生系统缓存，需预留磁盘空间。
- 没有 TURN 时，某些 NAT/移动网络不能连接。提示尝试同 Wi-Fi；未来可接入服务端签发的短期 TURN 凭据。
- 在线状态与新功能需双方安装本版并部署 013。老版不会上报在线或接受直传请求。

## 两台手机验收
1. 两台安装本版、不同账号登录，聊天页确认互相绿点，昵称正确。
2. 点击学友开始对话；另一台停在首页，发送文字，核对未读数量；进入后清零。
3. + → 在线直传，先用 1MB 文件；对方接收，核对进度、两端完成和打开文件。
4. 分别用音频、视频、100MB、3000MB 文件测试；记录速度和磁盘占用。
5. 测试拒绝、发送方取消、接收方取消、断网、切后台，均不得假报成功。
6. 同 Wi-Fi 成功后再测试 Wi-Fi 与移动网络。跨网络失败不等于可以承诺靠 STUN 解决。
7. 接收后重启 App，从原会话“已接收文件”打开。

### 构建环境补充
新增 third_party/open_filex（保留上游许可证），仅把 Android compileSdkVersion 从 34 改为 35，绕过本机损坏的 SDK 34；pubspec 使用本地 override。插件业务逻辑未修改。
AndroidManifest.xml 增加 ACCESS_NETWORK_STATE 普通权限供 WebRTC 判断网络。不申请摄像头或麦克风权限，本次只发送现有文件。

## Android 构建与安装结果
Android debug APK 已构建成功，产物 releases/huideng-counter-v1.0.20-21-chat-live.apk。
通过 adb install -r 保留数据安装到已连接 Xiaomi 14T 成功。
本次 6 项 Flutter 测试通过，SQL 两组测试通过。尚未宣称两台手机/3000MB 实际直传通过。
