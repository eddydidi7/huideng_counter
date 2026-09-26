# Android 直接安装版签名

正式构建使用 `key.properties` 指向的 `signing/wenshu-release.jks`，不回退到 debug 签名。
这两个文件均受 Android 目录的 .gitignore 排除；不要公开上传，也不要发送给安装用户。
请把密钥文件与密码配置一起备份到私人离线位置。后续版本必须沿用此密钥，不能重新生成替换。

构建命令（Flutter 3.47.4）：

```text
flutter build apk --release --target-platform=android-arm,android-arm64,android-x64
```

不添加 `--split-per-abi`。产物是 `build/app/outputs/flutter-apk/app-release.apk`。
最低 Android 8.0（API 26）；targetSdk 沿用已固定的 Flutter SDK 默认值，发布时验证实际 APK。

旧 debug 测试版与正式版签名不同，不能直接覆盖安装。
不要为了测试自动卸载旧版：卸载可能丢失本地数据。应先完成数据备份或使用没有旧版的设备。
新用户可以直接复制 APK 到 Android 手机，通过系统安装器安装。
用户需允许相应文件管理器或浏览器安装应用；设备管理策略或厂商安全设置仍可能限制安装。
