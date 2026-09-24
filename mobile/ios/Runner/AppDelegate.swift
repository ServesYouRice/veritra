import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, FlutterStreamHandler {
  private var pushEvents: FlutterEventSink?
  private var pushInstance: String?
  private let wakeGenerationKey = "veritra_pending_push_wake_generation"
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    guard pm_crypto_abi_version() == PM_CRYPTO_ABI_VERSION,
          pm_crypto_available() == PM_CRYPTO_UNAVAILABLE else {
      return false
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "VeritraPush") else { return }
    FlutterEventChannel(
      name: "org.veritra.private_messenger/push_events",
      binaryMessenger: registrar.messenger()
    ).setStreamHandler(self)
    FlutterMethodChannel(
      name: "org.veritra.private_messenger/push_methods",
      binaryMessenger: registrar.messenger()
    ).setMethodCallHandler { [weak self] call, result in
      guard let self else { result(FlutterError(code: "unavailable", message: nil, details: nil)); return }
      switch call.method {
      case "register":
        guard let arguments = call.arguments as? [String: Any],
              let instance = arguments["instance"] as? String, !instance.isEmpty else {
          result(FlutterError(code: "invalid_arguments", message: "Push instance is required", details: nil)); return
        }
        self.pushInstance = instance
        // Only APNs can wake an iOS app; register only when the server
        // offers it (card I41).
        let providers = arguments["providers"] as? [String] ?? []
        if providers.contains("apns") {
          DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
        } else {
          self.pushEvents?(["type": "registration_failed", "instance": instance, "provider": "apns"])
        }
        result(nil)
      case "notificationPermission":
        UNUserNotificationCenter.current().getNotificationSettings { settings in
          let state: String
          switch settings.authorizationStatus {
          case .authorized, .provisional: state = "granted"
          case .denied: state = "denied"
          case .notDetermined: state = "not_determined"
          // .ephemeral (App Clips, iOS 14+) and future cases.
          @unknown default: state = "granted"
          }
          DispatchQueue.main.async { result(state) }
        }
      case "requestNotificationPermission":
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
          DispatchQueue.main.async { result(granted ? "granted" : "denied") }
        }
      case "pickDistributor":
        result(nil)
      case "unregister":
        DispatchQueue.main.async { UIApplication.shared.unregisterForRemoteNotifications() }
        if let instance = self.pushInstance {
          self.pushEvents?(["type": "unregistered", "instance": instance])
        }
        self.pushInstance = nil
        UserDefaults.standard.removeObject(forKey: self.wakeGenerationKey)
        result(nil)
      case "pendingWakeGeneration":
        result(UserDefaults.standard.integer(forKey: self.wakeGenerationKey))
      case "acknowledgeWake":
        guard let arguments = call.arguments as? [String: Any],
              let generation = arguments["generation"] as? NSNumber,
              generation.int64Value > 0 else {
          result(FlutterError(code: "invalid_arguments", message: "Wake generation is required", details: nil)); return
        }
        let current = UserDefaults.standard.integer(forKey: self.wakeGenerationKey)
        if current == generation.intValue {
          UserDefaults.standard.removeObject(forKey: self.wakeGenerationKey)
          result(true)
        } else {
          result(false)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    pushEvents = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    pushEvents = nil
    return nil
  }

  override func application(_ application: UIApplication,
      didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    guard let instance = pushInstance else { return }
    let token = deviceToken.map { String(format: "%02x", $0) }.joined()
    pushEvents?(["type": "endpoint", "provider": "apns", "instance": instance,
                 "endpoint": token, "publicKey": "", "authSecret": ""])
  }

  override func application(_ application: UIApplication,
      didFailToRegisterForRemoteNotificationsWithError error: Error) {
    // Registration is retried on the next authenticated startup. Do not emit
    // error descriptions because platform diagnostics can contain identifiers.
    guard let instance = pushInstance else { return }
    pushEvents?(["type": "registration_failed", "instance": instance, "provider": "apns"])
  }

  override func application(_ application: UIApplication,
      didReceiveRemoteNotification userInfo: [AnyHashable: Any],
      fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
    guard userInfo["version"] as? String == "v1",
          userInfo["event"] as? String == "new_encrypted_event_available" else {
      completionHandler(.noData); return
    }
    let next = UserDefaults.standard.integer(forKey: wakeGenerationKey) + 1
    UserDefaults.standard.set(next, forKey: wakeGenerationKey)
    pushEvents?(["type": "wake"])
    if application.applicationState != .active {
      // The one notification Veritra shows: a fixed sentence, never message
      // text, a sender or a conversation (card I41).
      let content = UNMutableNotificationContent()
      content.title = "Veritra"
      content.body = "New encrypted message"
      content.sound = .default
      UNUserNotificationCenter.current().add(
        UNNotificationRequest(identifier: "veritra-new-message", content: content, trigger: nil))
    }
    completionHandler(.newData)
  }
}
