# 09/21 最终整合版实施记录

本记录区分本地代码、部署与实机验证，不代表全部任务已经上线。原安装包仍为 1.0.46；本轮不生成新 APK。

## 0921-01 公共网盘图片

已增加图片缩略图及大图预览，保留文件名和原下载/分享操作。JPG/JPEG/PNG/WebP/GIF/AVIF 按扩展名识别；其他格式继续文件入口，不尝试原图回退。

- 服务端签名 Supabase Image Transform URL：列表最大 480×480，预览最大 1440×1440，contain，质量分别 65/80。
- 不开放原 bucket；服务端验证登录账号、封禁、公开状态、完整性校验及下载总开关。
- ListView 懒加载预览组件。缓存以账号、资源 ID、内容 SHA-256 和预览规格区分，临时目录最多约 64MB，清理对象仅为生成的预览缓存。
- 缓存命中仍请求授权，但不重新下载图片字节。服务端转换失败显示预览不可用，不偷偷下载原图。
- 新增 `202609210060_resource_previews.sql`；只增加 service-role 可执行的只读函数，没有关 RLS、开放写入或删除业务数据。
- 需执行 060 并更新 public-resources 函数；本轮尚未部署、未用线上图片实测。
- 官方转换能力参考：https://supabase.com/docs/guides/storage/serving/image-transformations 。转换服务的实际用量由 Supabase 计费，不能宣称零流量。

## 0921-02～04 聊天 UI

- 列表和网格头像统一方形轻圆角，尺寸根据可用设备高度计算，在 36～56 Flutter 逻辑像素范围内；圆角比例与计数项目图标相同为 22%。未按物理 px 锁死 Xiaomi 尺寸。
- 用户名保持大字号、消息低一级、日期辅助层级；列表减少上下 padding。
- ＋菜单新增“显示方式 → 列表/网格”，原新聊天、群聊、扫码、好友和隐私功能保留；聊天资料/在线状态也保留在菜单。
- SharedPreferences 的 `chat.grid.<userId>` 继续保存显示方式，首次默认列表。
- 顶栏为个人主页图标、网盘、带边框查找、带边框＋；个人图标直接打开已有主页。去除顶栏通讯录/红书及独立视图按钮，没有删除模块。
- 查找图标 31 逻辑像素，＋图标 26，点击区域仍至少 48 高。
- 手机实际视觉效果尚未验证。

## 0921-05 通知：部分完成，远程 Push 待接通

### 当前技术与代码

复用 Supabase Realtime 和现有 flutter_local_notifications 插件初始化入口。新消息只通过事件触发，展示前重新查询有权限的房间与当前消息；不直接信任消息推送正文。相同消息 ID 本机去重。

- 设置 → 聊天通知：总开关、声音、铃声、震动、内容预览、私聊、群聊、全局免打扰时间。
- 本机按账号保存上述设置（含铃声 URI）；会话免打扰复用原 `chat_members` 偏好/RPC，随账号同步，不新增第二套会话设置。
- Android 系统铃声选择器；默认、静音及系统可选音；不打包铃声。
- 声音与震动独立。跨午夜免打扰时段静音且不震动；单会话免打扰不发普通通知，不停止消息同步。
- Android 13+ 权限由用户在设置中主动申请，拒绝后给出系统设置入口，不自动反复请求。
- 聊天通知按声音/震动/铃声/免打扰组合建立渠道。版本更新与系统通知分别预留 `app_updates` / `app_system` 渠道；已有渠道仍受系统设置控制。
- 点通知用当前账号和服务器房间权限导航，账号不匹配不打开；不保存旧消息正文用于恢复聊天。
- 在线撤回更新取消对应消息 tag 的通知。离线时不能保证立即移除已有系统通知；点击旧通知不会把撤回消息插回聊天。

### 必须明确的限制

用户确认尚未开通推送服务。当前未接入 FCM、极光、个推或国内厂商 Push。Realtime 只能在进程/连接仍活跃时工作，系统挂起、杀进程或 App 完全关闭后不能保证送达。

未来统一推送适配器应复用 `ChatNotifications.receive(roomId,messageId)` 的当前权限/消息状态校验，以及既有版本发布数据与独立渠道；本轮没有部署可用的 Push 网关、设备 token 注册或厂商凭据，后台版本通知也还不具备远程 Push。

小米、华为、荣耀、OPPO、vivo、三星：均未进行本轮推送实机验证。没有声称在大陆全品牌稳定送达。

## 主要文件

- `lib/presentation/chat_top_bar.dart`、`chat_page.dart`、`chat_avatar.dart`
- `lib/presentation/resource_image_preview.dart`、`public_resources_page.dart`
- `lib/data/remote/public_resource_api.dart`
- `supabase/functions/public-resources/handler.ts`、`index.ts`
- `docs/deployment/public-resources-dashboard.ts`（与模块源码同步的单文件部署版本）
- `lib/services/chat_notification_settings.dart`、`chat_notifications.dart`、`solar_reminder_service.dart`
- `lib/presentation/chat_notification_settings_page.dart`、`settings_page.dart`、`content_link_host.dart`、`chat_room_page.dart`
- Android `MainActivity.kt`：系统铃声选择与系统通知设置入口。

另修复上一轮收藏统一的遗漏：旧备份中的收藏2恢复为统一收藏，保留正文并避免重复导入；超长笔记菜单去除旧收藏2入口。

## 验证与交付边界

- Flutter 全套回归：238 项通过（随后收藏备份修复另跑相关测试）。
- 相关 UI/网盘/APK/通知偏好测试：32 项通过；预览缓存与通知偏好补充测试 3 项通过。
- public-resources 接口：4 项 Deno 测试通过；模块及 Dashboard 单文件类型检查通过。
- 060 SQL：本地验证重复执行、认证权限、未发布/未校验拒绝、下载开关与直接客户端调用拒绝。
- Android `compileReleaseKotlin` 通过（非 APK 交付）。
- Flutter analyze：无项目错误/警告，保留 4 项既有第三方 info。
- 线上图片预览、两台手机撤回、通知声音/铃声/震动、点击通知、锁屏与厂商后台行为：未实机验证。
- 057～060 和新 admin-api/public-resources 代码尚需按整批部署状态核对；本记录不能作为已经部署的证明。
- 未生成、发布或安装新 APK；以前任务中尚未完成的部署、实机回归和最终发布继续保留。
