# 聊天紧凑气泡（1.0.28+29）

- 对话消息不再显示时间；原始 created_at、排序、已读判断及同步保持不变。
- 头像移到气泡外侧，自己的头像在右、对方头像在左。
- 单聊取消每条消息重复显示的昵称；群聊保留对方昵称。
- 气泡内边距由12调整为横向10、纵向7，圆角6，无阴影，纵向间距4。
- 保留18字号、1.4行高和发送/已读/失败重试状态。
- 修改：lib/presentation/chat_room_page.dart；pubspec.yaml、my_page.dart仅升级版本标记。
- 无新增依赖、SQL或SQLite迁移，无数据删除。
- Dart静态检查通过；真机布局视觉效果待用户查看。

验证结果：首次构建遇到临时头像副本无法删除，移除该构建副本后重新构建成功（159.5秒）。APK归档 releases/huideng-counter-v1.0.28-29-chat-compact.apk。Xiaomi 14T 覆盖安装 Success，核对 versionName=1.0.28/versionCode=29，冷启动 Status: ok，读取的启动错误日志无输出。未自动操作实际会话，气泡视觉效果需手机查看。
