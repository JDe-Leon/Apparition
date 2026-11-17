import Foundation

/// The personalized Developer Disk Image that debugserver needs mounted (iOS 17 and later),
/// so JIT works without another app mounting it first. Mounted at most once per restart of
/// the device; the files are downloaded once and kept.
enum DeveloperDiskImage {
    /// Xcode's personalized iOS image, as StikDebug and pymobiledevice3 fetch it. The device
    /// only mounts it once Apple's TSS server has signed it for this device, so a changed file
    /// would be refused rather than mounted.
    static let source = URL(string: "https://raw.githubusercontent.com/doronz88/DeveloperDiskImage/main/PersonalizedImages/Xcode_iOS_DDI_Personalized/")!
    static let files = ["Image.dmg", "Image.dmg.trustcache", "BuildManifest.plist"]

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeveloperDiskImage", isDirectory: true)
    }

    static var hasFiles: Bool {
        files.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    /// Downloads whichever files are missing. Blocks: call off the main thread.
    static func download() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in files {
            let destination = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: destination.path) { continue }
            let done = DispatchSemaphore(value: 0)
            var failure: Error?
            let task = URLSession.shared.downloadTask(with: source.appendingPathComponent(name)) { location, response, error in
                defer { done.signal() }
                if let error { failure = error; return }
                guard let location, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    failure = IDevice.ProbeError("downloading \(name) failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))")
                    return
                }
                do { try FileManager.default.moveItem(at: location, to: destination) } catch { failure = error }
            }
            task.resume()
            done.wait()
            if let failure { throw failure }
        }
    }

    /// Mounts the image over an open tunnel unless one is mounted, downloading its files the
    /// first time. Returns a line for the JIT session's events; never throws, since JIT can still
    /// work when something else mounted the image.
    static func ensure(adapter: OpaquePointer?, handshake: OpaquePointer?) -> String {
        var reply = AccountModel.call(apparition_ensure_ddi(adapter, handshake, hasFiles ? directory.path : nil))
        if reply["ok"] as? Bool == true, reply["needsFiles"] as? Bool == true {
            do { try download() } catch { return "disk image: couldn't download it: \(error)" }
            reply = AccountModel.call(apparition_ensure_ddi(adapter, handshake, directory.path))
        }
        guard reply["ok"] as? Bool == true else {
            return "disk image: \(reply["error"] as? String ?? "mounting failed")"
        }
        switch reply["mounted"] as? String {
        case "already": return "disk image: already mounted"
        case "now": return "disk image: mounted"
        default: return "disk image: not mounted"
        }
    }

    /// Adds the mount's line to a JIT reply's events, and to its error when JIT failed.
    static func annotate(_ reply: [String: Any], with line: String) -> [String: Any] {
        var reply = reply
        reply["events"] = [line] + (reply["events"] as? [String] ?? [])
        if reply["ok"] as? Bool != true, line != "disk image: already mounted", line != "disk image: mounted" {
            reply["error"] = "\(reply["error"] as? String ?? "JIT failed") (\(line))"
        }
        return reply
    }
}
