# 公共资源网盘：APK准备与新后台实施约定

> 2026-09-20 更新：真实 Supabase Storage 服务与后台管理代码已补齐，部署步骤及当前限制见 [PUBLIC_RESOURCES_SETUP.md](PUBLIC_RESOURCES_SETUP.md)。下方早期“存储厂商未决定/占位接口”记录不再代表当前代码状态；线上仍需部署验收。

更新：2026-09-18。状态：APK源码准备；没有生成APK、没有线上部署或执行SQL。

## 用户确认的方向

- “我的 → 公共网盘”保留，副标题“公共资源 · 共享下载”；聊天顶部“资料”复用同一公共网盘页面和账号。聊天顶部顺序为通讯录、红书、资料、搜索、添加。
- 平台公共资料库，不给每人分配私人空间。所有已登录的正式账号可浏览公开资料。
- 用户上传完成并通过文件完整性校验后直接公开，可供下载；管理员可以下架、删除。普通用户没有删除/回收站操作。
- 最新确认（2026-09-20）：不需要人工审核，后台不设置审核队列或审批步骤。管理员保留删除权限；协议中的 review_required 固定返回 false，旧状态解析仅为兼容。
- 发布前后均可暂时关闭整个资料库、上传或下载。未配置时显示“公共资源正在准备中”。
- 存储厂商暂未决定，先完成API兼容层。长期密钥只进安全后台，不进Flutter。
- 原user_files、user_storage_quota、私人对象与旧上传队列保持原样，不转换为公共数据。

## 本轮已实现的客户端能力

公共列表、搜索、服务器分类、时间/名称/大小排序、分页；“我的投稿”的待审核/已公开/拒绝/下架状态及审核说明；共享容量显示；单文件大小限制提示；贡献说明和分类；上传前明确公共用途；持久化失败队列（独立于私人队列）；稳定上传UUID重试；PUT流式/POST表单直传；GET签名下载；签名过期403重取一次；文件大小+SHA256校验；拒绝明文链接和跨域重定向；不向对象存储附带用户JWT；账号切换与页面关闭中止访问。

打开页面、手动刷新、App恢复前台时获取配置；页面前台停留时每60秒刷新。客户端展示仅改善体验，后台必须对每次操作重新检查权限与开关。

已编写 `public-resources` 安全关闭占位函数：验证真实Supabase用户，只返回未开放的空列表。未部署函数的404也由APK显示为准备中。它不是实际可用的网盘后台，不会操作旧私人数据，不可通过设置变量直接开启。

## 下一步：全新Windows中文管理软件

在实施新后台前检查既有 `outputs/huideng_admin`，复用已验证的登录/角色/数据接口，重做管理界面；不建立第二套用户账号，不丢失现有通知、共修和文章管理功能。

第一阶段优先菜单：

1. 总览：公开资料数、已用/预留/总容量、下载流量、费用预警。
2. 公共资源：管理员上传、分类/说明编辑、搜索、公开/下架、回收站、恢复、永久删除前确认。
3. 投稿记录：投稿人、上传时间、文件大小、完整性校验结果和公开状态；不提供批准/拒绝流程。未知或未校验完成的对象不发布，这是上传完整性检查，不是人工审核。
4. 开放设置：资料库总开关、上传开关、下载开关、单文件上限、文件类型、分类、公告。
5. 容量与流量：平台总容量、每人每天上传/下载额度、平台月流量阈值、告警、暂停新下载签发。
6. 存储连接：服务商选择、连接测试；凭证在服务端环境管理，不在管理客户端持久保存长期密钥。
7. 用户与权限：查看用户、禁用投稿、禁用下载、管理员权限；所有管理操作服务端认证并记录日志。
8. 现有内容管理：保留首页通知、共修消息、共享文章、红书内容审核、供佛入口等。
9. 操作日志：谁在何时变更配置、审批、删除；删除失败重试、保留可恢复窗口。

建议后台新增专用表（下一阶段迁移，不是本轮已执行SQL）：

- `public_resource_settings`：版本、开关、限额、类别、公告。
- `public_resources`：公开资源元数据、上传者、审核状态、审核原因、provider/bucket/object_key、SHA256、大小、created_at/updated_at/deleted_at。
- `public_resource_uploads`：用户+upload_id唯一、配额预留、对象校验、过期回收。
- `public_resource_usage`：用户与平台用量/签发预留/供应商实际下载量。
- `public_resource_audit`：管理员和用户关键操作日志。

权限在数据库和服务端强制：用户只能查询公开资源或自己的投稿，不能自己批准/改状态/删除；只允许管理员操作资源生命周期。绝不把旧私人表的RLS改成所有用户可读。

## 固定客户端接口 v1

所有请求：POST `/functions/v1/public-resources`，Supabase SDK携带当前用户JWT；请求包含 `api_version: 1`。返回JSON必须包含 `api_version: 1`；错误另带 `error`。服务端使用Auth getUser验证身份（不信任客户端传来的owner/provider）。不要让匿名账号或被封禁账号获得上传下载授权。

### list

输入：`action: list, scope: public|mine, search, category, sort: time|name|size, cursor: string|null`。

返回：

```json
{
  "api_version": 1,
  "config": {
    "enabled": true,
    "upload_enabled": true,
    "download_enabled": true,
    "review_required": false,
    "notice": "欢迎分享学修资料",
    "max_file_bytes": 104857600,
    "total_bytes": 107374182400,
    "used_bytes": 1024,
    "categories": ["经论", "音频"]
  },
  "files": [],
  "next_cursor": null
}
```

容量值均为字节；used_bytes包含未清理的下架对象和上传预留，避免误导。public仅返回published且非deleted的资料；mine只返回当前用户的投稿。返回游标必须稳定，排序含唯一id防重漏。停用时不返回资料或签名链接。

每条file结构（无个人云路径，无永久对象链接，无长期密钥）：

```json
{
  "id": "resource-uuid",
  "file_name": "学修资料.pdf",
  "file_size": 1024,
  "checksum": "64位小写SHA256十六进制",
  "status": "published",
  "category": "经论",
  "author_name": "投稿者",
  "description": "资料说明",
  "review_note": ""
}
```

状态枚举：uploading、pending、published、rejected、hidden。id只允许字母数字、下划线、连字符，1–100字符。审核说明仅在本人投稿接口返回。未知状态客户端禁用下载。

### begin

输入：`action: begin, upload_id: UUID, file_name, file_size, checksum, category, description`。

后台验证上传开关/用户状态/文件类型/大小/平台容量/每日额度，事务预留空间，以 `(user_id, upload_id)` 幂等。重试必须恢复相同对象；已上传则返回 `already_uploaded: true, file`。不能根据客户端上报“成功”直接公开。

未完成时返回 `transfer`；method为PUT或POST。例如：

```json
{
  "api_version": 1,
  "transfer": {
    "method": "PUT",
    "url": "https://provider.example/single-object?signature=temporary",
    "expires_at": "2026-09-18T12:15:00Z",
    "headers": {"Content-Type": "application/octet-stream"},
    "fields": {},
    "file_field": "file"
  }
}
```

签名限单个随机对象，短期有效；不得允许覆盖已发布对象、任意路径或桶级列表/删除。PUT需绑定长度和支持的checksum；POST需限定content-length-range和key。供应商不能约束的权限由安全服务端补齐；不得因为适配厂商放宽权限。关闭版本控制或正确统计历史版本，不能利用重复上传绕过容量。

POST是multipart/form-data，由客户端生成boundary，fields为服务端签发的表单项，file_field默认为file；PUT发送原始文件流。不要在签名headers里返回Authorization、apikey、Cookie、Host、Content-Length（客户端拒绝）。无需厂商SDK/长期Secret。不能支持此格式的厂商，需服务端适配，不能假定随意更换即可运行。

### complete

输入：`action: complete, upload_id`，返回 `file`。

后台HEAD/实际内容SHA256校验并确认字节数，预留转为实际用量；事务幂等。校验成功后直接标记 published，不进入 pending 人工审核队列。若对象未完全写入，返回错误，不扣第二次容量。客户端断网重试begin也应发现已完整上传的同一对象并安全完成。

### download

输入：`action: download, id`，返回GET类型的transfer（相同结构、无fields）。

后台验证当前资源仍公开、下载开关/用户权限/限额，按资源自己的provider路由，签发只读单对象临时链接。新上传切换厂商不迁移旧文件。临时链接必须实际GET可用，无需客户端跟随重定向；APK不会给对象服务器发送Supabase JWT。

限流计量注意：同一签名可能被重复使用，不能把“签发次数×大小”当成严格账单上限。若要求硬控费用，需要CDN/供应商访问限制或可计量的下载网关，并计入中继流量。签名到期前下架也不能立即撤销已发出的链接，应缩短有效期并明确管理提示。

错误代码：LOGIN_REQUIRED、RESOURCE_NOT_CONFIGURED、RESOURCE_DISABLED、UPLOAD_DISABLED、DOWNLOAD_DISABLED、RESOURCE_QUOTA_EXCEEDED、DOWNLOAD_LIMIT、RESOURCE_RATE_LIMIT、FILE_TOO_LARGE、FILE_TYPE_NOT_ALLOWED、FILE_UNAVAILABLE、UPDATE_REQUIRED。其他错误客户端显示网络/操作失败，不把服务端技术信息或密钥展示给用户。

## 上线检查与边界

本轮验证：`flutter test --no-pub test/public_resources_test.dart test/cloud_drive_test.dart test/chat_top_bar_test.dart` 共25项通过；公共端点安全关闭测试1项通过；Deno检查index.ts通过。包含320/412宽度中英文页面、后台开关刷新、公共/个人队列隔离、PUT/POST模拟传输、签名过期重取、校验失败清理等。真实厂商和真机测试尚未进行。

- 本轮只能用模拟API/本地服务验证。尚无真实存储连通性、费用保护、服务端RLS或Xiaomi真机上传下载结果。
- 下一阶段实现服务端和管理软件后，必须用用户A/B验证上传成功自动公开、未完成上传不可见、普通用户不能删除/变更公开状态、暂停与限额服务端生效、断网重试不重复、重启后恢复、真实大文件上传/下载。
- 管理软件完成不等于可立即公开，必须先选厂商、配置并通过上述联调。
- 遵循v1接口的服务配置、分类、限额更新可由后台实现，用户刷新即获取；以后新增v1未支持的客户端交互或协议仍可能需要更新APK。
- 不生成或安装APK，直到用户明确要求“生成APK”。
