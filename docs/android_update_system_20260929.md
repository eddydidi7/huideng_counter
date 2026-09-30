# Android 更新系统（2026-09-29）

## 当前诊断

本次只读 POST 检查默认项目的 `latest_app_version`，服务端成功响应 `null`。
因此当前这条版本 API 没有向客户端提供生效的已发布版本。这是目前可以确认的
“无法发现新版”阻断点。没有管理员数据库查询结果，不能断言是无记录、未发布、
发布时间尚未到，还是服务器另有配置。也没有有效 APK URL 可用于线上下载验证。

不要仅修改其他“更新地址”配置：客户端实际读取 `app_releases` 经由
`latest_app_version()` 返回的记录，下载地址字段为 `download_url`。
后台保存草稿、正式发布、发送通知是不同动作；仅发通知不能发布二进制版本。

默认公开 API（POST，客户端附带项目 publishable key；不需要登录）：

`https://duakhsuncmbabxomynkr.supabase.co/rest/v1/rpc/latest_app_version`

若构建时覆盖 `SUPABASE_URL`，实际地址随该项目变化。所有设置、通知入口继续
打开同一个 `AppUpdatePage`，没有增加第二套更新检测服务。手动检查每次调用 RPC，
不使用缓存版本记录。

## 本次修改

主工程：

- `lib/services/app_release.dart`：数值 versionCode、最低版本、检测/提示/启动/自动下载/Wi-Fi 策略。
- `lib/presentation/app_update_host.dart`：启动与恢复时检查、临时失败重试；稍后仅抑制本次会话，不再保存一天的抑制时间。
- `lib/presentation/app_update_page.dart`：版本详情、暂停/继续/取消/重试、Wi-Fi 等待、移动数据确认、安装前再次校验，初始强制更新限制。
- `lib/services/apk_files.dart`：沿用下载器，增加响应类型检测、Range 边界检查、完整临时包复用、同目标并发保护、限定命名空间的缓存清理。
- `android/app/src/main/kotlin/org/huideng/huideng_counter/ApkInstallerBridge.kt`：网络类型查询、包名/签名/版本不符的明确错误。继续使用系统安装界面。
- `supabase/migrations/202609290084_app_update_policy.sql`：扩展现有 058 版本记录与原管理 RPC，发布历史的二进制不可变及 versionCode 递增检查。
- `supabase/tests/app_releases_test.mjs`，`test/app_release_test.dart`，`test/apk_files_test.dart`，`test/app_update_page_test.dart`。
- `pubspec.yaml`：1.0.71+72；此前 1.0.70 已使用 code 71，不能再发 code 71。

现有后台工程 `outputs/huideng_admin`：

- `lib/features/app_releases_page.dart`：版本策略开关、最低版本、发布更新按钮，检查服务端是否真正返回新策略。
- `lib/services/release_url_check.dart`：发布前不带登录凭证探测下载链接、HTTPS 跳转、响应类型、大小和 ZIP 文件头。
- `test/app_releases_test.dart`、`test/release_url_check_test.dart`。
- `pubspec.yaml`：0.1.8+9，未构建安装包。

## 下载与安装安全

1. 以 versionCode 判断，不按 versionName 文本排序。后台版本名必须与实际 APK 一致。
2. 下载只接受 HTTPS，跳转最多 5 次，拒绝 HTML/JSON 错误页。APK 头检查不能替代完整包验证。
3. SHA-256 流式计算，并与版本记录的 `sha256` 比较，同时检查实际字节数。失败不能安装。
4. `.part` 使用 versionCode + SHA-256 隔离，支持 Range 时仅请求剩余字节。服务器不支持 Range、返回 200 时只能重新下载；不能承诺任何服务器都可续传。
5. 完整且 SHA 正确的包不重复下载；中断/暂停保留临时文件，取消删除当前未完成文件。
6. Android `verifyUpdate` 读取真实 APK 包名、versionCode、versionName 和签名，与当前安装比较。包名保持 `org.huideng.huideng_counter`，正式构建仍要求已有签名配置。
7. 用户点击“立即更新”或“继续下载”后，下载和校验成功且 APP 仍在前台时，直接用 FileProvider URI + 临时读取授权启动 Android 安装确认；自动下载或已退到后台时保留“立即安装”按钮。未知来源未授权时打开系统设置，返回后仍由用户确认安装，不静默安装。
8. 没有卸载、清数据库、清登录状态操作。升级后数据保留必须实机验收，不能仅以代码检查代替。
9. 缓存清理限定在 app-update 的散列目录；已安装版本的已知更新包或 30 天未使用的缓存可清理，不清理聊天 APK、笔记或用户文件。

## 需要手动部署

APK 实体沿用公共网盘上传器，保存到 Supabase Storage 的 `public-resources` bucket，
对象路径由服务端生成；`app_releases` 只保存下载地址和版本元数据。
这类 APK 分发会使用 Storage 和下载流量，并不是 P2P 文件直传。
已有公共网盘 bucket 可直接复用，不新增 APK 专用 bucket，也不要将私有 bucket 改成公开。
下载通过 `resource-web` 的分享入口获取临时直链；需要现有上传、分享函数和对应权限已部署。
Android 的 REQUEST_INSTALL_PACKAGES、FileProvider 和 apk_provider_paths.xml 已存在，无需重复添加。

1. 确认 058 已安装；在 Supabase 执行 **084**。它不依赖 080/081 配额冻结草稿，不要顺带部署那些草稿。
2. 本批沿用 `admin-api` 已有 `releases.list/save/notify` 路由，不新增 Edge action；若服务端尚未部署支持这些旧路由的 admin-api，先部署现有版本。
3. 使用更新后的后台版本管理界面。只替换数据库不能让旧后台显示新开关。
4. 发布 APK 需要实际可下载的 HTTPS 直链；公共网盘网页 `/f/<slug>` 不可直接作为安装包地址。现有后台上传器生成 `resource-web?...&download=1&redirect=1` 下载入口，需该函数已部署且允许公开下载。
5. 发布后重新查询上述 RPC，应得到版本对象而不是 null；核对真实 versionCode、大小、SHA、发布时间。

## Windows 本地发布

1. 在 `C:\huideng_counter` 用现有“一键生成apk.bat”构建，Codex 本次没有执行它。
2. 保持正式 applicationId 和原签名证书；不要用 `.dev` 或测试签名 APK 代替正式更新。
3. 通过后台选择生成的 APK，自动读取版本、大小和 SHA-256，并上传；或填写真实文件直链及准确元数据。
4. 填写更新说明、发布时间、最低版本与策略。普通更新先保持强制关闭、自动下载关闭；勾选正式发布，点击“发布更新”。
5. 查询 API 确认发布成功，需要通知时另点“发送更新通知”。
6. 保留旧版本手机，走 App 内更新，不用 ADB 覆盖安装或卸载清数据代替验收。

## 验收边界

本地自动测试覆盖版本比较、最低版本、提示开关、强制更新初始返回限制、失败查询后保留限制、
普通更新稍后入口、小屏布局、Range 续传、错误校验、HTML 拒绝、缓存复用与清理，后台元数据及 URL 探测，SQL 管理权限及发布不可变性。

本次未构建 APK、未编译 Android 原生模块、未安装手机、未部署迁移、未发布线上版本。
仍须实机检查：启动发现更新、Wi-Fi/移动数据变化、暂停取消、未知来源授权往返、签名拒绝、
实际覆盖安装，以及升级后笔记/登录/设置/聊天数据保留。后台探测文件头不是签名或全包 SHA 验证。

验证结果：主端更新相关 15 项测试、后台 2 项测试及本地 SQL 测试通过。
后台完整 flutter analyze 无问题；主端完整分析无 error/warning，仍有 8 条已有 info
（连接包、content_limits 测试和 third_party），命令因此退出码为 1，不能称完整分析零问题。

旧 APP 只能执行它原本已有的逻辑：现有旧版可读取同一 RPC 的基础版本字段，但不能凭空获得
新的策略、断点控制或强制更新修复。先发布一次包含本批代码的正式版本；此后正常发布新记录
即可被这套客户端检测。客户端强制更新不是服务端鉴权，离线未获取策略或修改过的客户端不能
由这个界面保证阻断；对不兼容的服务端 API 仍需独立版本校验。
