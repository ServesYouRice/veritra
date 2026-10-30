import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  private weak var connectedScene: UIWindowScene?
  private func attachUI() {
    guard window == nil, let scene = connectedScene,
          let app = UIApplication.shared.delegate as? AppDelegate else { return }
    app.setWakeUIAttached(true)
    guard let engine = app.sharedEngine() else { return }
    let sceneWindow = UIWindow(windowScene: scene)
    sceneWindow.rootViewController = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
    window = sceneWindow
    sceneWindow.makeKeyAndVisible()
  }
  override func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
      options connectionOptions: UIScene.ConnectionOptions) {
    connectedScene = scene as? UIWindowScene
    let app = UIApplication.shared.delegate as? AppDelegate
    // A notification launch must not turn scene connection alone into UI/key
    // initialization. Actual foreground scene transition attaches the view.
    if app?.backgroundLaunchHint == false && UIApplication.shared.applicationState != .background { attachUI() }
    super.scene(scene, willConnectTo: session, options: connectionOptions)
  }
  override func sceneWillEnterForeground(_ scene: UIScene) {
    attachUI()
    super.sceneWillEnterForeground(scene)
  }
  override func sceneDidBecomeActive(_ scene: UIScene) {
    attachUI()
    super.sceneDidBecomeActive(scene)
    (UIApplication.shared.delegate as? AppDelegate)?.setWakeUIAttached(true)
  }
  override func sceneWillResignActive(_ scene: UIScene) {
    (UIApplication.shared.delegate as? AppDelegate)?.setWakeUIAttached(false)
    super.sceneWillResignActive(scene)
  }
  override func sceneDidDisconnect(_ scene: UIScene) {
    let app = UIApplication.shared.delegate as? AppDelegate
    app?.setWakeUIAttached(false)
    app?.detachSharedView(window?.rootViewController)
    window = nil; connectedScene = nil
    super.sceneDidDisconnect(scene)
  }
}
