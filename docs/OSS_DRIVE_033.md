# 网盘第一阶段：阿里云 OSS（1.0.33 / 34）

## 当前结果

已实现 Flutter 文件列表、搜索/排序、选择文件上传、进度、失败手动重试、下载 SHA-256 校验后打开、回收站与恢复、容量显示。统一使用现有 Supabase 登录。原“备份与存储设置”仍可从网盘进入。

**尚未上线：用户尚未开通 OSS / 私有 Bucket / RAM 角色。018 SQL 未在远端执行，storage-token 未部署，真实 STS 和真机上传下载未验证。请勿把本地测试通过理解为云服务已开通。**

第一阶段不提供文件夹、复制/移动/重命名、永久删除、自动恢复上传、分片断点续传、COS、Google Drive 自动备份。现有 Google Drive 入口保留，但不代表 OAuth/自动备份已完成。

## 先做什么（平台管理员一次配置）

1. 在自己的阿里云账号开通 OSS，了解并确认存储和下载流量费用。普通用户不需要阿里云账号。
2. 创建专用私有 Bucket，标准存储，保留阻止公共访问。地域按实际服务对象选择；此前香港节点计划可使用香港 `oss-cn-hongkong`，不要选好后随意更换。
3. 此版必须使用**从未开启版本控制**的专用 Bucket；启用后再暂停也不满足要求。原因：禁止覆盖请求在版本控制下不能保证相同对象只存一份。不要设置自动删除用户对象的生命周期规则。
4. 创建专用 RAM 调用身份、RAM 角色。角色信任策略仅允许该调用身份 AssumeRole。调用身份权限只允许对该角色执行 `sts:AssumeRole`，不要授予管理员权限。
5. 给角色附加下面的最小 OSS 权限（替换 YOUR_BUCKET），不授予删除或整个账号存储权限。

```json
{
  "Version": "1",
  "Statement": [
    {"Effect":"Allow","Action":["oss:PutObject","oss:GetObject"],"Resource":["acs:oss:*:*:YOUR_BUCKET/users/*"]},
    {"Effect":"Allow","Action":["oss:GetBucketVersioning"],"Resource":["acs:oss:*:*:YOUR_BUCKET"]}
  ]
}
```

每次 STS AssumeRole 还会进一步限制到当前用户的**单个 UUID 文件**；角色基础策略不代表客户端拿到全部 users 权限。

6. 在现有 Supabase 项目的 SQL Editor 执行一次 `supabase/migrations/202609170018_cloud_drive.sql`。它新增两张表和两个函数，不删除旧表、不改旧文件。重复执行会报已存在并回滚，不应通过删表解决。
7. 在 Supabase Edge Functions Secrets 中录入以下五项。只在控制台填写，不要发送到聊天，不要写进 Flutter、Git 或安装包：

| 名称 | 内容 |
|---|---|
| ALIYUN_STS_ACCESS_KEY_ID | 专用 RAM 调用身份的 AccessKey ID |
| ALIYUN_STS_ACCESS_KEY_SECRET | 对应长期密钥，仅服务端保存 |
| ALIYUN_OSS_ROLE_ARN | 上述 RAM 角色 ARN |
| ALIYUN_OSS_BUCKET | 私有 Bucket 名称 |
| ALIYUN_OSS_REGION | 例如 oss-cn-hongkong，必须匹配 Bucket |

Supabase 自带 `SUPABASE_URL`、`SUPABASE_SERVICE_ROLE_KEY` 留在函数环境，不进入客户端。

8. 部署 `supabase/functions/storage-token/index.ts`，同时包含 `supabase/functions/_shared/oss.ts`。有 Supabase CLI 时，在用户端工程目录执行：

```powershell
supabase login
supabase functions deploy storage-token --project-ref duakhsuncmbabxomynkr --no-verify-jwt
```

`--no-verify-jwt` 关闭的是旧网关校验；函数内部必须保留 `auth.getUser(accessToken)` 真实校验，并拒绝匿名用户。禁止删除该校验。普通用户不能调用高权限数据库函数。

9. 打开 App → 我的 → 网盘。未配置时会明确显示未开通，配置完成后使用慧灯账号测试。

## 安全与容量设计

- 新表：`user_files`、`user_storage_quota`；RLS 仅允许登录用户读取自己的记录。客户端不能直接改文件状态、路径或配额。
- 写入、软删除、恢复经过验证 JWT 的 Edge Function，再调用只授予 service_role 的 `drive_service_v1`。
- 不信任请求中的 user_id；由验证后的 JWT 用户决定身份。被 Auth 暂停的用户不能使用网盘。
- 默认每人 1 GiB（1,073,741,824 字节），单文件最高 1 GiB。上传前事务锁定用户配额并预占空间；同一个 UUID 重试不会重复占用。
- **上传不向客户端发放通用写入 STS secret**。服务端用精确对象 STS 生成 V4 POST 表单，限制 UUID 路径、精确文件大小、禁止覆盖与 15 分钟期限，防止绕过容量限制上传额外文件。
- 下载发放单对象、只读、15 分钟 STS。凭证只在内存缓存，剩余少于 5 分钟刷新；403 最多刷新重试一次。退出页面释放。
- 上传完成后服务端 HEAD 验证实际大小，才确认成功并计入已用空间。下载流式校验 SHA-256 后才打开。服务端目前不重新读取整个对象计算 SHA-256。
- OSS 请求使用 V4 签名；STS RPC 本身仍按官方 RPC 协议使用 HMAC-SHA1。
- 回收站仍计入容量。失败/未完成上传的预占空间也保留，避免对象存在但配额已释放；本阶段没有自动清理预占空间任务。管理清理需后续核对对象并经确认，不能直接减容量。
- 文件源内容不删除，下载也不会覆盖用户修改过的旧下载。暂不实现真正删除云端对象。
- Google Drive 继续作为后续灾备方向，不作为主网盘；更换平台 Bucket 不自动迁移或删除旧文件。

## 文件改动

新增：

- `lib/domain/cloud_file.dart`
- `lib/data/local/drive_upload_queue.dart`
- `lib/data/remote/cloud_storage_provider.dart`
- `lib/data/remote/aliyun_oss_provider.dart`
- `lib/data/remote/oss_v4.dart`
- `lib/presentation/cloud_drive_page.dart`
- `test/cloud_drive_test.dart`
- `supabase/migrations/202609170018_cloud_drive.sql`
- `supabase/functions/storage-token/index.ts`
- `supabase/functions/_shared/oss.ts`
- `supabase/config.toml`
- 本文档

修改：`lib/presentation/my_page.dart` 网盘入口与旧设置标题；`pubspec.yaml` 版本号。

没有新增 Flutter package，没有修改现有 SQLite 表或计数/笔记同步。上传任务使用按用户隔离的 SharedPreferences 队列，不保存 STS。旧业务数据迁移风险低；018 只新增独立网盘结构。

工作区测试脚本：`work/admin-sql-tests/cloud-drive.mjs`、`work/admin-sql-tests/oss-signing.mjs`。

## 验证记录与尚未验证项

已通过：PGlite 数据库权限/配额测试（A/B 隔离、匿名/封禁拒绝、禁止客户端修改配额、幂等预占/提交、大小不符拒绝、容量超限、回收站恢复）；OSS 模拟签名/精确对象 STS/文件大小约束测试；Dart 队列重启与账号隔离、凭证刷新窗口与隐藏、Dart/Edge V4 签名一致性测试；Deno 类型检查。

测试中的“100MB”是模拟表单约束和元数据预占，**不是成功上传真实 100MB 文件**。

Android debug 构建成功，已通过 `adb install -r` 覆盖安装 Xiaomi 14T（MFZ999VCM7AMNBJF）。设备确认 versionName=1.0.33、versionCode=34，冷启动 Status: ok；检查的最近日志未发现 AndroidRuntime/flutter 错误。未卸载、未清除 App 数据。这是安装与启动验证，不是云端传输验收。

安装包：`releases/huideng-counter-v1.0.33-34-oss-drive.apk`。

开通后必须实测：A 上传/B 无权读取、A 无权访问 B 路径、凭证过期刷新、手机重启、真实 100MB 上传下载与校验、网络中断与重试、无重复记录、容量超限、回收站恢复。Xiaomi 14T 云端传输尚未验收。

## 官方参考

- [STS AssumeRole](https://www.alibabacloud.com/help/zh/ram/developer-reference/api-sts-2015-04-01-assumerole)
- [OSS V4 升级说明](https://www.alibabacloud.com/help/en/oss/developer-reference/guidelines-for-upgrading-v1-signatures-to-v4-signatures)
- [POST V4](https://www.alibabacloud.com/help/en/oss/developer-reference/signature-version-4-recommend)
- [Header V4](https://www.alibabacloud.com/help/en/oss/developer-reference/recommend-to-use-signature-version-4)
- [PostObject 与禁止覆盖限制](https://www.alibabacloud.com/help/en/oss/developer-reference/postobject)
