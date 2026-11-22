//
//  InjectedTweaks.swift
//  SideStore
//
//  SideStore shell: tweaks injected into sideloaded apps (the regular, signed-and-installed ones,
//  not the apps running in the LiveContainer engine, which have their own Tweaks screen).
//
//  Each app has its own folder of tweaks (.dylib, extracted from .deb when needed). Whenever the app
//  is (re)signed, the tweaks are copied into App.app/Frameworks, their CydiaSubstrate / jailbreak
//  dependencies are rewritten to resolve inside the app, and the main executable is told to load them.
//  The app is then signed as usual, tweaks included.
//  needs proper testing on device
//

import Foundation

struct InjectedTweak: Identifiable, Hashable
{
    let url: URL
    var id: String { url.path }
    var isEnabled: Bool { !url.lastPathComponent.hasSuffix(".disabled") }
    var displayName: String {
        let name = url.lastPathComponent
        return name.hasSuffix(".disabled") ? String(name.dropLast(".disabled".count)) : name
    }
}

enum InjectedTweaksError: LocalizedError
{
    case unsupportedFile(String)
    case substrateUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedFile(let name):
            return String(format: NSLocalizedString("“%@” is not a tweak: choose a .dylib or a .deb file.", comment: ""), name)
        case .substrateUnavailable:
            return NSLocalizedString("This tweak needs CydiaSubstrate, which comes with the LiveContainer engine of SideStore shell and could not be found.", comment: "")
        }
    }
}

enum InjectedTweaks
{
    private static var rootURL: URL {
        FileManager.default.applicationSupportDirectory.appendingPathComponent("InjectedTweaks", isDirectory: true)
    }

    static func folderURL(for bundleID: String) -> URL {
        rootURL.appendingPathComponent(bundleID, isDirectory: true)
    }

    static func tweaks(for bundleID: String) -> [InjectedTweak] {
        let folder = folderURL(for: bundleID)
        guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return []
        }
        return items
            .filter { $0.lastPathComponent.hasSuffix(".dylib") || $0.lastPathComponent.hasSuffix(".dylib.disabled") }
            .map(InjectedTweak.init(url:))
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    static func hasEnabledTweaks(for bundleID: String) -> Bool {
        tweaks(for: bundleID).contains { $0.isEnabled }
    }

    /// Adds a .dylib, or every tweak library found in a .deb. Returns the names added.
    @discardableResult
    static func add(from fileURL: URL, for bundleID: String) throws -> [String] {
        let fileManager = FileManager.default
        let folder = folderURL(for: bundleID)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        let name = fileURL.lastPathComponent
        let lowercased = name.lowercased()
        var written: [String] = []

        if lowercased.hasSuffix(".dylib") {
            let destination = folder.appendingPathComponent(name)
            if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
            try fileManager.copyItem(at: fileURL, to: destination)
            written.append(name)
        } else if lowercased.hasSuffix(".deb") {
            for (dylibName, data) in try DebExtractor.extractTweaks(from: fileURL) {
                try data.write(to: folder.appendingPathComponent(dylibName), options: .atomic)
                written.append(dylibName)
            }
        } else {
            throw InjectedTweaksError.unsupportedFile(name)
        }
        return written
    }

    static func setEnabled(_ enabled: Bool, _ tweak: InjectedTweak) throws {
        guard enabled != tweak.isEnabled else { return }
        let newName = enabled ? tweak.displayName : tweak.displayName + ".disabled"
        try FileManager.default.moveItem(at: tweak.url, to: tweak.url.deletingLastPathComponent().appendingPathComponent(newName))
    }

    static func delete(_ tweak: InjectedTweak) throws {
        try FileManager.default.removeItem(at: tweak.url)
    }

    // MARK: Injection

    /// CydiaSubstrate (ElleKit) shipped with the LiveContainer engine.
    static var substrateFrameworkURL: URL? {
        let candidates: [URL?] = [
            Bundle.main.bundleURL.appendingPathComponent("Frameworks/CydiaSubstrate.framework"),
            lcMainBundleURL?.appendingPathComponent("Frameworks/CydiaSubstrate.framework")
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("CydiaSubstrate").path) }
    }

    private static var lcMainBundleURL: URL? {
        let selector = NSSelectorFromString("lcMainBundle")
        guard let defaultsClass = UserDefaults.self as AnyObject as? NSObjectProtocol,
              defaultsClass.responds(to: selector),
              let bundle = defaultsClass.perform(selector)?.takeUnretainedValue() as? Bundle
        else { return nil }
        return bundle.bundleURL
    }

    static func isSubstrate(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.contains("cydiasubstrate") || lower.contains("libsubstrate") || lower.contains("ellekit")
    }

    private static func isJailbreakPath(_ path: String) -> Bool {
        path.hasPrefix("/Library/") || path.hasPrefix("/var/jb/") || path.hasPrefix("/usr/local/")
    }

    /// Points a tweak's CydiaSubstrate dependency at the one shipped with the app or LiveContainer
    /// (`@rpath/CydiaSubstrate.framework/CydiaSubstrate`, or `shortSubstratePath` when the original path is too
    /// short to hold it) and makes libraries that only exist on a jailbroken device optional.
    /// Returns true when the short path was used.
    @discardableResult
    static func fixDependencies(of tweakURL: URL, shortSubstratePath: String) throws -> Bool {
        var usedShort = false
        try MachOInjector.rewriteDependencies(of: tweakURL) { path in
            if isSubstrate(path) {
                let full = "@rpath/CydiaSubstrate.framework/CydiaSubstrate"
                if path == full { return (nil, false) }
                // a dependency path can only be replaced by one that fits in its slot
                if path.utf8.count >= full.utf8.count { return (full, false) }
                usedShort = true
                return (shortSubstratePath, false)
            }
            if isJailbreakPath(path) {
                // libraries that only exist on a jailbroken device: load the tweak without them
                return (nil, true)
            }
            return (nil, false)
        }
        return usedShort
    }
    
    /// Injects the enabled tweaks of `bundleID` into the app bundle at `appURL` (a staged copy).
    /// Returns the names injected.
    @discardableResult
    static func inject(into appURL: URL, bundleID: String) throws -> [String] {
        let tweaks = tweaks(for: bundleID).filter { $0.isEnabled }
        guard !tweaks.isEmpty else { return [] }

        let fileManager = FileManager.default
        guard let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Info.plist")),
              let executableName = info["CFBundleExecutable"] as? String
        else { throw MachOInjectorError.notMachO(appURL.lastPathComponent) }
        let executableURL = appURL.appendingPathComponent(executableName)
        try MachOInjector.ensureNotEncrypted(executableURL)

        let frameworksURL = appURL.appendingPathComponent("Frameworks", isDirectory: true)
        try fileManager.createDirectory(at: frameworksURL, withIntermediateDirectories: true)

        // Copy the tweaks and find out whether any of them needs CydiaSubstrate.
        var copied: [URL] = []
        var needsSubstrate = false
        for tweak in tweaks {
            let destination = frameworksURL.appendingPathComponent(tweak.displayName)
            if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
            try fileManager.copyItem(at: tweak.url, to: destination)
            if try MachOInjector.dependencies(of: destination).contains(where: isSubstrate) {
                needsSubstrate = true
            }
            copied.append(destination)
        }

        if needsSubstrate {
            guard let substrate = substrateFrameworkURL else { throw InjectedTweaksError.substrateUnavailable }
            let destination = frameworksURL.appendingPathComponent("CydiaSubstrate.framework")
            if !fileManager.fileExists(atPath: destination.path) {
                try fileManager.copyItem(at: substrate, to: destination)
            }
            // short alias, used when a dependency path is too short for the framework path
            let alias = frameworksURL.appendingPathComponent("libsubstrate.dylib")
            if !fileManager.fileExists(atPath: alias.path) {
                try fileManager.copyItem(at: destination.appendingPathComponent("CydiaSubstrate"), to: alias)
            }
        }

        // Make every tweak resolve its dependencies inside the app.
        for tweakURL in copied {
            try fixDependencies(of: tweakURL, shortSubstratePath: "@rpath/libsubstrate.dylib")
        }

        // Tell the app to load the tweaks.
        try MachOInjector.addRPath("@executable_path/Frameworks", to: executableURL)
        for tweakURL in copied {
            try MachOInjector.addWeakDylib("@executable_path/Frameworks/\(tweakURL.lastPathComponent)", to: executableURL)
        }

        return copied.map { $0.lastPathComponent }
    }
}
