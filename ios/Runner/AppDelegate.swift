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
    let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DeviceInfo")!
    let channel = FlutterMethodChannel(name: "generador_qr_app/device", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      if call.method == "info" {
        result(["modelo": UIDevice.current.model])
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
