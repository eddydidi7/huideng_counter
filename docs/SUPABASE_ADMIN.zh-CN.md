# 使用 Supabase 控制台管理慧灯计数器

## 本次状态

2026-09-15 已在测试项目 duakhsuncmbabxomynkr 执行 202609150003_app_links.sql，创建并填写全局入口表。Flutter 读取与缓存代码已接入，但需要重新编译、覆盖安装后才能在手机使用。Windows/iOS 共用代码，仍需分别编译与实测。

## 修改藏历、论坛链接

1. 打开 https://supabase.com/dashboard/project/duakhsuncmbabxomynkr/editor 。
2. Table Editor → public → app_links。
3. 编辑唯一一行 global：calendar_url 为藏历，forum_url 为论坛。填写完整 HTTPS 网址并保存单元格修改。
4. APP 启动、返回前台或前台每五分钟获取配置；离线保留缓存。

发布的合法后台链接优先于用户旧设置。旧设置不删除，在没有有效后台配置时作为兼容回退。普通用户只能读取公开链接，不能通过 APP 修改全局配置。后台管理员通过控制台修改。

## 查看已同步数据

- Authentication → Users：账号及注册、确认状态。
- Table Editor → counter_projects：用户项目；名称、图片信息在 data 中。
- counter_events：逐次计数记录，按 user_id、project_id 筛选；occurred_at、delta、source 分别为操作时间、变化量、来源。
- counter_documents：kind 为 setting/order/session，分别对应设置、排序与会话。
- Storage → counter-images：已上传的私有图片。

仅存在本机、尚未上传的记录不会出现在控制台。时间显示请确认时区；数据库保存带时区的时间。

请勿在 Table Editor 手工改计数总数或事件：这会绕过现有事件合并流程。需要校正请在 APP 内操作。普通 APP 用户仍然只能访问自己的计数与图片；本次没有扩大用户数据权限。

## 网站内容与 APP 数据边界

此配置只控制 APP 打开的网址。藏历网站内容和现有外部论坛的帖子、回复、账号由各自网站后台管理，不会因为设置链接就自动进入 Supabase。Supabase 当前查看的是慧灯计数器已同步的数据。

首页法语寄语使用另一个待部署的 home_messages 迁移，不能把它当成本次已部署内容。
