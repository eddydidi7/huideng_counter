# 公共资料浏览器下载（050）

需求已改为两种方式均可下载：App 内资料下载，以及未安装 App 的朋友通过浏览器链接下载。仅开放已发布、完整性验证完成且未下架的公共资料；不开放私人笔记或聊天附件。

## 部署
1. 先完成 048（大文件）和 049（资源管理），再在 SQL Editor 执行 `supabase/migrations/202609200050_public_resource_web_share.sql`。新增随机分享链接和独立匿名下载签发计数，不删除现有文件。
2. 更新 Supabase `public-resources`：完整使用 `docs/deployment/public-resources-dashboard.ts`。
3. 新建 Supabase Edge Function，名称必须为 `resource-web`；index.ts 使用 `docs/deployment/resource-web-dashboard.ts`。关闭该函数 Verify JWT 并保存，因为浏览器无登录账号；函数内部只通过随机分享标识获取允许公开的资料。不要更改 admin-api 的身份校验。
4. 将 `outputs/wenshu-web-service/server.mjs`、`test.mjs` 更新到现有 GitHub Render 仓库，等待 Render 部署。沿用现有 SUPABASE_URL，可选 SUPABASE_ANON_KEY；不把 service_role 密钥交给 Render 或浏览器。
5. community_config.public_base_url 沿用 `https://wenshu-web-service.onrender.com`。客户端需要包含此次菜单的新版；本轮未构建 APK。

## 使用
进入 App 的“资料 / 公共网盘”，在已发布文件右侧菜单选择“复制浏览器下载链接”，发给朋友。
链接格式 `/f/64位随机标识`，不要求朋友注册或安装本 App。网页显示名称、大小、发布者、日期、SHA-256；APK 显示“Android安装包”和“下载 APK”。
点击下载后跳转对象存储，300MB 文件不经 Render 中转或读入其内存。浏览器处理下载进度。Android 下载后通过系统文件管理器打开，由用户确认安装；iOS 只能保存文件，不能安装 APK。微信可能需通过“在浏览器中打开”。
App 内原有下载、完整性校验及系统安装流程继续保留。

## 控制与限制
- 存储桶保持私有，永久分享页面与 120 秒临时对象下载地址分开。
- 全局关闭下载/网盘，或者管理员下架、删除文件后，不再生成新下载地址；已经签发的地址在短暂有效期内或已开始的传输不能立即撤回。
- 浏览器匿名下载无法可靠归属某个注册账号，因此不会伪造个人下载流量。
- 浏览器另设全站每日“签发容量”上限，默认 20 GiB（北京时间）；字段为 public_resource_settings.web_daily_signed_bytes，可在数据库后台修改。现有后台下载开关同时控制浏览器与 App。此字段尚无 Windows 单独输入框。
- 签发容量是保护性计数，并非真实流量/账单硬上限；同一临时链接可能被复用，下载失败签发量也不回退。公开链接可以被转发。
- APK 单文件限制沿用原有桶、全局 Storage、客户端和个人额度配置；050 不放开无限上传。

## 验证
本地网页测试覆盖展示、POST 点击下载、恶意跳转拦截、下架及原文章页面回归；SQL 测试覆盖随机链接稳定、RPC 权限、关闭下载、下架、匿名签发额度和私有对象路径不进入元数据；Flutter 检查原有下载及分享请求。
尚未部署线上、未实机验证 300MB APK 浏览器下载。部署后使用真实已发布 APK 分别测试手机浏览器及 App 下载，再测试关闭下载和下架。
