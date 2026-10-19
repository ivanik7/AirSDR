import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    RecordFolderChannel.register(with: flutterViewController)
    super.awakeFromNib()
  }
}

// A sandboxed app needs a security-scoped bookmark, not just a saved path.
// Keep the resolved scope open while the native recording writer uses file:.
private final class RecordFolderChannel {
  private static let bookmarkKey = "recording.folder.securityScopedBookmark"
  private static var activeURL: URL?

  static func register(with controller: FlutterViewController) {
    let channel = FlutterMethodChannel(name: "sdr/record_folder_macos",
                                       binaryMessenger: controller.engine.binaryMessenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "choose":
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
          guard response == .OK, let url = panel.url else {
            result(nil)
            return
          }
          do {
            let bookmark = try url.bookmarkData(options: .withSecurityScope,
                                                includingResourceValuesForKeys: nil,
                                                relativeTo: nil)
            guard url.startAccessingSecurityScopedResource() else {
              result(FlutterError(code: "unavailable", message: "Folder access denied", details: nil))
              return
            }
            // Do not replace the last usable bookmark with an unwritable
            // selection: Dart validates only after this method returns.
            let probe = url.appendingPathComponent(".airsdr-probe-\(UUID().uuidString)")
            do {
              let payload = Data([0x5a])
              try payload.write(to: probe, options: .withoutOverwriting)
              defer { try? FileManager.default.removeItem(at: probe) }
              guard try Data(contentsOf: probe) == payload else {
                throw CocoaError(.fileReadCorruptFile)
              }
            } catch {
              url.stopAccessingSecurityScopedResource()
              result(FlutterError(code: "unavailable", message: "Folder is not writable: \(error.localizedDescription)", details: nil))
              return
            }
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
            activeURL?.stopAccessingSecurityScopedResource()
            activeURL = url
            result(["locator": "file:\(url.path)", "displayName": url.lastPathComponent])
          } catch {
            result(FlutterError(code: "unavailable", message: error.localizedDescription, details: nil))
          }
        }
      case "validate":
        guard let locator = call.arguments as? String,
              let data = UserDefaults.standard.data(forKey: bookmarkKey) else {
          result(false)
          return
        }
        do {
          var stale = false
          let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope,
                            relativeTo: nil, bookmarkDataIsStale: &stale)
          guard !stale, locator == "file:\(url.path)" else {
            result(false)
            return
          }
          if activeURL != url {
            guard url.startAccessingSecurityScopedResource() else {
              result(false)
              return
            }
            activeURL?.stopAccessingSecurityScopedResource()
            activeURL = url
          }
          result(true)
        } catch {
          result(false)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
