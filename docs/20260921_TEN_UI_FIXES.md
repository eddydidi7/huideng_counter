# 2026-09-21：1.0.47 后新增十项修正

## 交付范围

已修改现有源码；未构建 APK、未更新手机、未改版本号、未修改数据库或 Supabase。沿用原草稿、计数、聊天和笔记数据。

## 修改与原因

1. 藏历：月历原本已按 offset + 当月天数生成格子，并非固定 42 格。取消 GridView 隐式安全区 padding，单元格改按现有大字体实际行高计算；农历及说明上下间距压缩。保留日期字号与特殊日颜色。
2. 日出日中：旧逻辑只有系统 Geocoder，并可能复用没有名称的缓存。现在 GPS 获取后立即保存、计算和更新提醒，地名异步解析；系统失败后直接由设备调用 BigDataCloud 当前 GPS 查询，最多自动重试两次。只复用 1 公里内的成功名称，成功名称单独缓存，拒绝 IP 推测的地名；手动地点不调用网络查询，旧请求不能覆盖新地点。查询说明位于地点旁信息按钮中。
3. 空间检查：检查计数、聊天/群、红书、笔记、藏历、日出日中、个人主页、网盘、设置。压缩设置/常用页外边距和间隔、日出页面外边距、通知行、聊天行及藏历说明间距。计数/群聊/个人主页原有紧凑布局保留；网盘底部上传按钮避让、空状态以及导航安全区不盲目移除。尚未逐页在手机上验收。
4. 笔记主页：新共享 AdaptiveActionBar 根据文本、字体缩放及可用宽度分配整行空间，避免默认 TextButton 字号回退；常用/收藏/所有笔记/菜单保留，点击区域至少 48dp。
5. 阅读入口：普通编辑页、超长笔记编辑页及独立阅读页统一为阅读/发红书/聊天/横三点/完成。发红书与聊天复用已有分享；完成复用保存退出路径。历史版本和资料快照可分享，但禁止把快照 ID 当作原笔记 ID 修改或公开链接。
6. 红书：无标题纯文字原先被自动标题的两行组件截断；现在直接走正文七行组件。有标题时标题与正文分别显示，短正文按自然高度，现有双列 masonry 保留。
7. 聊天通知：主标题 21 逻辑字号、辅助文字 16，继续接受系统字体缩放；行内边距压缩，保留最小点击高度及开关。没有新增推送服务。
8. 发布：移除发布前第二次确认，直接走现有 submit。busy 阻止发布中重复提交；失败保留草稿与同一 UUID，成功 Snackbar 后返回。
9. 用户搜索：全部/好友/陌生人主行显示个人号，昵称/设备名称移到副行；头像不变。
10. 聊天列表：沿用当前响应式头像基础乘 0.9，名字/摘要字号乘 0.85，减少行内空白；顶部个人/网盘/查找/加号不变。

## 主要文件

- lib/presentation/adaptive_action_bar.dart（新增）
- notes_page.dart、note_reader_page.dart、large_note_editor.dart
- note_share_actions.dart、note_tools.dart、personal_library_page.dart、content_link_host.dart
- forum_page.dart、forum_compose_page.dart
- tibetan_calendar_page.dart、calendar_traditions_panel.dart
- chat_page.dart、chat_contacts_page.dart、chat_notification_settings_page.dart
- settings_page.dart、my_page.dart、solar_page.dart
- lib/services/solar_location_service.dart

以上无目录前缀文件位于 lib/presentation。

## 测试记录

- flutter analyze --no-pub：本次源码零 error/warning；第三方依赖原有 4 条 info。
- 全量回归最终一轮：254 项通过，3 项测试需要修正模拟条件；随后对应补测全部通过（发布及草稿 7 项、新批次回归 15 项）。合计 257 项用例已获通过结果，并非宣称一次运行全绿。
- 新批次：320/360/412/480 宽度，1.0/1.6/2.0 字体缩放顶栏无溢出、48dp 点击区；无标题七行及短文自然高度；系统地名失败转备用服务；HTTP 503 不清除成功地名缓存；IP 城市不替代 GPS 地点。
- 日出页面：模拟 GPS 成功而地名失败，日中仍可显示，自动重试执行。
- 原有回归包含藏历多尺寸、计数及音量键震动、五百万字笔记、笔记本地保存/同步、阅读和页面返回等。
- 日志：项目根目录 work/0921-ten-analyze-final.txt、0921-ten-tests-final.txt、0921-publish-final.txt、0921-regression-final.txt。

## 待实机验收

未生成新安装包，因此未在手机验证本次界面与真实账号发帖/分享。海外与中国大陆真实网络的地名解析均未实测；不能保证某一家网络服务在所有地区可用。当前有系统服务、独立网络查询、附近成功名称缓存及手动地点作为降级路径，任一地名失败不阻断太阳时间计算。

## 地名服务参考

[BigDataCloud 官方当前设备查询文档](https://www.bigdatacloud.com/geocoding-apis/free-reverse-geocode-to-city-api)

[官方 lookupSource 说明](https://www.bigdatacloud.com/blog/new-feature-update-free-client-side-reverse-geocoding-api-with-ip-geolocation-fallback)

仅设备当前 GPS 直接请求；不在服务器批量请求、不用历史/手动坐标调用免费客户端接口。测试使用模拟响应，不向该服务发送虚构坐标。
