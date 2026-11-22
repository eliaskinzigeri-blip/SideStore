//
//  TweakSources.swift
//  SideStore
//
//  SideStore shell: tweaks that come from a download link and keep themselves up to date.
//
//  A tweak added "from a link" remembers that link. SideStore downloads it again when it starts
//  (at most every 30 minutes) or when asked from the Tweaks screen, and replaces the file when its
//  content changed. LiveContainer signs the new file the next time the app is launched.
//  needs proper testing on device
//

import Foundation
import CryptoKit

struct TweakSourceEntry: Codable, Equatable
{
    /// Path of the tweak inside LiveContainer's Tweaks folder, without the ".disabled" suffix.
    var relativePath: String
    var url: URL
    var sha256: String
    var lastUpdate: Date
}

enum TweakSourceError: LocalizedError
{
    case unavailable
    case notADylib(String)
    case badResponse(Int)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return NSLocalizedString("The LiveContainer engine is not available.", comment: "")
        case .notADylib(let name):
            return String(format: NSLocalizedString("“%@” is not a tweak (.dylib).", comment: ""), name)
        case .badResponse(let code):
            return String(format: NSLocalizedString("The download failed (HTTP %d).", comment: ""), code)
        }
    }
}

struct TweakUpdateReport
{
    /// Number of linked tweaks that were checked.
    var checked = 0
    var updated: [String] = []
    /// Tweak name -> error description.
    var failed: [String: String] = [:]
}

enum TweakSources
{
    private static let entriesKey = "SCTweakSources"
    private static let lastCheckKey = "SCTweakSourcesLastCheck"

    static var tweaksRootURL: URL? {
        ContainerBridge.hostHomeURL?.appendingPathComponent("Documents/Tweaks", isDirectory: true)
    }

    static var entries: [TweakSourceEntry] {
        get {
            guard let data = UserDefaults.standard.data(forKey: entriesKey),
                  let entries = try? JSONDecoder().decode([TweakSourceEntry].self, from: data)
            else { return [] }
            return entries
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: entriesKey)
        }
    }

    static func relativePath(of fileURL: URL) -> String? {
        guard let root = tweaksRootURL?.standardizedFileURL.path else { return nil }
        var path = fileURL.standardizedFileURL.path
        if path.hasSuffix(".disabled") { path = String(path.dropLast(".disabled".count)) }
        guard path.hasPrefix(root + "/") else { return nil }
        return String(path.dropFirst(root.count + 1))
    }

    static func entry(for fileURL: URL) -> TweakSourceEntry? {
        guard let relativePath = relativePath(of: fileURL) else { return nil }
        return entries.first { $0.relativePath == relativePath }
    }

    static func forget(fileURL: URL) {
        guard let relativePath = relativePath(of: fileURL) else { return }
        entries.removeAll { $0.relativePath == relativePath }
    }

    /// Keeps the link when a tweak is moved to another folder.
    static func move(from oldURL: URL, to newURL: URL) {
        guard let oldPath = relativePath(of: oldURL), let newPath = relativePath(of: newURL) else { return }
        var all = entries
        for index in all.indices where all[index].relativePath == oldPath {
            all[index].relativePath = newPath
        }
        entries = all
    }

    private static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TweakSourceError.badResponse(http.statusCode)
        }
        return data
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Downloads a tweak into `folderURL` and remembers its link. Returns the file written.
    @discardableResult
    static func add(from url: URL, into folderURL: URL) async throws -> URL {
        let name = url.lastPathComponent
        guard name.hasSuffix(".dylib") else { throw TweakSourceError.notADylib(name) }

        let data = try await download(url)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let fileURL = folderURL.appendingPathComponent(name)
        try data.write(to: fileURL, options: .atomic)
        InjectedTweaks.prepareForContainer(fileURL)

        guard let relativePath = relativePath(of: fileURL) else { throw TweakSourceError.unavailable }
        var all = entries.filter { $0.relativePath != relativePath }
        all.append(TweakSourceEntry(relativePath: relativePath, url: url, sha256: sha256(data), lastUpdate: Date()))
        entries = all
        return fileURL
    }

    /// Checks every linked tweak and replaces the ones that changed.
    @discardableResult
    static func updateAll(force: Bool = false) async -> TweakUpdateReport {
        var report = TweakUpdateReport()
        guard ContainerBridge.isAvailable, let root = tweaksRootURL else { return report }
        
        let defaults = UserDefaults.standard
        if !force, let last = defaults.object(forKey: lastCheckKey) as? Date, Date().timeIntervalSince(last) < 30 * 60 {
            return report
        }
        defaults.set(Date(), forKey: lastCheckKey)

        let fileManager = FileManager.default
        var all = entries

        for index in all.indices {
            let entry = all[index]
            let enabledURL = root.appendingPathComponent(entry.relativePath)
            let disabledURL = URL(fileURLWithPath: enabledURL.path + ".disabled")

            // the tweak was removed by other means: forget its link
            let targetURL: URL
            if fileManager.fileExists(atPath: enabledURL.path) {
                targetURL = enabledURL
            } else if fileManager.fileExists(atPath: disabledURL.path) {
                targetURL = disabledURL
            } else {
                all[index].sha256 = ""
                continue
            }

            report.checked += 1
            do {
                let data = try await download(entry.url)
                let hash = sha256(data)
                guard hash != entry.sha256 else { continue }
                try data.write(to: targetURL, options: .atomic)
                // the hash stays the one of the downloaded file, the patched copy differs on purpose
                InjectedTweaks.prepareForContainer(targetURL)
                all[index].sha256 = hash
                all[index].lastUpdate = Date()
                report.updated.append(enabledURL.lastPathComponent)
                debugLog("[TweakSources] Updated \(entry.relativePath) from \(entry.url)")
            } catch {
                report.failed[enabledURL.lastPathComponent] = error.localizedDescription
                debugLog("[TweakSources] Could not update \(entry.relativePath): \(error)")
            }
        }
        
        entries = all.filter { !$0.sha256.isEmpty }
        return report
    }
}
