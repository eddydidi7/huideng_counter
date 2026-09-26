# 待打包：丰富表情与收藏表情

本次只修改代码及素材，未构建或安装APK。

## 使用
聊天输入框的表情按钮 → 常用表情 / 收藏表情。
常规Unicode表情分笑脸、手势、祝福、生活四类，最近使用保留24个。实际图案由各平台字体渲染，不是微信原版表情。
收藏面板内置29张按截图主题重新绘制的静态PNG，保留透明背景。截图底部被裁掉的主题未猜测补画。
点击+可多选导入PNG/JPG/GIF/WebP，单文件≤10MB；点击表情发送，长按移除。聊天图片长按可“收藏为表情”。GIF不转为JPEG。
收藏按当前账号存于本机，重启保留；自定义收藏暂未跨设备同步。发送沿用私有chat-files及现有成员权限，需要网络。

## 文件
修改：lib/presentation/chat_room_page.dart、pubspec.yaml（只注册素材目录，版本未变）。
新增：lib/domain/chat_emojis.dart、lib/presentation/chat_emoji_panel.dart、lib/services/chat_sticker_store.dart、test/chat_sticker_test.dart。
素材：assets/stickers/manifest.json及29张PNG，总计约45.3MiB。
预览：docs/STICKERS_PREVIEW.html。
图像使用内置image_gen逐张生成；最终提示词记录docs/STICKER_PROMPTS.json。

SQLite沿用按user_id隔离的chat_cache，新增缓存键recent_emojis_v1、favorite_stickers_v1、hidden_builtin_stickers_v1，无表结构升级；不改Supabase SQL或RLS，无新增依赖。
移除收藏不删除原图、聊天附件或待发送文件。

## 验证
静态检查无问题；收藏去重、持久化、用户隔离、内置资源读取和转为发送文件验证通过。
结合上一轮气泡测试，5项测试全部通过。未做新版本真机发送/接收测试，等待用户明确要求生成APK后再打包。
