import ActivityKit
import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Lets monitor alerts appear as banners while the app is in the foreground.
    UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ObdLiveActivityBridge") {
      LiveActivityBridge.register(with: registrar)
    }
  }
}

/// The data shown in the Live Activity.
///
/// KEEP IN SYNC with the copy in ios/ObdLiveActivity/DashboardLiveActivity.swift:
/// the widget extension is a separate program, and iOS matches the two by this
/// type's name and its Codable layout.
@available(iOS 18.0, *)
struct DashboardAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    struct Item: Codable, Hashable {
      var label: String
      var value: String
      var unit: String
      var fraction: Double
    }

    var items: [Item]
    var alert: String
    var critical: Bool
  }

  var vehicle: String
}

/// Receives the selected live values from Dart (lib/app/live_activity.dart)
/// and shows them in a Live Activity. From iOS 26 the system displays Live
/// Activities on the CarPlay Dashboard, which needs no CarPlay entitlement.
final class LiveActivityBridge: NSObject, FlutterPlugin {
  /// The running `Activity<DashboardAttributes>`. Typed as `Any` because
  /// stored properties cannot carry an availability attribute.
  private var current: Any?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "obdscan/live_activity", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(LiveActivityBridge(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard #available(iOS 18.0, *) else {
      result(false)
      return
    }
    let arguments = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "start":
      result(start(vehicle: arguments["vehicle"] as? String ?? "Vehicle"))
    case "update":
      update(arguments)
      result(nil)
    case "end":
      end()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  @available(iOS 18.0, *)
  private func start(vehicle: String) -> Bool {
    guard ActivityAuthorizationInfo().areActivitiesEnabled else { return false }
    // Remove anything left over from a previous run of the app.
    for stale in Activity<DashboardAttributes>.activities {
      Task { await stale.end(nil, dismissalPolicy: .immediate) }
    }
    let state = DashboardAttributes.ContentState(items: [], alert: "", critical: false)
    do {
      current = try Activity<DashboardAttributes>.request(
        attributes: DashboardAttributes(vehicle: vehicle),
        content: ActivityContent(state: state, staleDate: nil),
        pushType: nil
      )
      return true
    } catch {
      NSLog("OBD Scan: could not start Live Activity: \(error.localizedDescription)")
      return false
    }
  }

  @available(iOS 18.0, *)
  private func update(_ arguments: [String: Any]) {
    guard let activity = current as? Activity<DashboardAttributes> else { return }
    let rawItems = arguments["items"] as? [[String: Any]] ?? []
    let items = rawItems.map { raw in
      DashboardAttributes.ContentState.Item(
        label: raw["label"] as? String ?? "",
        value: raw["value"] as? String ?? "",
        unit: raw["unit"] as? String ?? "",
        fraction: (raw["fraction"] as? NSNumber)?.doubleValue ?? 0
      )
    }
    let state = DashboardAttributes.ContentState(
      items: items,
      alert: arguments["alert"] as? String ?? "",
      critical: arguments["critical"] as? Bool ?? false
    )
    // If updates stop (app suspended or closed) the view shows "waiting" after 30 s.
    let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(30))
    Task { await activity.update(content) }
  }

  @available(iOS 18.0, *)
  private func end() {
    guard let activity = current as? Activity<DashboardAttributes> else { return }
    current = nil
    Task { await activity.end(nil, dismissalPolicy: .immediate) }
  }
}
