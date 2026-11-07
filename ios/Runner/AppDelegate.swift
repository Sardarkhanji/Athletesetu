import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // Free-storage probe used by the top utility bar (<500 MB warning before a test).
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "AthleteSetuStorage") {
      let channel = FlutterMethodChannel(
        name: "athletesetu/storage", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        guard call.method == "freeBytes" else {
          result(FlutterMethodNotImplemented)
          return
        }
        let url = URL(fileURLWithPath: NSHomeDirectory())
        do {
          let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
          result(NSNumber(value: values.volumeAvailableCapacityForImportantUsage ?? 0))
        } catch {
          result(FlutterError(code: "STATFS_FAILED", message: error.localizedDescription, details: nil))
        }
      }
    }
  }
}
