> 最新进展（2026-09-15 20:17）：文字笔记云同步已接入现有 Supabase 测试项目，SQLite 升级至 v6。47 项测试通过，新 Android APK 已编译，尚未真机双设备验收。以下 1B 记录中的“笔记未接云同步”属于此前阶段状态；当前以 [笔记同步说明](NOTES_SYNC_20260915.zh-CN.md) 为准。

# 最新需求核对与分阶段实施

## 基线

用户端目录：outputs/huideng_counter；独立 Windows 后台：outputs/huideng_admin。
以 LATEST_REQUIREMENTS_20260915.md 为需求原文；后续说明优先于旧计划。
2026-09-15 用户确认：藏历面向宁玛派传承；暂时没有和风天气账号。

## 当前已实现和缺口

| 模块 | 已实现 | 待实现或待验证 |
| --- | --- | --- |
| 计数 | 项目/图片/拖动排序、软删除、屏幕/音量/空格计数、历史与人工校正 | 倒数、目标数量、震动强度分级 |
| 数据 | SQLite v4、账号分库、UUID 事件账本同步、队列与重试 | 新模块迁移、跨设备压力验收 |
| 导出 | 全项目 CSV、UTF-8 BOM、完整计数 JSON 备份封装 | 项目/日期筛选、CSV 设备列；笔记纳入完整备份 |
| 通知 | 首页/我的显示缓存通知、后台发布 | 已读/收藏/未读计数、文章、推送、定时任务启用 |
| 导航 | 计数/藏历/论坛/我的四栏 | 计数/藏历/日出/笔记/我的五栏 |
| 藏历 | 外部网站入口 | 原生离线日期、月名、节日、缺日/重日/闰月、食象 |
| 日出 | 无 | 安全代理、和风账号、城市时区、定位、缓存、提醒 |
| 笔记 | 无 | 本地笔记、富文本、清单/图片、分类标签、回收站、备份/同步 |
| 账号 | 邮箱登录、同步、修改密码/找回入口 | 邮件回跳配置与 SMTP 实测 |
| 语言 | 简体中文/English/跟随系统 | 繁体中文、统一资源整理、浅深主题 |
| 云存储 | Supabase 项目图片 | OSS/COS STS、Google Drive OAuth、切换与恢复 |
| Windows 后台 | 独立 EXE、管理员登录用户已确认正常、通知、网址、基础统计、角色权限 | 文章/论坛/用户治理、藏历维护、存储健康、版本、完整统计 |

## 第一阶段分批交付

### 1A 首页紧凑字号（本次）

- home_page.dart：首页标题按当前实际字号缩小 20%；“我的计数项目”缩小 40%。
- notices_page.dart：新增 compactHeader，仅首页通知标题缩小 20%、“查看全部”恢复原字号（按后续用户更正）。
- 保留颜色、留白、计数列表与其他页面字号。
- 无新增 package、SQLite 表、云端 SQL、Dashboard 设置。
- 不删库，不更改用户数据；本批无数据迁移。

### 1B 五栏导航 + 本地笔记基础

- app_shell.dart 调整五栏；论坛入口迁到“我的 → 通知与社区”，保留现有网址访问至原生论坛完成。
- 新增本地笔记 repository/controller/page，首批文字、搜索、自动保存、置顶、回收站及恢复。
- SQLite v5 只追加 notes/note_revisions/notebooks/tags/note_tags 表；升级前沿用 checkpoint 与备份。
- notes 含 UUID、created_at、updated_at、deleted_at、sync_status 和 version。每次保存追加 revision，按基准版本检查冲突；账号切换时停止旧账号保存并保留未完成草稿。
- 备份格式版本兼容旧计数备份；完整备份必须包含笔记，恢复同 UUID 冲突保存副本，不覆盖。
- 新增迁移/账号隔离/自动保存失败/恢复冲突测试后，再接入导航，避免出现不可用入口。

### 1C 原生离线藏历

- 候选历算：Phugpa；宁玛传统的 Rigpa 日历说明采用 Phugpa，但不能仅凭宗派认定所有用户都使用同一历算。
- 参考来源：https://rigpa.org/tibetan-buddhist-calendar/；算法核对：https://www2.math.uu.se/~svantejs/papers/calendars/tibet.pdf。
- 采用可核实且许可清楚的算法或预置数据；不复制第三方页面样式、插图或整套未经授权的数据文件。
- 独立 calendar_days 数据集以公历日期为唯一键；字段包括 tradition、dataset_version、source、tibetan_year/month/day、leap_month、day_occurrence。缺日不能伪造公历对应，重日保留两条不同公历日期。
- calendar_month_names 统一管理 zh-Hans/zh-Hant/en 及出处；calendar_observances 管节日说明；eclipses 独立记录时刻与可见地区，不与月相混同。
- 数据集升级写入临时版本，完整校验后切换 active_version；不影响私人计数和笔记库。
- UI 为原生今日卡/月历/日期详情；无可信数据的日期明确显示未覆盖，不用公历或普通农历充当藏历。

### 1D 日出日中

- 优先和风官方接口，经 Edge Function/安全 API 转发；API 凭证只在服务端配置。
- 明确取得 civilDawn、sunrise、solarNoon；不计算“日出日落中点”代替 solarNoon，不固定 12:00。
- 官方字段依据：https://dev.qweather.com/en/docs/api/weather/weather-daily-forecast/。开通前核对产品套餐、可查询日期范围、用量和数据许可。
- 地点必须有坐标和 IANA 时区；使用地点当地日期转换，包含夏令时，极昼/极夜显示不可用原因。
- 新增 solar_cache/favorite_locations；缓存键含地点坐标、日期、时区、服务版本；过期/离线标记缓存。
- 提醒默认关闭，用户启用后才申请系统通知权限；切地点/日期或时区后重新安排。
- 尚无和风账号，开通及可能付费选项需由用户选择；不得承诺已接通。

## 后续阶段

2. 笔记冲突副本同步、四种 CloudStorageProvider、CSV 筛选；保留现有计数账本。
3. 通知已读/收藏、原生 Supabase 论坛、社区未读；公共内容读取与私人数据 RLS 分离。
4. 扩展现有管理端；不重复创建工程，不把管理员密钥放进 EXE。
5. 繁体资源、主题、Windows/iOS、性能、离线重试与多设备压力验收。

## 验收方式

- 每批静态分析与相关单元/控件测试；数据库新增必须验证 v4 真实结构升级且事件 UUID/总数不变。
- Xiaomi 14T：覆盖安装前先导出完整备份；验证首页三处字体、通知详情、项目图片/排序、音量键计数、历史及登录同步；以实际连接和运行记录为真机测试依据。
- 小屏 360×640、大屏 412×915、字体放大 1.3/2.0；计数按钮可达、无溢出。
- Windows：独立构建用户端，鼠标/空格、窗口缩放、导出中文文件名；管理员端能登录不代表用户端已完成实机验收。
- 未构建/未安装的源码修改不得称为已在手机生效。

## 本次 1B 实施记录

新增：migration_v5.dart、notes_repository.dart、notes_page.dart、native_modules_page.dart、notes_test.dart、notes_ui_test.dart。
修改：local_database.dart（升级版本与自动备份）、backup_repository.dart（完整备份 v2，兼容 v1）、app_shell.dart（五栏与社区入口）、迁移/导航旧测试预期。
未新增 Flutter package。SQLite 仅追加 notes 和 note_revisions 两表；notebooks/tags/note_tags 延后随对应功能迁移。
本批没有 Supabase SQL 或 Dashboard 修改，笔记未接云同步，未申请 API Key。

已实现：文字笔记、中文标题/正文搜索、列表/网格、排序、置顶、收藏、归档、回收站/恢复、500ms 自动保存、保存后返回、字符计数、每次保存修订、旧版本冲突拒绝并保留编辑器正文。
完整 JSON 备份封装升级为 v2，加入笔记及修订；旧 v1 可导入；旧 App 不可恢复新的 v2，避免静默遗漏笔记。CSV 仍用于计数报表。
导入同 UUID 不同笔记保留副本；副本 ID 确定化防止重复导入；计数事件合并行为保留。
新建笔记按当前账号数据库隔离；访客笔记留在访客区，当前“导入访客计数”不会迁移笔记。
藏历/日出目前仅为原生未接入提示页，没有实际日期或日出数据查询；不能称为模块已完成。
论坛改由“我的 → 通知与社区 → 论坛”打开现有网站，未接入原生论坛。
尚未实现：富文本、图片/拍照、清单、笔记本/标签、PDF/Markdown/TXT 导出、永久删除、修订浏览、笔记云同步；不以占位页面代替功能完成。

验证：Dart 静态分析通过；新增笔记保存/冲突/备份测试、v4→v5 计数记录完整保留测试、360×640 和 412×915 的五栏/自动保存/返回测试通过；旧版本迁移、音量计数和导航语言回归通过。
Xiaomi 14T 尚未真机验收：先完整备份，再覆盖安装；检查三处缩小标题及“查看全部”原字号、五栏、创建笔记后返回/重启、飞行模式保存、回收站恢复、备份导入、计数与同步。
Windows 用户端需另行编译/运行验证；此前成功的 EXE 是独立管理端。
迁移风险：schema v5 是向前升级；不要覆盖安装不支持 v5 的旧版 App。升级前自动保留旧 SQLite 副本，禁止卸载清数据。

构建记录：2026-09-15 19:37 Android Studio 显示 BUILD SUCCESSFUL（3m30s）。新版 debug APK：build/app/outputs/flutter-apk/app-debug.apk，198256117 字节。flutter analyze 已通过；全量回归中旧版本/导航预期更新后复测通过。尚未安装 Xiaomi 14T，不以构建成功代替真机测试。


Windows 用户端续编记录（2026-09-15 20:00）：
- 已通过短路径源码构建解决插件路径过长；临时构建目录为 C:\Users\eddyd\AppData\Local\Temp\hd-src-0915。
- SQLite 官方源包通过正常 HTTPS 校验下载并配置 FETCHCONTENT_SOURCE_DIR_SQLITE3，未关闭证书校验。
- 当前剩余编译错误：flutter_secure_storage_windows 缺少 atlstr.h，需要 Visual Studio 2022 的 Microsoft.VisualStudio.Component.VC.ATL 组件。
- 官方安装器补装被已打开的安装器实例阻止；待用户关闭重复实例提示和安装器，再继续安装/编译。尚未生成可交付 Windows 用户端 EXE。
- Flutter build-dir 已恢复 build，后续 Android 编译不使用临时目录。
- 原始项目源码与计数数据没有因构建路径变更而移动；临时目录只用于编译。
