import Cocoa
import FlutterMacOS

final class DesktopQuickSendBridge {
  static let shared = DesktopQuickSendBridge()
  private static let maximumPendingCount = 32

  private struct PendingEntry: Codable {
    let id: String
    let arguments: [String]
  }

  private struct PendingRejection: Codable {
    let id: String
    let reason: String
    let limit: Int
  }

  private struct PersistentState: Codable {
    var entries: [PendingEntry] = []
    var rejection: PendingRejection?
  }

  private var channel: FlutterMethodChannel?
  private var state: PersistentState

  private init() {
    state = Self.loadState()
  }

  func attach(channel: FlutterMethodChannel) {
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(
          code: "quick_send_unavailable",
          message: "The native quick-send queue is unavailable",
          details: nil))
        return
      }
      if call.method == "consumePendingQuickSends" {
        result(self.snapshot())
        return
      }
      if call.method == "acknowledgeQuickSend",
         let id = call.arguments as? String {
        result(self.acknowledge(id: id))
        return
      }
      if call.method != "consumePendingQuickSends" {
        result(FlutterMethodNotImplemented)
      }
    }
    wakeDart()
  }

  @discardableResult
  func enqueue(arguments: [String]) -> Bool {
    guard !arguments.isEmpty else {
      return false
    }
    if state.entries.count >= Self.maximumPendingCount {
      var next = state
      next.rejection = PendingRejection(
        id: "macos-rejection-\(UUID().uuidString.lowercased())",
        reason: "draftLimitExceeded",
        limit: Self.maximumPendingCount)
      guard Self.persist(next) else {
        return false
      }
      state = next
      wakeDart()
      return false
    }
    state.entries.append(PendingEntry(
      id: "macos-\(UUID().uuidString.lowercased())",
      arguments: arguments))
    guard persistState() else {
      state.entries.removeLast()
      return false
    }
    wakeDart()
    return true
  }

  private func snapshot() -> [[String: Any]] {
    var values = state.entries.map { entry in
      ["id": entry.id, "arguments": entry.arguments] as [String: Any]
    }
    if let rejection = state.rejection {
      values.append([
        "id": rejection.id,
        "rejection": [
          "reason": rejection.reason,
          "limit": rejection.limit,
        ],
      ])
    }
    return values
  }

  private func acknowledge(id: String) -> Bool {
    var next = state
    if next.rejection?.id == id {
      next.rejection = nil
    } else if let index = next.entries.firstIndex(where: { $0.id == id }) {
      next.entries.remove(at: index)
    } else {
      return true
    }
    guard Self.persist(next) else {
      return false
    }
    state = next
    return true
  }

  private func wakeDart() {
    channel?.invokeMethod("quickSendReceived", arguments: nil)
  }

  private func persistState() -> Bool {
    Self.persist(state)
  }

  private static var stateURL: URL? {
    guard let directory = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask).first else {
      return nil
    }
    return directory
      .appendingPathComponent("Whisper", isDirectory: true)
      .appendingPathComponent("desktop_quick_send_queue.json")
  }

  private static func loadState() -> PersistentState {
    guard let url = stateURL,
          let data = try? Data(contentsOf: url),
          let decoded = try? JSONDecoder().decode(PersistentState.self, from: data) else {
      return PersistentState()
    }
    return decoded
  }

  private static func persist(_ state: PersistentState) -> Bool {
    guard let url = stateURL else {
      return false
    }
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true)
      let data = try JSONEncoder().encode(state)
      try data.write(to: url, options: .atomic)
      return true
    } catch {
      return false
    }
  }
}

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.servicesProvider = self
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    guard !flag else {
      return true
    }

    sender.unhide(nil)
    if let window = sender.windows.first(where: { $0 is MainFlutterWindow }) ??
        sender.windows.first {
      if window.isMiniaturized {
        window.deminiaturize(nil)
      }
      window.makeKeyAndOrderFront(nil)
    }
    sender.activate(ignoringOtherApps: true)
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func application(_ sender: NSApplication, openFiles filenames: [String]) {
    let accepted = DesktopQuickSendBridge.shared.enqueue(
      arguments: ["--quick-send"] + filenames)
    revealMainWindow(sender)
    sender.reply(toOpenOrPrint: accepted ? .success : .failure)
  }

  @objc(receiveQuickSendService:userData:error:)
  func receiveQuickSendService(
    _ pasteboard: NSPasteboard,
    userData: String,
    error: AutoreleasingUnsafeMutablePointer<NSString>
  ) {
    let options: [NSPasteboard.ReadingOptionKey: Any] = [
      .urlReadingFileURLsOnly: true
    ]
    let urls = pasteboard.readObjects(
      forClasses: [NSURL.self],
      options: options) as? [URL] ?? []
    let paths = urls.filter(\.isFileURL).map(\.path)
    if !paths.isEmpty {
      let accepted = DesktopQuickSendBridge.shared.enqueue(
        arguments: ["--quick-send"] + paths)
      revealMainWindow(NSApp)
      if !accepted {
        error.pointee = "Whisper quick send is full. Process pending content before adding more."
      }
      return
    }
    if let text = pasteboard.string(forType: .string), !text.isEmpty {
      let accepted = DesktopQuickSendBridge.shared.enqueue(
        arguments: ["--quick-send-text", text])
      revealMainWindow(NSApp)
      if !accepted {
        error.pointee = "Whisper quick send is full. Process pending content before adding more."
      }
      return
    }
    error.pointee = "Whisper could not read the selected content."
  }

  private func revealMainWindow(_ sender: NSApplication) {
    sender.unhide(nil)
    if let window = sender.windows.first(where: { $0 is MainFlutterWindow }) ??
        sender.windows.first {
      if window.isMiniaturized {
        window.deminiaturize(nil)
      }
      window.makeKeyAndOrderFront(nil)
    }
    sender.activate(ignoringOtherApps: true)
  }
}
