# 本地日出日中（1.0.32+33）

## 行为
藏历 → 八关斋戒 · 日出日中进入原生页面，不再打开或抓取日出网站。
先读取设备上的位置缓存并显示，再尝试一次中等精度定位（20秒超时）。没有后台持续定位权限，也不上传坐标。首次自动申请一次；拒绝后不会每次打开自动重复申请，用户可点击重新定位或系统设置。
缓存少于24小时且移动不足20km时复用；主动重新定位始终采用新位置。定位失败仍显示缓存。手动地点不被自动GPS刷新覆盖。

SharedPreferences已有2.5.5沿用并改为直接依赖。位置以solar_location_v1单个JSON原子写入，内含solar_latitude、solar_longitude、solar_location_name、solar_timezone_offset（分钟）、solar_location_updated_at、timezone_id和manual。没有修改SQLite/Supabase表。

页面显示民用晨光始、日出、突出的日中。不显示日落。无事件显示文字或横线，不显示NaN。保留持戒提示。支持今天、前后一天、日期选择、重新定位；手动设置经纬度+IANA时区，预填上海和奥克兰。城市反向编码未接入，自动定位显示坐标。

## 时区与精度
getSpa输入YYYY-MM-DD，不传设备午夜时间。civil dawn使用96度天顶角。结果转换为绝对UTC时间后按地点偏移显示。
自动定位使用所选日期的设备本地正午时区（含系统DST规则），提示必须与所在地一致。手动地点用IANA时区数据库，支持奥克兰夏令时和印度半小时时区；不对异地城市套用设备时区。
日期查询范围1900—2100。未修正实际地形遮挡、海拔、天气折射。设备时区错误会影响结果，需系统设置正确。

## 提醒
30分钟、10分钟默认关闭。主动开启才申请通知和精确闹钟权限。安排未来30天最多60条本地通知，每天按实际solarNoon单独计算（不是固定12点或固定时间循环）。应用启动/回前台/更换地点时更新；重启设备由插件receiver恢复已排程提醒。选择查询日期不会把提醒改成历史日期。
只取消保留给日出的73000—73059通知，不取消其他业务消息。未开应用超过30天不会无限生成后续提醒；跨地点移动后应刷新位置；系统省电、强行停止或权限关闭可能阻止提示。Windows和iOS代码接入但未在真机验证。

## 文件
新增：
- lib/domain/solar_times.dart
- lib/services/solar_location_service.dart
- lib/services/solar_time_service.dart
- lib/services/solar_reminder_service.dart
- lib/presentation/solar_page.dart
- android/app/src/main/res/drawable/ic_solar_notification.xml
- test/solar_time_test.dart、solar_location_test.dart、solar_page_test.dart
- test/fixtures/solar_noaa.json
- tool/solar_verification.dart
修改：
- tibetan_calendar_page.dart（入口）、main.dart（已开启提醒的启动/回前台刷新）
- AndroidManifest.xml（前台定位、通知、精确闹钟、重启恢复；无后台定位权限）
- android/app/build.gradle.kts（通知插件所需desugaring）
- ios/Runner/Info.plist、AppDelegate.swift（使用期间定位与前台通知）
- pubspec.yaml / pubspec.lock及生成的插件注册文件
- my_page.dart仅版本号
- test/solar_navigation_test.dart（原生页面入口测试）
原SolarWebsitePage保留源代码，不再是默认查询路径。后台原网址配置不会影响本地计算。

## 依赖
geolocator 14.0.2、nrel_spa 1.2.0、shared_preferences 2.5.5、flutter_local_notifications 19.5.0、timezone 0.10.1。
geolocator14.0.3需要win32 6，与现有file_picker10所需win32 5不兼容，因此固定14.0.2，避免升级破坏文件选择功能。

## 数值核验
独立NOAA参考：https://gml.noaa.gov/grad/solcalc/main.js
方法说明：https://gml.noaa.gov/grad/solcalc/calcdetails.html
包文档：https://pub.dev/packages/nrel_spa
将NOAA sunrise迭代两次，civil dawn使用96度代替90.833度，仅生成测试fixture，应用不依赖该JS或网络。
10组上海、奥克兰、德里日期（含奥克兰9月27日DST）：三项时间最大差异92.68秒，日中最大13.89秒，全部小于120秒容差。
2026-09-17样例（显示截取到分钟）：上海晨光05:15/日出05:39/日中11:48；奥克兰晨光05:52/日出06:17/日中12:15。仅用于指定坐标与日期核验。

## 验证状态
数值、DST、极昼极夜、无效坐标测试13项通过；权限申请/缓存重读/定位关闭测试3项通过；缓存先显示和拒绝权限页面测试2项通过。
真实手机首次授权、定位实测、断网后重开和提醒到时投递仍需安装后验证。不得将模拟测试写成真机测试。尚未编译iOS或Windows。
无需SQL、Supabase Dashboard设置或API Key。无删库、迁移、用户内容覆盖风险。

构建与安装：Android debug编译成功（591.3秒），归档releases/huideng-counter-v1.0.32-33-offline-solar.apk。Xiaomi 14T覆盖安装Success；versionName=1.0.32、versionCode=33；启动Status: ok（当前实例收到Intent，非冷启动测试），读取的错误日志无输出。设备仅声明前台精确/粗略定位，无ACCESS_BACKGROUND_LOCATION；安装后初始权限均未授权，等待用户在页面手动允许。总计19项相关测试通过（13数值、3定位服务、2缓存页面、1入口）。静态分析通过，核验工具的lint已修复。真实定位、重启离线及提醒投递尚待用户操作确认。

真机进展：用户确认首次进入并允许定位后“已显示三个时间”；adb只读核实ACCESS_FINE_LOCATION及ACCESS_COARSE_LOCATION已授权。正在等待用户断网关闭再打开验证。提醒到时投递未实测。

真机离线验证完成：用户关闭Wi-Fi/移动数据并关闭应用后重新打开，确认“离线重开仍正常显示”，无需重新选择地点。至此首次授权定位、缓存持久化、离线重开三个时间显示均由用户在Xiaomi 14T确认；未卸载现有App做全新安装，以保护用户数据。提醒默认关闭，实际通知到时投递、设备重启后提醒、iOS/Windows仍未实测。
