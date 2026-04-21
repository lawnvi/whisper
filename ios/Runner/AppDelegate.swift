import UIKit
import Flutter
import MobileCoreServices

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {

    var documentBrowserViewController: UIDocumentBrowserViewController?

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let controller: FlutterViewController = window?.rootViewController as! FlutterViewController
        let dirChannel = FlutterMethodChannel(name: "com.vireen.whisper/ios_dir", binaryMessenger: controller.binaryMessenger)

        dirChannel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
            switch call.method {
            case "openFolder":
                self?.openDir(call: call, result: result)
            case "availableBytes":
                self?.availableBytes(call: call, result: result)
            default:
                result(FlutterMethodNotImplemented)
            }
        }

        GeneratedPluginRegistrant.register(with: self)
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    private func showAlert(_ message: String) {
        let alertController = UIAlertController(title: "Flutter Alert", message: message, preferredStyle: .alert)
        alertController.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))

        if let viewController = UIApplication.shared.keyWindow?.rootViewController {
            viewController.present(alertController, animated: true, completion: nil)
        }
    }

    private func openDir(call: FlutterMethodCall, result: @escaping FlutterResult) {
        if let arguments = call.arguments as? [String: Any], let path = arguments["path"] as? String {

        let uri = URL(fileURLWithPath: path)
        let activityViewController = UIActivityViewController(activityItems: [uri], applicationActivities: nil)
        if let viewController = UIApplication.shared.keyWindow?.rootViewController {
            viewController.present(activityViewController, animated: true, completion: nil)
        }


        let url = URL(fileURLWithPath: path)
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: path) && fileManager.isReadableFile(atPath: path) {
            documentBrowserViewController = UIDocumentBrowserViewController(forOpeningFilesWithContentTypes: [kUTTypeFolder as String])
            documentBrowserViewController?.delegate = self
            documentBrowserViewController?.allowsPickingMultipleItems = false

            // Set initial directory
//                documentBrowserViewController?.directoryURL = url

            if let viewController = UIApplication.shared.keyWindow?.rootViewController {
                viewController.present(documentBrowserViewController!, animated: true, completion: nil)
            }
            result(nil)
                
        } else {
                // If the folder doesn't exist or isn't readable
                showAlert("无效的文件夹路径")
                result("无效的文件夹路径")
            }
        }
    }

    private func availableBytes(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let arguments = call.arguments as? [String: Any],
              let path = arguments["path"] as? String else {
            result(nil)
            return
        }

        do {
            let values = try FileManager.default.attributesOfFileSystem(forPath: path)
            result(values[.systemFreeSize] as? NSNumber)
        } catch {
            result(nil)
        }
    }
}

extension AppDelegate: UIDocumentBrowserViewControllerDelegate {
    func documentBrowser(_ controller: UIDocumentBrowserViewController, didPickDocumentURLs documentURLs: [URL]) {
        // Handle the picked document URLs if needed
    }

    func documentBrowser(_ controller: UIDocumentBrowserViewController, didPickDocumentsAt documentURLs: [URL]) {
        // Handle the picked documents URLs
    }
}
