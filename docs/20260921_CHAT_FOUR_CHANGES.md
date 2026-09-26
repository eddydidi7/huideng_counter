# 2026-09-21 聊天四项补充修改

## 实现

- 全部/好友/陌生人及搜索结果显示个人号；不再以 UUID 或设备标识作为号码。保留现有头像组件、昵称/个人号/完整邮箱搜索接口。
- 群信息显示当前群名；群主和现有管理员可以改名。服务端校验管理权限，更新原群记录并写入系统消息。群信息和会话标题订阅更新，附带定时刷新恢复。
- 单聊信息的“＋”选择新成员后建立新群，包含本人、原私聊对象和所选用户。使用独立 UUID 幂等重试，原私聊和历史不搬移、不删除。
- 现有群继续直接邀请加入；复用群成员、管理员邀请开关、拉黑、封禁和人数上限校验。客户端区分身份失效、无权限、人数上限、接口未部署和网络错误，调试日志保留原始异常。

## 加成员失败的证据与边界

线上只读检查确认旧 `group_invite_v1` 包含 `is_anonymous` 排除条件，而已有迁移 021 允许具有 Supabase 身份的访客使用聊天。旧邀请函数与现有目录/聊天规则不一致。

数据库测试用访客目标复现 `CHAT_INVALID_USER`，修复后同一目标可直接加入。访客发起邀请的旧条件也会报 `CHAT_LOGIN_REQUIRED`。修复不会开放未登录的 anon 数据库角色。

手机现存日志没有那次失败的原始响应，因此不能断言历史那一次失败必然由该条件触发。需在新版同一账号/同一目标重试确认。

## 文件

- `lib/domain/chat_identity.dart`
- `lib/data/remote/chat_remote.dart`
- `lib/presentation/chat_contacts_page.dart`
- `lib/presentation/chat_info_page.dart`
- `lib/presentation/group_invite_page.dart`
- `lib/presentation/chat_room_page.dart`
- `lib/services/group_operation_error.dart`
- `supabase/migrations/202609210061_group_management.sql`
- `test/chat_identity_test.dart`
- `supabase/tests/group_management_test.mjs`

迁移 061 不删除历史数据、不关闭 RLS。新增 `group_manage_v2` 并修正 `group_invite_v1`。沿用已有群角色、成员、容量配置和聊天表。当前目录没有 Git 元数据；文件已保存，不能声称已提交版本库。

## 验证

- Flutter 全套测试：241 项通过。
- Flutter analyze：0 error、0 warning；4 条既有第三方依赖 info。
- 本地 PostgreSQL/PGlite：旧访客失败复现；批量陌生人/访客加入、重复成员、管理权限、仅管理员邀请、人数上限、封禁账号、系统改名消息、单聊新建群幂等、原私聊历史隔离和 RLS 验证通过。
- 聊天撤回及图片预览授权回归测试通过。
- Supabase Dashboard：057、058、059、060、061 执行返回 Success；public-resources 预览代码部署成功，与本地代码去除空白后的内容指纹一致。
- 线上只读复核：群邀请访客规则、新群管理 RPC、撤回、版本查询、预览 RPC、聊天 RLS 开启和 anon 禁止群管理，共 7 项均为 true。
- 真实多设备接收群、群名实时更新、离线后重连：尚未实机验证。自动测试不能替代这些验收。

## 先前批次仍需区分

- 新版包含已完成的先前客户端改动；本次没有重新开发这些功能。
- Windows 后台版本管理/附件清理的 admin-api 新代码尚未在本次部署，Windows 后台也没有在本次重新打包。
- 尚未开通推送服务；不能保证 App 完全关闭后的聊天推送。
- 正式发行 APK 与这台手机现有测试签名不同。手机应使用同一测试证书覆盖安装；正式包供正式版用户安装，不能将测试证书包当作正式发行包。

## 安装交付

已通过 `adb install -r` 覆盖安装到连接的小米手机，返回 Success，未卸载或清除数据。安装后读取版本为 1.0.47 / 48，并成功启动 MainActivity。用户已实机确认：原来失败的群添加成员成功。单聊建群及多设备群名实时同步仍未获得人工实机确认。

正式包：`outputs/android-release-1.0.47/wenshu-counter-1.0.47-release-universal.apk`

- 文件大小：200617590 字节（约 191.32 MiB）
- versionName：1.0.47；versionCode：48
- minSdk：26；targetSdk：36
- ABI：arm64-v8a、armeabi-v7a、x86_64
- SHA-256：`4d1131c31bf2566cd43369fe10c0d983a716c753dbc4736b6d5d8832133aac33`
- 签名校验、ZIP CRC 完整性校验通过；正式证书与原正式 1.0.45/1.0.46 相同。
- 手机测试包：同目录 `wenshu-counter-1.0.47-phone-test.apk`，仅用于这台已有测试签名的手机保留数据更新。
