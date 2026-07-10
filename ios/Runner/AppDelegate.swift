import UIKit
import Flutter
import AVFoundation
import MobileCoreServices
import Network
import dnssd

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {

    var documentBrowserViewController: UIDocumentBrowserViewController?
    private let audioSharePlugin = IOSAudioSharePlugin()
    private let localNetworkPermissionPlugin = IOSLocalNetworkPermissionPlugin()

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let controller: FlutterViewController = window?.rootViewController as! FlutterViewController
        let dirChannel = FlutterMethodChannel(name: "com.vireen.whisper/ios_dir", binaryMessenger: controller.binaryMessenger)
        audioSharePlugin.register(binaryMessenger: controller.binaryMessenger)
        localNetworkPermissionPlugin.register(binaryMessenger: controller.binaryMessenger)

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

final class IOSLocalNetworkPermissionPlugin {
    private var channel: FlutterMethodChannel?
    private var browser: NWBrowser?
    private var pendingResults: [FlutterResult] = []
    private var probeGeneration = 0
    private var backgroundObserver: NSObjectProtocol?

    deinit {
        if let backgroundObserver = backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
        }
    }

    func register(binaryMessenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(
            name: "com.vireen.whisper/local_network_permission",
            binaryMessenger: binaryMessenger
        )
        self.channel = channel
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self = self else {
                result("unknown")
                return
            }
            switch call.method {
            case "currentStatus":
                result("unknown")
            case "ensureGranted":
                self.ensureGranted(result: result)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.finishProbe(status: "retryable")
        }
    }

    private func ensureGranted(result: @escaping FlutterResult) {
        guard UIApplication.shared.applicationState == .active else {
            result("unavailable")
            return
        }
        pendingResults.append(result)
        guard browser == nil else {
            return
        }

        probeGeneration += 1
        let generation = probeGeneration
        let browser = NWBrowser(
            for: .bonjour(type: "_whisper._tcp", domain: "local."),
            using: .tcp
        )
        self.browser = browser
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard let self = self,
                  let browser = browser,
                  browser === self.browser else {
                return
            }
            switch state {
            case .ready:
                self.finishProbe(status: "granted")
            case .waiting(let error), .failed(let error):
                self.finishProbe(status: self.status(for: error))
            case .cancelled:
                self.finishProbe(status: "retryable")
            case .setup:
                break
            @unknown default:
                self.finishProbe(status: "unknown")
            }
        }
        browser.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self, self.probeGeneration == generation else {
                return
            }
            self.finishProbe(status: "retryable")
        }
    }

    private func status(for error: NWError) -> String {
        switch error {
        case .dns(let code):
            return Int32(code) == kDNSServiceErr_PolicyDenied
                ? "denied"
                : "retryable"
        case .posix(let code):
            switch code {
            case .ENETDOWN, .ENETUNREACH, .EHOSTUNREACH, .ENODEV, .ENXIO:
                return "unavailable"
            default:
                return "retryable"
            }
        default:
            return "retryable"
        }
    }

    private func finishProbe(status: String) {
        guard browser != nil || !pendingResults.isEmpty else {
            return
        }
        probeGeneration += 1
        let activeBrowser = browser
        browser = nil
        activeBrowser?.stateUpdateHandler = nil
        activeBrowser?.cancel()
        let results = pendingResults
        pendingResults.removeAll()
        results.forEach { $0(status) }
    }
}

final class IOSAudioSharePlugin {
    private var channel: FlutterMethodChannel?
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var playbackFormat: AVAudioFormat?
    private var playbackChannels = 0
    private var playbackSessionId = ""

    func register(binaryMessenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(
            name: "com.vireen.whisper/audio_share",
            binaryMessenger: binaryMessenger
        )
        self.channel = channel
        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call: call, result: result)
        }
    }

    private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "startPlayback":
            guard let args = call.arguments as? [String: Any],
                  let sessionId = args["sessionId"] as? String,
                  let format = args["format"] as? [String: Any] else {
                result(FlutterError(
                    code: "bad-arguments",
                    message: "startPlayback requires sessionId and format",
                    details: nil
                ))
                return
            }
            do {
                try startPlayback(sessionId: sessionId, format: format)
                result(nil)
            } catch {
                result(FlutterError(
                    code: "audio-playback",
                    message: error.localizedDescription,
                    details: nil
                ))
            }

        case "writePcm":
            guard let args = call.arguments as? [String: Any],
                  let sessionId = args["sessionId"] as? String,
                  let pcm = pcmData(from: args["pcm"]) else {
                result(FlutterError(
                    code: "bad-arguments",
                    message: "writePcm requires sessionId and pcm",
                    details: nil
                ))
                return
            }
            writePcm(sessionId: sessionId, pcm: pcm)
            result(nil)

        case "stopPlayback":
            let args = call.arguments as? [String: Any]
            stopPlayback(sessionId: args?["sessionId"] as? String ?? "")
            result(nil)

        case "startCapture", "stopCapture":
            result(FlutterMethodNotImplemented)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func startPlayback(sessionId: String, format: [String: Any]) throws {
        stopPlayback()
        playbackSessionId = sessionId

        try AVAudioSession.sharedInstance().setCategory(
            .playback,
            mode: .default,
            options: [.mixWithOthers]
        )
        try AVAudioSession.sharedInstance().setActive(true)

        let sampleRate = Double(format["sampleRate"] as? Int ?? 48000)
        let channels = AVAudioChannelCount(format["channels"] as? Int ?? 2)
        guard let audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: max(1, min(channels, 2)),
            interleaved: false
        ) else {
            throw NSError(
                domain: "IOSAudioSharePlugin",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid playback format"]
            )
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: audioFormat)
        try engine.start()
        player.play()

        self.engine = engine
        self.player = player
        playbackFormat = audioFormat
        playbackChannels = Int(audioFormat.channelCount)
    }

    private func writePcm(sessionId: String, pcm: Data) {
        guard sessionId == playbackSessionId,
              let player = player,
              let format = playbackFormat,
              pcm.count > 0 else {
            return
        }

        guard playbackChannels > 0 else {
            return
        }
        let sourceBytesPerFrame = playbackChannels * MemoryLayout<Int16>.size
        let frameCount = AVAudioFrameCount(pcm.count / sourceBytesPerFrame)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: frameCount
              ) else {
            return
        }
        buffer.frameLength = frameCount
        guard let channelData = buffer.floatChannelData else {
            return
        }
        pcm.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for frame in 0..<Int(frameCount) {
                for channel in 0..<playbackChannels {
                    let byteIndex = (frame * playbackChannels + channel) * 2
                    let lo = UInt16(bytes[byteIndex])
                    let hi = UInt16(bytes[byteIndex + 1]) << 8
                    let sample = Int16(littleEndian: Int16(bitPattern: hi | lo))
                    channelData[channel][frame] = Float(sample) / 32768.0
                }
            }
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
        if !player.isPlaying {
            player.play()
        }
    }

    private func stopPlayback(sessionId: String = "") {
        if !sessionId.isEmpty && sessionId != playbackSessionId {
            return
        }
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        playbackFormat = nil
        playbackChannels = 0
        playbackSessionId = ""
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: [.notifyOthersOnDeactivation]
        )
    }

    private func pcmData(from value: Any?) -> Data? {
        if let data = value as? FlutterStandardTypedData {
            return data.data
        }
        return value as? Data
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
