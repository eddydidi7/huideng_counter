# 慧灯聊天模块第一版（1.0.18 / 19）

## 当前状态

客户端源码、SQLite 离线队列、Supabase SQL 与权限测试已提供。
本轮 Supabase 控制台连接两次超时，**没有执行云端 migration，没有完成两台真机互发消息验收**。
安装 APK 不会自动建云端表；看到“聊天服务尚未部署”时需要先执行下面的脚本。

## 部署

1. 打开当前 Supabase 项目的 SQL Editor，新建查询。
2. 粘贴完整 `supabase/migrations/202609170012_chat.sql` 并执行一次。脚本有事务，失败时整体回滚。
3. 成功显示 `Success. No rows returned`。不要重复执行已经成功的建表脚本。
4. 返回手机“聊天”，点右上角刷新。
5. 可运行以下只读检查：

```sql
select to_regclass('public.chat_profiles') as profiles,
       to_regclass('public.chat_rooms') as rooms,
       to_regclass('public.chat_messages') as messages,
       to_regprocedure('public.chat_api_v1(text,jsonb)') as api;
select tablename from pg_publication_tables
 where pubname='supabase_realtime' and tablename in ('chat_messages','chat_rooms','chat_members');
select id, public, file_size_limit from storage.buckets where id='chat-files';
```

本脚本新增 5 张表：chat_profiles、chat_rooms、chat_members、chat_messages、chat_blocks；
新增 chat_api_v1 RPC、注册资料触发器和 RLS；将三张会话表加入 Realtime；创建 **私有** chat-files 存储桶（单文件 10MB）。
如果项目禁用了 Realtime，请启用相关表的 Postgres Changes。
无需 Edge Function 或额外 API Key。客户端继续使用现有 Supabase public key 和用户登录 token。
数据库操作由受限的 SECURITY DEFINER 函数处理，固定 search_path，逐动作检查 auth.uid()、会话成员和群主。
普通用户不能直接 INSERT/UPDATE/DELETE 聊天表，游客不能调用聊天接口。

## 使用

- 所有非匿名注册账号自动加入通讯录；对其他用户只公开昵称和用户 ID，不公开邮箱或密码。
- 默认昵称为“学友 + 短编号”，在聊天右上角个人图标中修改。
- 点“通讯录 / 建群”，点某位学友可开始单聊，无需另加好友。
- 勾选多位学友、点“创建群聊”、填写群名即可建群。上限100人。
- 群主可改名、邀请、移除成员；成员可退出。第一版群主不能退出或转让。
- 聊天支持文字、图片、文件；图片和文件上传需联网，附件不超过10MB。
- 点击图片或文件通过系统浏览器查看/下载。图片在会话内提供预览。
- 消息长按复制或撤回。仅发送者可撤回两分钟内消息。
- 会话菜单可置顶、免打扰、查看成员。免打扰在本版弱化未读标识；尚无后台推送/铃声。
- 通讯录右侧菜单可拉黑/解除；拉黑限制双向单聊与邀请，已有共同群内消息仍可见。
- 群内新加入成员可阅读该群历史。退出或移除后云端拒绝读取消息、签发附件下载链接。

## 本地与同步

独立 `chat_cache.sqlite` 版本1新增 chat_cache、chat_outbox 两张表，按 user_id 隔离。
不更改原有计数/笔记数据库。文本先保存本地队列，再以固定 UUID 发送。
断网、进程重启或回执丢失后可重试；服务端重复 UUID 不重复插入。
前台使用 Realtime，并每10–20秒兜底拉取；失败按5/15/30/60秒退避，恢复前台时重试。
首次进入的会话需联网创建；缓存仅保证已加载的会话和最近100条消息离线可读。
文件上传成功后，附件消息元数据也进入待发队列。上传本身失败需重新选文件。
下载链接有效期60秒；撤回不等于能收回对方已下载的文件。

## 已验证

- `work/admin-sql-tests/chat.mjs`：真实 PostgreSQL 引擎（PGlite）执行 migration 和权限测试。
- 全注册用户目录、不含邮箱、唯一单聊、UUID重试、未读/已读、撤回归属、拉黑。
- 建群、群主权限、邀请/移除/退出、被移除成员无法读取、游客拒绝。
- Storage RLS：参与者可读附件，第三人不可读或上传。
- `test/chat_store_test.dart`：本地缓存和队列账号隔离、固定 UUID、不覆盖待发正文。
- `test/chat_repository_test.dart`：模拟回执丢失、重复重试、切换账号禁止发送。

## 仍待真实环境验收

部署后用两个独立账号，测试双方文字/图片互发，三人群聊、退出后拒绝访问，
关闭网络发送后恢复网络补传，退出重登待发继续，后台返回后刷新和未读计数。
语音/视频、头像上传、消息举报、群主转让、后台系统推送、WebRTC大文件直传、
聊天全量备份、Windows/iOS真机尚未完成，不能把本版称为完整微信功能。

技术参考：
- https://supabase.com/docs/guides/realtime/postgres-changes
- https://supabase.com/docs/guides/database/postgres/row-level-security
