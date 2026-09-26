import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ApkShareBridge") else { return }
    let channel = FlutterMethodChannel(name: "org.huideng.counter/apk", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "share", let path = call.arguments as? String else {
        result(FlutterMethodNotImplemented); return
      }
      let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
      let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("apk_share").resolvingSymlinksInPath()
      guard url.path.hasPrefix(root.path + "/"), url.pathExtension.lowercased() == "apk",
            FileManager.default.fileExists(atPath: url.path), var presenter = self?.window?.rootViewController else {
        result(FlutterError(code: "APK_SHARE", message: "文件不可用", details: nil)); return
      }
      while let shown = presenter.presentedViewController { presenter = shown }
      let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
      sheet.popoverPresentationController?.sourceView = presenter.view
      sheet.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
      presenter.present(sheet, animated: true)
      result(nil)
    }
  }
}
