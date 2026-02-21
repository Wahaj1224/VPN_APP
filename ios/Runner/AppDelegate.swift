import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    // Scaffold SoftEther method channel
    let controller : FlutterViewController = window?.rootViewController as! FlutterViewController
    let softEtherChannel = FlutterMethodChannel(name: "hivpn/softether",
                          binaryMessenger: controller.binaryMessenger)
    softEtherChannel.setMethodCallHandler({ (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
      switch call.method {
      case "initialize":
        result(false)
      case "prepare":
        result(false)
      case "connect":
        result(false)
      case "disconnect":
        result(false)
      case "isConnected":
        result(false)
      case "getStats":
        result([String: Any]())
      default:
        result(FlutterMethodNotImplemented)
      }
    })
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
