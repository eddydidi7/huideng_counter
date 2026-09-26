# 紧凑图标导航（1.0.29+30）

底部保持计数、藏历、聊天、笔记、我的五个入口及原顺序。
导航内容高度48（原73.6），图标21.6不变。隐藏可见标签，保留标签供无障碍及工具提示使用；取消选中椭圆底框，改用主题主色高亮。去掉阴影，保留聊天未读徽标和系统底部安全区域。

修改 app_shell.dart；my_page.dart 和 pubspec.yaml 仅版本标记。更新已有 solar_navigation_test.dart，使用图标点击，以验证隐藏标签后入口仍可操作。
不修改数据库、同步、业务页面或消息数据。

验证：静态分析通过；现有导航测试1项通过。首次构建因默认头像源资源及构建副本带ReadOnly失败，去掉两者只读属性（图片字节不变）后构建成功，耗时165.6秒。Xiaomi 14T覆盖安装Success，versionName=1.0.29、versionCode=30，冷启动Status: ok，读取启动错误日志无输出。真机视觉效果待用户查看。APK：releases/huideng-counter-v1.0.29-30-compact-navigation.apk。
