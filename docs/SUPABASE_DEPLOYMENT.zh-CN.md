# Supabase 测试环境部署记录

## 已部署并验证

- 项目：huideng-counter-test
- 组织：Huideng Counter（Free）
- 项目标识：duakhsuncmbabxomynkr
- 实际地区：Northeast Asia (Tokyo)，ap-northeast-1。以创建后的控制台为准；并非阿里云香港自建。
- Project URL：https://duakhsuncmbabxomynkr.supabase.co
- 控制台：https://supabase.com/dashboard/project/duakhsuncmbabxomynkr
- 客户端公开配置：config/supabase.test.json（只有 URL 和 publishable key，无 secret/service_role/数据库密码）。

本次通过已登录的 Supabase SQL Editor，在用户确认后执行了 202609150001_counter_sync.sql 对应的建表、函数、RLS 和 Storage 策略。编辑器返回 Success。不是通过 CLI migration push 执行，所以 Dashboard 的迁移记录不一定显示该版本号；不要重复运行初始建表脚本。

## 实际 SQL 验收结果

数据库查询返回：

| 指标 | 结果 |
|---|---|
| counter_ 数据表 | 6 |
| 全部表 RLS | true |
| owner_read 策略 | 6 |
| 同步 RPC | 3 |
| 图片桶 public | false |
| 单图片大小上限 | 20971520 字节（20 MiB） |
| 图片读写策略 | 2 |
| 验收后测试用户残留 | 0 |

事务测试在两个模拟 Auth 用户及 anon 数据库角色下验证：项目请求回执重放、项目 CAS 旧版本冲突、计数 UUID 重传去重、同 UUID 内容不一致拒绝、双设备事件求和、增量日志不重复、直接删除事件拒绝、跨账号读写拒绝、匿名调用拒绝。结果：PASS。所有测试用户和计数数据在事务末尾 ROLLBACK。

测试通过数据库角色与 JWT claims 模拟授权，尚未验证真实用户登录后通过 HTTP API 的全链路。图片桶权限已创建并查询确认，真实图片上传/下载和两账号对象路径攻击测试仍待 APP 接入时运行。

## Auth 当前状态

控制台已确认：Email provider enabled、允许用户注册、Confirm email 开启、匿名登录关闭。没有更改这些现有选项。
邮件页面显示当前使用默认邮件模板，尚未设置自定义 SMTP。公开用户注册邮件投递、生产发信以及密码重置回调仍需后续配置和验收；不应为绕过发信问题关闭邮箱验证。

## APP 状态与下一步

Flutter 已完成客户端接入代码，详见 [客户端接入记录](SUPABASE_CLIENT.zh-CN.md)。启动时保持访客记录原位，用户主动登录后才同步相应账号库；访客数据需要在“我的”明确选择导入。

本记录中的 SQL 测试是数据库级验收，不是手机和 Windows 的真实账号端到端验收。尚未替用户注册账号或上传真实手机数据；SMTP、确认链接落地页、真实设备同步需要下一步联调。
