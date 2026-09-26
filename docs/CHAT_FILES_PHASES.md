# 聊天、文件库与续传：增量实施记录

## 本次范围：阶段 1A（1.0.23+24）

原始要求完整保存在 CHAT_FILES_REQUIREMENTS_20260917.md。本次只完成最前面的聊天入口与隐私调整，不代表文件库或断点续传全部完成。

- 底部：计数、藏历、聊天、笔记、我的。藏历内已有日出查询入口继续保留。
- 聊天首页一排：聊天、当前昵称、通讯录、搜索、加号。昵称截断，点击仍可修改与论坛共用的昵称。
- 通讯录：全部用户／好友／陌生人。保留新的好友和群聊入口；全部用户包含本人，本人不可给自己发起私聊。
- 全部用户由服务端分页，每页 100 条，可加载更多。不显示邮箱、手机号；排除匿名、暂停及双向拉黑的账号。陌生人再排除本人和好友。
- 我的 → 设置 → 隐私：允许陌生人直接聊天／仅好友可聊天。云端按账号保存，只有服务端确认成功才更新界面。
- 私聊消息实际写入检查收件人隐私，旧客户端也不能绕过。好友申请不受这个开关影响，拉黑仍会禁止申请。
- 013 已安装时，对新建私聊 P2P 请求也加同样的限制。已经双方接受并建立的点对点连接不在本次实时断开范围内。
- 原有会话列表、基础群聊、好友请求、草稿、置顶、免打扰、未读数不移除。

### 修改文件

- lib/presentation/chat_page.dart：单排顶部、隐私错误提示。
- lib/presentation/chat_contacts_page.dart：三类联系人、分页用户列表，保留申请和群聊。
- lib/presentation/settings_page.dart：隐私入口。
- lib/data/remote/chat_remote.dart：新目录 RPC、私聊打开前检查、session 刷新。
- lib/presentation/app_shell.dart：底部藏历名称。
- lib/presentation/my_page.dart、pubspec.yaml：版本号。
- test/solar_navigation_test.dart：验证新导航名称和保留日出入口。

### 新增文件

- lib/presentation/chat_privacy_page.dart
- supabase/migrations/202609170015_chat_privacy.sql
- 工作区 work/admin-sql-tests/chat-privacy.mjs（本地 PostgreSQL 兼容测试）
- 本文和原始需求归档。

没有新增 Flutter package；没有修改 SQLite 结构；没有删除或清空现有本地／云端数据。

### Supabase 配置

在已有 012、014 基础上执行 015 一次；建议同时已部署 013，以保护直传请求。015 增加 chat_privacy 表（user_id、allow_strangers、updated_at），RLS 仅本人可读，写入仅通过鉴权 RPC。普通客户端不得直接写设置表或调用内部判断函数。

新增 chat_directory_v2 RPC、内部 chat_can_contact、chat_guard_privacy；消息表增加 BEFORE INSERT 触发器。若 013 的 chat_transfers 表存在，增加相同触发器。不会修改已有消息。

默认允许陌生人，延续已有行为。群聊沿用成员权限，陌生人开关只限制私聊。设置修改不新增 Realtime 表；发送时以云端当前设置为准。012／014 现有 Realtime 配置保持。无新 API Key 或 Storage Provider 配置。

## 下一阶段 1B：统一文件模型与持久化任务（尚未实施）

先核查部署项目 Storage 单文件限制及实际可用容量，再接 Supabase 小规模文件存储。100MB 是目标配置值，不代表当前项目已经允许 100MB 上传。OSS／COS／R2 未配置时不显示已连接。Google Drive 保留个人灾备定位。

建议新增云端表，均通过 migration：

- file_objects：UUID、owner_id、scope（private/group/shared）、room_id、provider、object_key、name、size、mime_type、sha256、state（uploading/verifying/ready/hidden/deleted）、created_at、updated_at、deleted_at。
- file_chunks：file_id、chunk_index、size、sha256；用于只修复损坏块。
- file_descriptions：file_id、说明、分类、关键词、置顶、重要标记。
- file_favorites：user_id、file_id；file_reports：举报者、file_id、原因、状态。
- file_upload_sessions：上传者、provider session、过期时间、完成状态；敏感上传授权仅服务端返回短期值。
- file_policy：后台可修改共享文件限额、类型和上传限频。实际生效上限必须同时满足 Provider 限制。

不将文件二进制放 PostgreSQL。管理员隐藏／删除经安全 API；客户端不能把 uploading 直接更新为 ready。云端校验完成后发布，不能只相信客户端声明的 checksum。

权限：private 仅 owner；group 只允许当前群成员，并可查看历史群文件，文件权限独立于消息历史；shared 只有 ready 且未隐藏／删除记录公开可读，上传和修改需要账号及所有权。文件下载也必须验证同样权限，不能只限制列表。下载次数在签发下载授权时定义为下载请求次数，不冒称完整下载次数。

SQLite 新表 file_transfer_tasks：按需求记录 UUID、user_id、file_id、类型、源路径、目标、provider、session、文件信息、checksum、块大小／数量、已完成块、字节数、状态、重试、时间；另存块明细避免每次重写大 JSON。所有任务必须用户隔离，退出登录暂停，切换账号不继续前一账号任务。

## 阶段 1C：传输引擎与三个文件入口（尚未实施）

统一 FileTransferManager 提供任务创建、暂停、继续、取消、网络策略和状态流。Provider adapter 负责建立／恢复上传会话、查询已确认分块、上传缺块、校验完成、下载指定范围。按实际协议选择分块大小，不把 4MB／8MB 当所有服务的通用协议限制。

只有服务端确认的进度才落盘；重启后先与远端核对。源文件不可读时提示重新选择并校验文件身份，不能把另一文件续到原任务。下载写 .part，校验长度与 SHA-256 后同文件系统原子重命名。临时签名过期应重新授权；远端上传会话过期时明确提示其真实恢复能力，不能承诺所有服务永远从原位置恢复。

网盘提供我的文件／共享文件／群文件。群附件上传成功后由服务端幂等关联消息和群文件，避免半成功产生重复。共享文件引用 ID 分享到聊天，不重复上传。APK 仅提供来源风险提示与下载，不自动安装。

后台、锁屏可能暂停；恢复前台继续，不能承诺系统杀进程期间持续运行。自动／仅 Wi-Fi／手动策略必须和实际网络检测联动，未接 Provider 的入口不提供假进度。

## 阶段 2（尚未实施）

保留现有前台 P2P，但它目前不是跨重启续传。需补持久化分块位图、双方重新确认任务、缺块协商、重连后校验与缺块补传。没有 TURN 服务；不擅自收费开通。云端回退需要发送者明确选择以及服务端额度检查。后续实现文件传输助手、群管理和更细共享范围。

## 必须实测的验收

两账号陌生人允许／拒绝／成为好友；第三账号访问隔离；新增群成员下载历史群文件；50% 断网、强杀、重启、锁屏后续传；下载恢复；重试幂等；SHA-256；损坏块重传；切换账号不串任务。先用可控测试文件，不删除用户文件。当前尚未完成这些文件传输真机测试。
## 本次验证结果
- 6 个相关 Dart 文件静态检查：无问题。
- 10 项 Flutter 回归测试通过，覆盖聊天缓存／任务幂等、排序／未读、图片处理、原有 P2P 校验，以及导航保留日出入口。
- 本地 PostgreSQL 兼容环境执行实际 012／013／014／015：目录分页、隐藏敏感信息、过滤拉黑用户、设置本人隔离、匿名拒绝、旧客户端消息被拒、P2P 请求被拒、成为好友后允许、解除好友后拒绝、既有 UUID 重试等检查通过。
- 这些测试不等于 Supabase 线上部署或 Xiaomi 14T 两账号真机验证。
- 尚待用户确认 015 执行成功，届时再进行新版安装和线上验证。

- Android debug 编译成功（216.3 秒）：releases/huideng-counter-v1.0.23-24-chat-privacy.apk。尚未安装；等待 015 部署确认。
## 015 部署确认与手机安装
- 用户已回复“015成功”。此为用户执行结果确认，尚未完成线上双账号验证。
- Xiaomi 14T（MFZ999VCM7AMNBJF）覆盖安装返回 Success，未卸载、未清除数据。
- 系统包信息确认 versionName=1.0.23、versionCode=24，启动成功；读取的近期 AndroidRuntime/flutter 错误日志无输出。
- 待用户打开聊天、通讯录和隐私设置检查；两账号收发和隐私开关联调尚未完成。
