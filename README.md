# 慧灯计数器 · Huideng Counter

沿用原工程增量开发的 Flutter 工程，目标 Android / iOS / Windows。旧 Android 工程未被修改；当前工作区未提供旧工程，所以本版根据需求独立实现。

## 已实现

- 默认跟随系统语言，支持简体中文 / English 手动切换并保存偏好。用户自定义名称不翻译。
- 多项目新建、编辑、软删除、长按手柄拖动排序。
- 本地图片选择，复制至应用私有目录；删除原始照片不会影响已保存图片。
- 首页显示今日念诵数、累计总数、最近念诵时间。
- 大计数页：图片、本次数量、累计数量；Android / iOS / Windows 支持屏幕 +1，Android 另支持两个音量键 +1。
- Android 音量上下键，每次按下计一次，长按重复事件不会重复计数；离开页面、失焦、进入后台或打开调整页时停止拦截，恢复系统音量键。
- Windows 鼠标和空格键；移动设备震动开关。
- 每次计数立即通过 SQLite 事务写入项目、会话和事件表。
- 返回、结束或进入后台时关闭本次会话；异常退出后使用最后一次已提交计数的时间恢复结束时间。
- 逐次计数流水、念诵会话历史、今天/昨天/本周/本月/自定义筛选；人工 +1/-1/设置总数均保存校正前后值、差值、时间和可选备注。
- 今日数量仅统计实际念诵，人工校正不改变今日数量；跨午夜按每次点击所在的本地日期计算。
- 底部计数 / 藏历 / 论坛 / 我的。藏历和论坛使用已配置网页入口，原生内容后台尚未接入。

## 架构

```text
lib/
  core/app_controller.dart       应用状态与语言偏好
  domain/models.dart             实体、仓库契约、数量边界
  data/local/local_database.dart 数据库、版本和建表
  data/repositories/             SQLite 仓库实现、事务
  data/remote/                   Supabase RPC、私有图片存储、安全会话存储
  presentation/                  四栏导航、计数、流水/会话历史、编辑和设置
```

所有业务表包含 UUID `id`、`createdAt`、`updatedAt`、`syncStatus`、`deletedAt`。时间按 UTC ISO 8601 存储，界面显示本地时间。事件另保存当时的 `localDay`，避免旅行切换时区后历史日统计移动。

SQLite schema version 为 4。首次打开旧版数据库时先备份，再以事务迁移：保留五张旧表，增加 count_changes 统一流水，核对总数，失败自动回滚。旧记录来源标记为未知，不推断按键类型。Android/iOS 使用 sqflite，Windows 使用 sqflite_common_ffi 和随应用分发的 SQLite 库。数据与图片位于 `getApplicationSupportDirectory()`，不依赖临时图片路径。

软删除将项目及关联数据标记为已删除，不物理擦除记录或图片，以保留未来同步所需的删除标记。当前界面没有恢复入口。

## Supabase 账号同步（测试环境）

- “我的”支持邮箱/密码登录与注册、同步状态、立即同步、冲突处理和访客数据导入。
- 计数以 UUID 事件合并；人工设置总数转换为 delta，绝不上传最终总数覆盖其他设备。
- 独立账号 SQLite 保持离线计数。前台每 15 秒重试，失败退避，恢复前台后继续同步。
- 私有 Storage 保存图片；项目、排序、语言、震动设置、历史同步。
- 数据库升级前备份；原访客数据不自动归属账号。每个访客项目只能被一个账号认领，重复导入按 UUID 去重。
- 登录会话使用系统安全存储，不写入业务 SQLite。代码仅包含测试项目公开 publishable key。

详见 [客户端接入与手机验收步骤](docs/SUPABASE_CLIENT.zh-CN.md) 和 [Supabase 部署记录](docs/SUPABASE_DEPLOYMENT.zh-CN.md)。SMTP 与真实设备端到端验收尚未完成；当前不是生产发布版本。

## 构建

标准 Flutter 环境：

```powershell
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

本机配置可执行 `./build-android.ps1`。工具位于 `C:\Users\eddyd\Documents\Codex\tools`；脚本只影响当前进程环境，不修改全局 PATH。

APK 默认位置：`build/app/outputs/flutter-apk/app-debug.apk`。

Windows 编译还需要 Visual Studio 的 **Desktop development with C++** 工作负载和 Windows SDK，并启用 Windows 开发者模式以创建插件符号链接。然后运行 `flutter config --enable-windows-desktop`、`flutter pub get`、`flutter build windows`。

iOS 编译需要在 Mac 上安装 Xcode、配置 Apple 签名，再运行 `flutter build ios`。Windows 主机不能编译 iOS。本阶段未对 iOS 和 Windows 原生安装包进行构建验证。

## 测试重点

`test/repository_test.dart` 覆盖并发计数、跨午夜统计、校正事务回滚、软删除、排序、重启持久化和中断会话恢复。

`test/ui_test.dart` 覆盖按钮与空格键计数、结束会话、语言切换。新增测试覆盖真实 v1 数据库迁移与备份、失败回滚、逐次来源、微秒边界、日历范围、系统语言、Android 前台输入和校正返回。音量键界面测试使用平台通道模拟，不能替代 Android 真机验收。

真机验收仍应覆盖：本地图片选择、设备震动、Android 音量键、网页跳转、后台/进程退出后恢复，以及三平台的缩放和系统字体差异。

## 边界

数量范围为 0 至 9007199254740991，防止数据库和未来 JSON 跨语言精度溢出。点击以成功提交 SQLite 事务为有效计数；存储失败显示错误而不增加界面数量。空会话不在历史列表中显示。

应用当前离线保存，不含账号、云同步、后台管理网站或旧版数据导入。debug APK 供测试使用，正式发布需要单独的签名密钥和发布配置。

## Supabase 增量同步基础（2026-09-15）
详见 [接入方案与完成范围](docs/SUPABASE_SYNC_PLAN.zh-CN.md)。SQLite 已增量升级到 v3，增加离线队列和同步元数据，保留旧表。Supabase SQL 位于 supabase/migrations，隔离验收脚本位于 supabase/tests。登录、真实网络适配和图片恢复尚未接入，APP 仍为本地模式。

