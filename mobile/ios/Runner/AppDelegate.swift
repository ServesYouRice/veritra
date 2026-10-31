import Flutter
import UIKit
import UserNotifications
import Darwin

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterStreamHandler {
  private var pushEvents: FlutterEventSink?
  private var pushInstance: String?
  private var ownedEngine: FlutterEngine?
  private(set) var backgroundLaunchHint = false
  // Set once in didFinishLaunching; false until the crypto boundary checks.
  private var cryptoBoundaryReady = false
  private let wakeCoordinator = IOSWakeCoordinator()

  func sharedEngine(background: Bool = false) -> FlutterEngine? {
    dispatchPrecondition(condition: .onQueue(.main))
    if let ownedEngine { return ownedEngine }
    // UIKit ignores didFinishLaunching's false and still connects the scene,
    // so the crypto check is enforced here: no Dart runs against a
    // mismatched or prematurely enabled crypto library.
    guard cryptoBoundaryReady else { return nil }
    let startingInBackground = background || backgroundLaunchHint
    guard !startingInBackground || IOSWakeCoordinator.coldExecutionEnabled else { return nil }
    let engine = FlutterEngine(name: "veritra.shared", project: nil, allowHeadlessExecution: true)
    ownedEngine = engine
    // Flutter queues platform calls on main. Register all channels in this
    // same main-thread turn before any queued bootstrap message can run.
    guard engine.run() else { ownedEngine = nil; return nil }
    GeneratedPluginRegistrant.register(with: engine)
    registerStorageChannel(engine)
    registerPushChannels(engine)
    wakeCoordinator.attach(engine.binaryMessenger, background: startingInBackground)
    return engine
  }

  func setWakeUIAttached(_ attached: Bool) {
    if attached { backgroundLaunchHint = false }
    wakeCoordinator.uiAttached(attached)
  }
  func detachSharedView(_ controller: UIViewController?) {
    if ownedEngine?.viewController === controller { ownedEngine?.viewController = nil }
  }
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    backgroundLaunchHint = launchOptions?[.remoteNotification] != nil && application.applicationState != .active
    cryptoBoundaryReady = pm_crypto_abi_version() == PM_CRYPTO_ABI_VERSION &&
      pm_crypto_available() == PM_CRYPTO_UNAVAILABLE
    guard cryptoBoundaryReady else { return false }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func registerPushChannels(_ engine: FlutterEngine) {
    guard let registrar = engine.registrar(forPlugin: "VeritraPush") else { return }
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
        _ = self.wakeCoordinator.unregister()
        result(nil)
      case "pendingWakeGeneration":
        result((try? self.wakeCoordinator.journal.load().pending) ?? 0)
      case "acknowledgeWake":
        guard let arguments = call.arguments as? [String: Any],
              let generation = arguments["generation"] as? NSNumber,
              generation.int64Value > 0 else {
          result(FlutterError(code: "invalid_arguments", message: "Wake generation is required", details: nil)); return
        }
        result((try? self.wakeCoordinator.journal.acknowledge(generation.int64Value)) ?? false)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Keeps the encrypted local database out of iCloud and computer backups
  /// (NSURLIsExcludedFromBackupKey). The Dart store sends its directory, so
  /// WAL and SHM files created later are covered, and the database files,
  /// before and after each open; paths that do not exist yet are skipped. A
  /// copied database cannot be opened without its keychain key, which is
  /// this-device-only; this keeps even that copy off other devices.
  private func registerStorageChannel(_ registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "VeritraStorage") else { return }
    FlutterMethodChannel(
      name: "org.veritra.private_messenger/storage",
      binaryMessenger: registrar.messenger()
    ).setMethodCallHandler { call, result in
      guard call.method == "excludeFromBackup" else { result(FlutterMethodNotImplemented); return }
      guard let arguments = call.arguments as? [String: Any],
            let paths = arguments["paths"] as? [String], !paths.isEmpty else {
        result(FlutterError(code: "invalid_arguments", message: "Paths are required", details: nil)); return
      }
      // Every path is tried: one that refuses must not leave the others in
      // backups. Failures are counted and reported once, at the end.
      var failures = 0
      for path in paths where FileManager.default.fileExists(atPath: path) {
        var url = URL(fileURLWithPath: path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
          try url.setResourceValues(values)
        } catch {
          failures += 1
        }
      }
      if failures > 0 {
        // A count only: an error description would name the file's path.
        result(FlutterError(code: "exclude_failed", message: nil, details: failures))
      } else {
        result(nil)
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
    let started = ProcessInfo.processInfo.systemUptime
    guard userInfo["event"] as? String == "new_encrypted_event_available" else {
      completionHandler(.noData); return
    }
    if userInfo["version"] as? String == "v2" {
      let customKeys = Set(userInfo.keys.compactMap { $0 as? String }).subtracting(["aps"])
      guard customKeys == Set(["version", "event", "presentation"]),
            userInfo["presentation"] as? String == "none" else {
        completionHandler(.noData); return
      }
      wakeCoordinator.receive(started: started, engineAvailable: { [weak self] in
        self?.sharedEngine(background: true) != nil
      }, completion: completionHandler)
      return
    }
    guard userInfo["version"] as? String == "v1" else { completionHandler(.noData); return }
    guard (try? wakeCoordinator.journal.mark()) != nil else { completionHandler(.failed); return }
    pushEvents?(["type": "wake"])
    // D53: a current server sends this wake as a visible alert that iOS shows
    // itself, so a local notice would be a duplicate. Only an older server's
    // background-only push still needs one. No delegate shows either while
    // the app is active.
    if !Self.carriesSystemAlert(userInfo) && application.applicationState != .active {
      let content = UNMutableNotificationContent()
      content.title = "Veritra"
      content.body = NSLocalizedString("veritra.notification.new_message", value: "New message",
                                       comment: "Generic notification; no sender or content (D53)")
      content.sound = .default
      UNUserNotificationCenter.current().add(
        UNNotificationRequest(identifier: "veritra-new-message", content: content, trigger: nil))
    }
    completionHandler(.newData)
  }

  /// Whether APNs already carries a visible alert for this push (D53).
  static func carriesSystemAlert(_ userInfo: [AnyHashable: Any]) -> Bool {
    guard let aps = userInfo["aps"] as? [String: Any], let alert = aps["alert"] else { return false }
    return !(alert is NSNull)
  }
}

/// A tiny protected metadata journal; never a message or credential cache.
final class IOSWakeJournal {
  struct State: Codable {
    var sequence: Int64; var pending: Int64; var profile: String?
    var notices: [String: Int64] = [:]; var noticeClock: Int64 = 0
    init(sequence: Int64, pending: Int64, profile: String?) {
      self.sequence = sequence; self.pending = pending; self.profile = profile
    }
    enum CodingKeys: String, CodingKey { case sequence, pending, profile, notices, noticeClock }
    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      sequence = try c.decode(Int64.self, forKey: .sequence)
      pending = try c.decode(Int64.self, forKey: .pending)
      profile = try c.decodeIfPresent(String.self, forKey: .profile)
      notices = try c.decodeIfPresent([String: Int64].self, forKey: .notices) ?? [:]
      noticeClock = try c.decodeIfPresent(Int64.self, forKey: .noticeClock) ?? 0
    }
  }
  enum Failure: Error { case unavailable }
  private let legacyKey = "veritra_pending_push_wake_generation"
  private func location() throws -> URL {
    guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { throw Failure.unavailable }
    return support.appendingPathComponent("veritra-wake", isDirectory: true)
  }
  func load() throws -> State {
    let file = try location().appendingPathComponent("state.json")
    guard FileManager.default.fileExists(atPath: file.path) else {
      let old = UserDefaults.standard.object(forKey: legacyKey) as? NSNumber
      let legacy = old?.int64Value ?? 0
      guard legacy >= 0 else { throw Failure.unavailable }
      return State(sequence: legacy, pending: legacy, profile: nil)
    }
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    guard let size = attributes[.size] as? NSNumber, size.int64Value <= 512 * 1024 else { throw Failure.unavailable }
    let state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
    guard state.sequence >= 0, state.pending >= 0, state.pending <= state.sequence,
          state.profile == nil || IOSWakeCoordinator.validProfile(state.profile!),
          state.notices.count <= 4096, state.noticeClock >= 0,
          state.notices.allSatisfy({ key, time in
            key.range(of: "\\A[a-z][a-z0-9-]{0,39}:[0-9a-f]{32}\\z", options: .regularExpression) != nil && time >= 0 && time <= state.noticeClock
          }) else { throw Failure.unavailable }
    return state
  }
  private func save(_ state: State) throws {
    let manager = FileManager.default
    var directory = try location()
    try manager.createDirectory(at: directory, withIntermediateDirectories: true,
      attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    var values = URLResourceValues(); values.isExcludedFromBackup = true
    try directory.setResourceValues(values)
    let temporary = directory.appendingPathComponent(".wake-\(UUID().uuidString).tmp")
    let target = directory.appendingPathComponent("state.json")
    let bytes = try JSONEncoder().encode(state)
    guard bytes.count <= 512 * 1024 else { throw Failure.unavailable }
    let descriptor = temporary.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR) }
    guard descriptor >= 0 else { throw Failure.unavailable }
    defer { Darwin.close(descriptor); try? manager.removeItem(at: temporary) }
    try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: temporary.path)
    try bytes.withUnsafeBytes { raw in
      var offset = 0
      while offset < raw.count {
        let written = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
        if written < 0 && errno == EINTR { continue }
        guard written > 0 else { throw Failure.unavailable }
        offset += written
      }
    }
    guard Darwin.fsync(descriptor) == 0 else { throw Failure.unavailable }
    let renamed = temporary.path.withCString { source in target.path.withCString { destination in Darwin.rename(source, destination) } }
    guard renamed == 0 else { throw Failure.unavailable }
    let parent = directory.path.withCString { Darwin.open($0, O_RDONLY) }
    guard parent >= 0 else { throw Failure.unavailable }
    defer { Darwin.close(parent) }
    guard Darwin.fsync(parent) == 0 else { throw Failure.unavailable }
    UserDefaults.standard.removeObject(forKey: legacyKey)
  }
  func mark() throws -> Int64 {
    var state = try load()
    guard state.sequence < Int64.max else { throw Failure.unavailable }
    state.sequence += 1; state.pending = state.sequence
    try save(state); return state.pending
  }
  func acknowledge(_ generation: Int64) throws -> Bool {
    var state = try load()
    guard generation > 0, state.pending == generation else { return false }
    state.pending = 0; try save(state); return true
  }
  // Durable at-most-once attempt: crash after this write can miss a generic
  // notice, but never repeats its sound. Full fresh journal fails closed.
  func claimNotice(_ profile: String, _ notice: String) throws -> Bool {
    var state = try load()
    let current = Int64(Date().timeIntervalSince1970 * 1000)
    guard current >= state.noticeClock else { throw Failure.unavailable }
    state.notices = state.notices.filter { current - $0.value <= 60 * 60 * 1000 }
    let key = profile + ":" + notice
    let fresh = state.notices[key] == nil
    guard !fresh || state.notices.count < 4096 else { throw Failure.unavailable }
    if fresh { state.notices[key] = current }
    state.noticeClock = current; try save(state); return fresh
  }
  func bind(_ profile: String?) throws {
    var state = try load(); state.profile = profile
    if profile == nil { state.pending = 0 }
    try save(state)
  }
}

final class IOSWakeCoordinator {
  // Enabling cold execution requires the reviewed existing-only Dart bootstrap.
  static let coldExecutionEnabled = false
  let journal = IOSWakeJournal()
  private var channel: FlutterMethodChannel?
  private var profile: String?
  private var launchBackground = false
  private var ui = false
  private final class Held {
    let generation: Int64, deadline: TimeInterval
    let completion: (UIBackgroundFetchResult) -> Void
    var timer: DispatchWorkItem?
    var done = false
    init(_ generation: Int64, _ deadline: TimeInterval, _ completion: @escaping (UIBackgroundFetchResult) -> Void) {
      self.generation = generation; self.deadline = deadline; self.completion = completion
    }
    func finish(_ result: UIBackgroundFetchResult) {
      guard !done else { return }; done = true; timer?.cancel(); completion(result)
    }
  }
  private final class Active {
    let id = UUID().uuidString.lowercased()
    let profile: String, generation: Int64, deadline: TimeInterval
    init(_ profile: String, _ generation: Int64, _ deadline: TimeInterval) {
      self.profile = profile; self.generation = generation; self.deadline = deadline
    }
  }
  private var waiting: [Held] = []
  private var active: Active?
  static func exactInteger(_ value: Any?) -> Int64? {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID(),
          ["i", "q", "s", "l"].contains(String(cString: number.objCType)) else { return nil }
    return number.int64Value
  }
  static func validProfile(_ value: String) -> Bool { value.range(of: "\\A[a-z][a-z0-9-]{0,39}\\z", options: .regularExpression) != nil }
  private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
  func attach(_ messenger: FlutterBinaryMessenger, background: Bool) {
    precondition(Thread.isMainThread && channel == nil)
    launchBackground = background
    let channel = FlutterMethodChannel(name: "org.veritra.private_messenger/wake_worker", binaryMessenger: messenger)
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(FlutterError(code: "wake_unavailable", message: nil, details: nil)); return }
      if call.method == "bootstrap", call.arguments == nil {
        do {
          let state = try self.journal.load()
          result(["protocol": 1, "launch": self.launchBackground ? "background" : "ui",
            "bound_profile": state.profile as Any? ?? NSNull(), "ui_attached": self.ui,
            "native_silent": true, "can_opt_in": false])
        } catch {
          // Notification metadata failure cannot manufacture background
          // readiness or prevent a real UI from opening its own protected store.
          result(["protocol": 1, "launch": self.launchBackground ? "background" : "ui",
            "bound_profile": NSNull(), "ui_attached": self.ui,
            "native_silent": false, "can_opt_in": false])
        }
        return
      }
      guard let args = call.arguments as? [String: Any], Self.exactInteger(args["protocol"]) == 1,
            let profile = args["profile"] as? String, Self.validProfile(profile) else {
        result(FlutterError(code: "invalid_wake_protocol", message: nil, details: nil)); return
      }
      switch call.method {
      case "install":
        guard Set(args.keys) == Set(["protocol", "profile"]), self.profile == nil || self.profile == profile else {
          result(FlutterError(code: "wake_owner_conflict", message: nil, details: nil)); return
        }
        do {
          try self.journal.bind(profile); self.profile = profile
          result(["protocol": 1, "native_silent": true, "worker_attached": true, "can_opt_in": false])
          self.startNext()
        } catch { result(FlutterError(code: "wake_storage_unavailable", message: nil, details: nil)) }
      case "uninstall":
        guard Set(args.keys) == Set(["protocol", "profile"]), self.profile == nil || self.profile == profile else { result(false); return }
        result(self.unregister())
      case "validatePermit", "presentGenericNotice":
        let allowed = call.method == "validatePermit" ? Set(["protocol", "permit", "profile"]) : Set(["protocol", "permit", "profile", "notice_id"])
        let id = args["permit"] as? String
        let valid = Set(args.keys) == allowed && id != nil && self.matches(id!, profile)
        if call.method == "validatePermit" {
          let remaining = valid ? max(0, Int((self.active!.deadline - self.now()) * 1000)) : 0
          result(["active": remaining > 0, "remaining_ms": remaining])
        } else {
          guard valid, let notice = args["notice_id"] as? String,
                notice.range(of: "\\A[0-9a-f]{32}\\z", options: .regularExpression) != nil else { result("unavailable"); return }
          self.present(id!, profile, notice, result)
        }
      default: result(FlutterMethodNotImplemented)
      }
    }
  }
  private func matches(_ id: String, _ profile: String) -> Bool {
    guard let active else { return false }
    return self.profile == profile && active.id == id && active.profile == profile && active.deadline > now()
  }
  func uiAttached(_ value: Bool) {
    ui = value
    if value { cancel("os_stop") }
    channel?.invokeMethod("uiAttached", arguments: ["protocol": 1, "attached": value])
  }
  func receive(started: TimeInterval, engineAvailable: () -> Bool, completion: @escaping (UIBackgroundFetchResult) -> Void) {
    precondition(Thread.isMainThread)
    guard let generation = try? journal.mark() else { completion(.failed); return }
    guard !ui else { completion(.noData); return }
    guard engineAvailable(), started + 20 > now() else { completion(.failed); return }
    let held = Held(generation, started + 20, completion)
    let timer = DispatchWorkItem { [weak self, weak held] in
      guard let self, let held, !held.done else { return }
      if let active = self.active, active.deadline <= self.now() { self.cancel("deadline") }
      held.finish(.failed); self.waiting.removeAll { $0.done }; self.startNext()
    }
    held.timer = timer; waiting.append(held)
    DispatchQueue.main.asyncAfter(deadline: .now() + max(0, held.deadline - now()), execute: timer)
    startNext()
  }
  private func startNext() {
    waiting.removeAll { $0.done }
    guard active == nil, !ui, let profile, let channel,
          let oldest = waiting.min(by: { $0.deadline < $1.deadline }),
          oldest.deadline > now(), let generation = try? journal.load().pending, generation > 0 else { return }
    let permit = Active(profile, generation, oldest.deadline); active = permit
    let budget = min(20000, Int((permit.deadline - now()) * 1000))
    guard budget > 0 else { cancel("deadline"); return }
    channel.invokeMethod("run", arguments: ["protocol": 1, "permit": permit.id,
      "profile": profile, "wake_generation": generation, "budget_ms": budget,
      "deadline_epoch_ms": Int64(Date().timeIntervalSince1970 * 1000) + Int64(budget)]) { [weak self] response in
      guard let self, self.active === permit else { return }
      let map = response as? [String: Any]
      let outcome = map?["outcome"] as? String
      let durable = self.now() < permit.deadline &&
        map.map { Set($0.keys) == Set(["protocol", "permit", "profile", "wake_generation", "outcome"]) } == true &&
        Self.exactInteger(map?["protocol"]) == 1 && map?["permit"] as? String == permit.id &&
        map?["profile"] as? String == profile && Self.exactInteger(map?["wake_generation"]) == generation &&
        (outcome == "committed" || outcome == "no_change")
      var ackFailed = false
      if durable {
        do { _ = try self.journal.acknowledge(generation) }
        catch { ackFailed = true } // Retain the pending marker; OS sees failure.
      }
      self.active = nil
      for item in self.waiting where item.generation <= generation {
        item.finish(durable && !ackFailed ? (outcome == "committed" ? .newData : .noData) : .failed)
      }
      self.waiting.removeAll { $0.done }
      DispatchQueue.main.async { self.startNext() }
    }
  }
  private func cancel(_ reason: String) {
    guard let permit = active else { return }
    active = nil // Revoke BEFORE signaling Dart or completing OS callbacks.
    channel?.invokeMethod("cancel", arguments: ["protocol": 1, "permit": permit.id, "profile": permit.profile, "reason": reason])
    for item in waiting where item.generation <= permit.generation { item.finish(.failed) }
    waiting.removeAll { $0.done }
  }
  func unregister() -> Bool {
    cancel("unregistered"); profile = nil
    for item in waiting { item.finish(.failed) }; waiting.removeAll()
    do { try journal.bind(nil); return true } catch { return false }
  }
  private func present(_ id: String, _ profile: String, _ notice: String, _ result: @escaping FlutterResult) {
    guard !ui, UIApplication.shared.applicationState != .active else { result("suppressed"); return }
    UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
      DispatchQueue.main.async {
        guard let self, self.matches(id, profile) else { result("unavailable"); return }
        guard !self.ui, UIApplication.shared.applicationState != .active,
              settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { result("suppressed"); return }
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
          center.getPendingNotificationRequests { pending in
            DispatchQueue.main.async {
              guard self.matches(id, profile), !self.ui,
                    UIApplication.shared.applicationState != .active else { result("unavailable"); return }
              let identifier = "veritra-local-" + notice
              let already = delivered.contains { $0.request.identifier == identifier } || pending.contains { $0.identifier == identifier }
              do {
                let fresh = try self.journal.claimNotice(profile, notice)
                guard fresh && !already else { result("suppressed"); return }
              } catch { result("unavailable"); return }
              guard self.matches(id, profile), !self.ui,
                    UIApplication.shared.applicationState != .active else { result("unavailable"); return }
              let content = UNMutableNotificationContent()
              content.title = "Veritra"; content.body = "New encrypted message"; content.sound = .default
              center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { error in
                DispatchQueue.main.async { result(error == nil ? "shown" : "unavailable") }
              }
            }
          }
        }
      }
    }
  }
}
