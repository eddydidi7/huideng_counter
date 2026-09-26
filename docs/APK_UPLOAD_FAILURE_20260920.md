# APK 上传失败诊断（2026-09-20）

## 线上证据
- 文件：wenshu-counter-1.0.45-release-universal.apk，199797918 字节。
- 已生成 public_resources 上传记录，MIME 为 application/vnd.android.package-archive，状态 uploading、verified=false。
- 应用及桶单文件上限均为 536870912 字节，桶 allowed_mime_types=null；公共网盘与上传/下载开关均开启。
- Storage 全局上限实际仍为 50 MB。本次已在 Dashboard 保存为 512 MB，未关闭 spend cap。
- 13:43:45 的 Storage 日志：POST /upload/resumable，HTTP 400；error.message=Invalid Compact JWS；error.errorCode=AccessDenied；error.statusCode=403；内部 ERR_JWS_INVALID。
- 同一时段 Edge begin、上传授权 RPC 和 Storage 签名上传凭证请求均为 HTTP 200。错误发生在 TUS 创建阶段，尚未传输 APK 字节。

## 根因及修复
客户端把 x-signature 签名凭证发送至普通用户 JWT 路径 /storage/v1/upload/resumable。Supabase 签名 TUS 的入口应为 /storage/v1/upload/resumable/sign。

客户端兼容现有 Edge 返回的旧入口，将已验证路径转换到 /sign；保留 HTTPS、同源 Location 校验、6 MiB 分块和原上传任务标识。无需重新选择本地 APK，不删除失败队列或本地文件。未知上传异常不再一律声称网络失败。

本次不需要修改 RLS、不需要新增 SQL migration、不需要放开私人桶，不修改 admin-api assets.upload 的 2 MB 限制。公共网盘 APK 数据经 Storage TUS 直传，不经 admin-api 或 Edge 的整包请求体。

## 代码文件
- lib/data/remote/resource_resumable_upload.dart：签名 TUS 路径、HTTP 错误记录及分类。
- lib/data/remote/public_resource_api.dart：Edge 和旧上传流程的 HTTP 错误记录。
- lib/data/remote/resource_transfer_error.dart：统一错误分类与日志脱敏。
- lib/presentation/public_resources_page.dart：权限、凭证、大小、类型、超时、网络及服务器提示。
- test/resource_resumable_upload_test.dart、test/public_resources_test.dart、test/resource_transfer_error_test.dart：路径、断点恢复和错误分类回归测试。

## 验证状态
修改范围静态分析无问题，22 项相关测试通过。真机完整上传/第二台手机下载/安装界面验收尚待新版 APK；不能用模拟测试替代真实验收。

## 官方依据
- https://github.com/supabase/supabase/blob/master/examples/storage/resumable-upload-signed-uppy/index.html
- https://github.com/supabase/storage/blob/master/src/http/routes/tus/index.ts
- https://supabase.com/docs/guides/storage/uploads/resumable-uploads
