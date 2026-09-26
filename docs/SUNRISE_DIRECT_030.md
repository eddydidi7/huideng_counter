# 日出入口直接打开（1.0.30+31）

原因：藏历卡片仅push SolarWebsitePage，网页按钮需要第二次点击。
修正：卡片直接调用已有launchSolarWebsite，读取app.sunriseUrl后台配置；优先应用内浏览器，失败自动尝试系统浏览器。两种方式均失败时提示并显示原有备用页面。防重复点击。原说明页保留作为失败恢复入口。
修改：tibetan_calendar_page.dart、solar_navigation_test.dart；pubspec.yaml与my_page.dart只更新版本。
无SQL、SQLite、依赖和用户数据变更。

验证：静态检查通过。导航测试初次因仍可见的藏历加载动画导致pumpAndSettle超时，改为有限pump后通过；验证一次点击调用默认网址及后台配置新网址且不出现中间页。Android构建270.3秒成功；Xiaomi 14T覆盖安装Success，versionName=1.0.30/versionCode=31，冷启动Status: ok，无本次读取范围内的启动错误日志。网页实际联网加载仍需在手机点击确认。
