import Cocoa
import FlutterMacOS

final class DesktopClipboardImagePlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "com.vireen.whisper/desktop_clipboard_image",
      binaryMessenger: registrar.messenger)
    let instance = DesktopClipboardImagePlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "readImagePng":
      guard let data = readImagePng() else {
        result(nil)
        return
      }
      result(FlutterStandardTypedData(bytes: data))
    case "readFilePaths":
      result(readFilePaths())
    case "changeToken":
      // Grows with every change of the clipboard, by any program.
      result(NSPasteboard.general.changeCount)
    case "clearFilePaths":
      // The file manager's own earlier copy, while a newer one is on its
      // way; Dart checks it is still its own first.
      NSPasteboard.general.clearContents()
      result(true)
    case "writeFilePaths":
      guard let arguments = call.arguments as? [String: Any],
            let paths = arguments["paths"] as? [String] else {
        result(FlutterError(code: "invalid_paths", message: nil, details: nil))
        return
      }
      result(writeFilePaths(paths, asImage: arguments["asImage"] as? Bool ?? false))
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func readImagePng() -> Data? {
    let pasteboard = NSPasteboard.general
    if let pngData = pasteboard.data(forType: .png), !pngData.isEmpty {
      return pngData
    }
    if let tiffData = pasteboard.data(forType: .tiff),
       let pngData = pngData(fromTiff: tiffData) {
      return pngData
    }
    let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil)
    guard let image = images?.first as? NSImage else {
      return nil
    }
    return pngData(from: image)
  }

  private func pngData(from image: NSImage) -> Data? {
    guard let tiffData = image.tiffRepresentation else {
      return nil
    }
    return pngData(fromTiff: tiffData)
  }

  private func pngData(fromTiff data: Data) -> Data? {
    guard let bitmap = NSBitmapImageRep(data: data) else {
      return nil
    }
    return bitmap.representation(using: .png, properties: [:])
  }

  private func readFilePaths() -> [String] {
    let pasteboard = NSPasteboard.general
    let options: [NSPasteboard.ReadingOptionKey: Any] = [
      .urlReadingFileURLsOnly: true
    ]
    let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
    return urls?
      .filter { $0.isFileURL }
      .map { $0.path } ?? []
  }

  private func writeFilePaths(_ paths: [String], asImage: Bool) -> Bool {
    let urls = paths.map { URL(fileURLWithPath: $0) }
    guard !urls.isEmpty, urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
      return false
    }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    if asImage, urls.count == 1,
       let image = NSImage(contentsOf: urls[0]),
       let tiff = image.tiffRepresentation,
       let bitmap = NSBitmapImageRep(data: tiff),
       let png = bitmap.representation(using: .png, properties: [:]) {
      let item = NSPasteboardItem()
      item.setString(urls[0].absoluteString, forType: .fileURL)
      item.setData(png, forType: .png)
      return pasteboard.writeObjects([item])
    }
    return pasteboard.writeObjects(urls as [NSURL])
  }
}
