# Supabase 增量接入方案与本次落地范围

日期：2026-09-15。项目：慧灯计数器 / Huideng Counter。

## 结论与当前状态

沿用 Flutter → repository → SQLite 架构，以已有 count_changes 为唯一计数事件账本；Supabase 用于 Auth、PostgreSQL 和私有 Storage。SQLite 是离线读写来源，云同步在独立服务中执行。

截至本次续开发，测试项目已部署 SQL/RLS/私有图片桶，并完成数据库角色级隔离与幂等验收。Flutter 已接入 Supabase Auth、安全会话存储、独立账号 SQLite、真实 RPC 网关、双向事件投影、图片上传下载和冲突界面。当前数据库为 v4，旧 v3 同步基础表保留。

真实账号注册、邮件投递、图片 HTTP 上传下载与 Android/Windows 双设备端到端验收仍待完成；代码接入不代表这些验收已经通过。最新使用步骤及限制见 [客户端接入记录](SUPABASE_CLIENT.zh-CN.md)，服务端部署事实见 [部署记录](SUPABASE_DEPLOYMENT.zh-CN.md)。

## 1. 当前数据库检查结果

| 原有表 | 已有能力 | 本次处理 |
|---|---|---|
| projects | UUID、名称、图片本机绝对路径、非负 total、position、lastRecitedAt、创建/修改/同步/软删除字段 | 保留所有列和值；total 仍是本地展示缓存 |
| count_changes | 统一 UUID、delta、source、beforeValue/afterValue、微秒时间、sessionId、originKind/originId | 作为云端事件来源；不重新生成事件 UUID |
| count_events | 每次 +1 的旧记录，按 localDay 统计今日计数 | 保留兼容，后续拉取需补建对应投影，不能将历史重复计入 |
| corrections | 增加、减少、设置累计值及备注 | 保留；同一操作与 count_changes 共用 UUID，不能上传两份 |
| sessions | 开始/结束时间、本次增加、结束累计 | 保留，与事件不同步计入总数，只同步会话摘要 |
| settings | settingKey 全局唯一，语言、震动、网站入口 | 原结构只适合单账号；采用每账号独立数据库避免串号 |

重要限制：SQLite projects.total 有 CHECK(total >= 0)。并发离线减少可能导致全量事件余额为负，不能把负数直接塞入旧列，也不能偷偷取 MAX(0,total)。v4 新增 ledger_balances 保存完整有符号余额；界面读取该余额。并发减少产生负数时保留全部事件，提示先追加校正事件，旧非负 total 仅保留为兼容缓存。

## 2. SQLite v3：新增而不重建

- sync_scope：当前数据库唯一所属 user_id（游客为 NULL），稳定 device_id，远端应用时的触发器抑制开关。
- event_sync：事件 UUID 的账号/设备归属、同步状态、服务端版本；关联原 count_changes，不改写旧历史列。
- sync_queue：entity_type、entity_id、generation、冻结 request_id/payload、attempts、next_attempt_at、state、last_error。
- sync_state：按用户保存 pull_cursor、last_attempt_at、last_sync_at、last_error。
- sync_remote_versions：各项目/设置/排序等最近确认的服务端版本。
- sync_conflicts：双方数据快照、原因、处理状态。
- sync_assets：保留原预留表；实际图片服务使用 v4 cloud_projects 和 sync_queue 中 image/download 任务。

升级会先对 v1/v2/v3 SQLite 做 WAL checkpoint 和文件备份，再在迁移事务中新增表、回填同步元数据和队列。项目、图片路径、事件和计数不修改。已有 v1 升级审计仍保留；v3 升级失败由 SQLite 回滚。

项目创建、名称/图片/删除、排序、会话、设置、计数事件写入同步队列，与原操作在同一 SQLite 事务中提交。仅总数/lastRecitedAt 更新不会造成项目元数据不断冲突。删除项目只同步项目墓碑，绝不能把所有历史事件当作反向 delta 或再次上传为新事件。

本地队列没有网络依赖。磁盘满或数据库损坏仍可能导致本地写入失败，和任何 SQLite 操作一样；这里保证的是网络、JWT、服务端错误不回滚已保存的计数。

## 3. 事件字段及合并

| 云端字段 | 本地来源/规则 |
|---|---|
| id | count_changes.id，原 UUID 保持不变 |
| user_id | 经 Supabase Auth 验证的账号，绑定后不可转给另一个账号 |
| project_id | count_changes.projectId |
| delta | 有符号增量，+1/-1/人工校正均生成新事件 |
| count_after | afterValue，只是操作设备当时的观察值，不是远端最终总数 |
| created_at | 事件原 createdAt，UTC |
| updated_at | 事件原 updatedAt；新事件上传后业务负载不再修改 |
| device_id | sync_scope.device_id，安装/本地库首次创建时生成并持久化 |
| sync_status | 本地 event_sync 维护 pending/synced；服务端已接受事件固定 synced |
| occurred_at/source/session_id/note | 保留精确念诵时间、来源、会话、备注 |

历史 v1 的 +1 记录从未保存当时累计数。迁移不伪造，source=legacy_unknown 时 count_after 允许 NULL；新事件必须有 count_after。旧设备 ID 也不可追溯，回填的是本次导入设备标识，不声称为历史原设备。

合并：按 (user_id,id) 去重，验证同 UUID 的不可变字段一致，再累加 delta。同 UUID 相同内容重传返回原 ACK；内容不一致进入冲突，不能静默忽略。

例如共同历史 100，A +3、B +2，合并得到 105，完全忽略两台机器上传的 count_after。设置 100→80 记录 delta=-20，另一台同期 +5 后为 85。界面要明确“设置值”是基于当前本地观察的校正，不是跨设备强制重置。

负余额示例：共同余额 1，A -1、B -1，完整账本为 -1。保留三条事件并展示待处理差异。当前投影采用独立 signed ledger balance + 界面校正提示，旧 total 不用于伪装合并结果；用户在已拉齐的账本上添加一条补偿事件解决。不能删除其中一个 -1，也不能重复自动 +1。

## 4. Supabase SQL 与隔离

文件：supabase/migrations/202609150001_counter_sync.sql。

- counter_projects：项目元数据，不包含可被客户端覆盖的最终总数。
- counter_events：追加式事件，复合主键 (user_id,id)，复合外键确保项目属于同一用户。
- counter_documents：设置按键、排序按整个列表、会话按 UUID 保存版本化文档。
- counter_sync_heads：每用户提交版本头。
- counter_change_feed：每用户持久化增量日志。
- counter_mutation_receipts：元数据请求 UUID 幂等回执，防止响应丢失重试造成假冲突。
- counter_totals：security_invoker 视图，仅按事件 SUM(delta) 派生余额。

所有用户表开启 RLS。authenticated 只能 SELECT 自己的行；没有直接 INSERT/UPDATE/DELETE 授权，通过限定 RPC 写入。RPC 的 SECURITY DEFINER 仅用于保护事件不可改写和同步日志原子性，固定空 search_path，逐项检查 auth.uid()，取消 PUBLIC/anon 执行权限。客户端绝不能携带 service_role 或 secret key，它们会绕过 RLS。

RPC：
- counter_push_event(p_event)：检查账号，UUID 去重/碰撞检查，追加事件与变更日志。
- counter_put_document(p_kind,p_id,p_expected_revision,p_data,p_request_id)：compare-and-swap；版本不符返回 remote 快照并保留本地编辑。
- counter_pull(p_after,p_limit)：按用户服务端 revision 分页，最多 500 条。

游标不能只用 created_at/updated_at，也不能只用普通自增序列的最大值：数据库事务可能反序提交。所有写 RPC 锁定同一用户的 counter_sync_heads 行，版本分配与日志在同一事务提交，保证按该用户版本读取不会跳过后来才提交的旧编号事务。该方案按用户串行，适合计数器；未来优化批量上传仍须保留此约束。

图片桶 counter-images 为 private，20 MB，上限与已有图片选择器一致，允许 JPEG/PNG/WebP；路径 user_id/project_id/asset_uuid.ext。Storage RLS 限制第一层目录为 auth.uid()，上传项目必须属于本人。替换图片用新对象 UUID，不覆盖旧路径；没有客户端删除策略，后续用受控后台垃圾回收。不能把带有效期的签名 URL 当成永久图片字段。

## 5. 冲突策略

| 数据 | 规则 |
|---|---|
| 计数事件 | UUID 集合并集；不允许最后总数覆盖 |
| 设置 | 每个键独立服务端版本 CAS，不同键互不影响；同键冲突保留双方供选择 |
| 项目名称/图片 | 一个项目文档版本 CAS；迟到编辑不可复活删除项目 |
| 排序 | 整个项目 UUID 列表原子 CAS；新建且未出现在列表的项目按 createdAt、UUID 追加显示 |
| 会话 | 原设备持续更新、结束后不可被其他设备重写；计数总数仍来自事件 |
| 删除 | 墓碑保留，迟到事件可继续存档但不显示项目；恢复需单独显式操作 |
| UUID 碰撞 | 隔离负载并提示，不重新赋 UUID 后自动重发同一个逻辑事件 |
| 负余额/超限 | 保留事件、标记冲突，不钳制/丢弃/覆盖 |

CAS 冲突的用户选择会生成新的请求 UUID 和新 base_revision，旧冲突快照保留。图片冲突不得删除另一台设备仍引用的对象。

## 6. sync queue / retry / last_sync_at

已实现基础 API：LocalSyncStore.next、acknowledge、retry、conflict、applyPage、completeCycle。

1. next 在 SQLite 事务中读取队列 generation、生成请求 UUID并冻结 payload。重试复用完全相同 UUID/内容。
2. ACK 必须同时匹配实体、generation、request_id。HTTP 在路上时出现新编辑，旧 ACK 不能清空新编辑。
3. 超时/断网/5xx：指数退避约 2秒至1小时加随机抖动；429 尊重 Retry-After；状态持久化，重启继续。
4. JWT 过期暂停上传，刷新成功后恢复；RLS 拒绝或数据校验问题应标记明确冲突/错误，不无限高速重试。网关负责分类。
5. 拉取页的写入和游标推进必须在同一个 SQLite 事务，失败全部回滚。导入时抑制队列触发器，避免远端数据反复上传。
6. last_attempt_at 是尝试时间。last_sync_at 只在完整推送+拉取成功且队列清空时更新；它不是增量游标。错误日志只存分类代码，不存密码/JWT。
7. SyncCoordinator 单账号单实例、避免重入；每次最多50个上传、10个拉取页，前台15秒唤醒一次；resume/网络恢复可主动 wake，不依赖网络类型检测的判断结果。
8. 切换账号或退出时 stop 增加 epoch；迟到网络响应不写回本地、不清队列。后续需等待正在进行的本地事务退出再关闭数据库。

目前网络调度器可用假网关测试，不会被 APP 自动启动。未实现后台 OS 定时任务；目标是 APP 前台恢复网络自动同步，后台被系统挂起后下次前台继续，Android/iOS 不保证后台常驻。

## 7. Flutter 接入实现

原定 Auth、账号隔离、RPC 网关、双向投影、Storage、同步状态与冲突界面已加入现有工程。完整文件清单、数据流与真机步骤见 [客户端接入记录](SUPABASE_CLIENT.zh-CN.md)。图片服务与 RPC 网关共用 supabase_sync_gateway.dart；不再单独规划尚未实现的 image_store。

## 8. Supabase 配置步骤

1. 明确是 Supabase 托管项目还是阿里云香港自建 Supabase。自建需要 Auth/PostgreSQL/Storage/API 网关整套服务，并维护 HTTPS、SMTP、升级和备份；不能只装一个 PostgreSQL。
2. 先准备测试项目，执行 migrations SQL，然后执行 tests/isolation_and_idempotency.sql（自动回滚测试数据）。若已有同名表/桶，不直接重复执行，先编写后续迁移。
3. 获取 Project URL 和 publishable/anon 公钥，以 dart-define 注入。secret/service_role 不进入客户端。
4. 配置 Auth 邮件注册/确认、SMTP、密码重置与允许回调。
5. 私有桶按迁移创建，不设 public。用两个真实用户验证 A 无法读/上传 B 的文件夹，包括猜测 UUID 的 URL。
6. 真机验证中国大陆和海外的 Auth、API、Storage 三条链路。托管/香港部署本身不保证所有运营商可达；离线能力保留，不能声称网络已经验证。
7. 测试 APP 已提供同步入口；Android/Windows 双设备验收通过后才可向正式用户发布；iOS 沿用相同数据协议，单独配置签名/安全存储/回调并在 Mac 上构建。

## 9. 验收与限制

已运行 Flutter/Dart 测试涵盖：v1/v2 原数据保留、UUID 唯一事件、手动校正、断网本地计数、队列重传、迟到 ACK、账号拒绝、游标事务回滚、跨账号事件拒绝、并集收敛、负余额检测、协调器恢复重试和切换账号迟到响应。

服务端初始 SQL 已部署并通过数据库角色级隔离/去重验收。仍需验收真实账号 HTTP、两账号 Storage 访问、同时提交事务的游标顺序、双设备离线重启、图片恢复、邮件确认和长期大量事件性能。当前客户端测试与外部配置限制见 [客户端接入记录](SUPABASE_CLIENT.zh-CN.md)。

## 官方资料

- Flutter 平台与入门：https://supabase.com/docs/guides/getting-started/quickstarts/flutter
- 初始化：https://supabase.com/docs/reference/dart/initializing
- 密码登录：https://supabase.com/docs/reference/dart/auth-signinwithpassword
- RLS：https://supabase.com/docs/guides/database/postgres/row-level-security
- 函数权限：https://supabase.com/docs/guides/database/functions
- Storage RLS：https://supabase.com/docs/guides/storage/security/access-control
- 自建：https://supabase.com/docs/guides/self-hosting

## 部署进度更新
测试环境已经部署并通过数据库级隔离/去重验收。请参见 [服务器部署记录](SUPABASE_DEPLOYMENT.zh-CN.md)。APP 登录、HTTP 同步与图片恢复代码已接入，真实设备端到端验收待完成。

