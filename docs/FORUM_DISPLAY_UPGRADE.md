# 红书显示与版面优化（2026-09-20）

## 客户端
- 共用 getPostDisplayTitle：有标题保留；空标题取正文开头 28 个可见字符并追加省略号；纯图片不显示标题区。生成值仅用于显示，不写回作者正文/标题。
- 历史“文字分享/图片分享”等标题没有可靠来源标记，保留，避免误改作者真实标题。
- 首页、详情、个人内容、收藏、搜索、个人主页、聊天分享使用同一规则。
- 详情板块和发布时间一排；卡片头像、作者、点赞、评论一排；单列图片放大。
- 原视图按钮打开“版面设置”，双列/单列即时生效，偏好继续本地保存。
- 头像复用聊天的 chat_profiles.avatar_path 和 ChatAvatar，上传缩略图、签名 URL 缓存、图片字节缓存与列表按行延迟构建减少重复加载。
- 保留既有发帖/编辑草稿、同步及 CAS 编辑逻辑，不新建替代帖子。
- 简洁、内容优先的 UI 约定已写入项目 AGENTS.md。

## Supabase：需要执行
supabase/migrations/202609200044_forum_display.sql

依赖现有论坛与作者编辑、文字图片发布迁移（包括 038、041）。此脚本不删除/清空帖子，不改写历史标题；在事务内放宽标题/正文长度约束，正文为空仍须有附件，并保留原权限、关联记录和内容版本校验。更新 RPC 返回作者 ID，增加公开作者当前头像的受限读取权限。可重复执行。
SQL Editor 如提示 destructive operations，来源是替换 CHECK 约束，不是删除用户数据。
无需为本次修改替换 admin-api。

## Render：需要上传部署
两个现有网页源码目录均已同步：
- outputs/wenshu-web-service/server.mjs
- outputs/huideng_public_web/server.mjs

发布当前使用目录的 server.mjs、test.mjs 到现有 Render 仓库，网页标题和 Open Graph 预览即可使用新规则。本地修改尚未上传到线上。

## 验证
- Flutter 相关测试：24 项通过（22 项显示/版面/发布/编辑/分享/草稿 + 2 项头像测试；重复运行的编辑测试不重复计数）。
- 两份网页服务测试：合计 22 项通过。
- PGlite SQL：044 重复执行、空标题、纯图片、权限、编辑原记录、评论/点赞/附件保留、公开头像读取均通过。
- 本次相关 15 个 Dart 文件定向 analyze 无问题。
- 完整 flutter analyze 已执行：47 项已有问题，其中第三方示例缺失依赖，另有 home_page、calendar_ui_test、connection_routing_test 的既有提示；未改动无关文件。
- 未执行线上数据库变更，未部署 Render，未构建 APK，未在真实手机上验收。
