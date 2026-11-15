//
//  ContainerBridge.swift
//  SideStore
//
//  Bridge between SideStore and the LiveContainer engine it runs inside ("SideStore shell").
//
//  When every sideloading slot of a free Apple ID is taken, new apps are not refused any more:
//  they are handed to LiveContainer, which runs them from inside this app without installing
//  them on the device. Those apps are kept in My Apps as inactive records flagged here.
//
//  Everything in this file is a no-op when SideStore runs as a normal standalone app.
//  needs proper testing on device
//

import Foundation
import UIKit
import CoreData
import ObjectiveC
import SideSign

enum ContainerBridge
{
    private static let containerAppsKey = "SCContainerApps"
    private static let queuedInstallsKey = "SCQueuedContainerInstalls"
    private static let pendingDeepLinkKey = "SCPendingDeepLink"

    // MARK: - Environment

    /// Home directory of the LiveContainer host app (SideStore's own home is a sub-folder of it).
    static var hostHomeURL: URL? {
        guard let path = getenv("LC_HOME_PATH") else { return nil }
        let string = String(cString: path)
        guard !string.isEmpty else { return nil }
        return URL(fileURLWithPath: string, isDirectory: true)
    }

    private static var sharedUtilsClass: AnyClass? {
        return NSClassFromString("LCSharedUtils")
    }

    /// True when SideStore is running inside the LiveContainer shell.
    static var isAvailable: Bool {
        return hostHomeURL != nil && sharedUtilsClass != nil && hostDefaults != nil
    }

    /// LiveContainer's own preferences (not SideStore's, which live in the guest home).
    private static var hostDefaults: UserDefaults? {
        // +[NSUserDefaults lcUserDefaults] is added by LiveContainer; it does not exist in a standalone SideStore.
        let selector = NSSelectorFromString("lcUserDefaults")
        guard let defaultsClass = UserDefaults.self as AnyObject as? NSObjectProtocol,
              defaultsClass.responds(to: selector)
        else { return nil }
        return defaultsClass.perform(selector)?.takeUnretainedValue() as? UserDefaults
    }

    private static var applicationsURL: URL? {
        return hostHomeURL?.appendingPathComponent("Documents/Applications", isDirectory: true)
    }

    private static var pendingDirectoryURL: URL? {
        return hostHomeURL?.appendingPathComponent("Documents/SCPending", isDirectory: true)
    }

    // MARK: - Container apps registry

    static var containerBundleIDs: Set<String> {
        return Set(UserDefaults.standard.stringArray(forKey: containerAppsKey) ?? [])
    }

    static func isContainerApp(_ bundleID: String) -> Bool {
        return containerBundleIDs.contains(bundleID)
    }

    static func markContainerApp(_ bundleID: String) {
        var bundleIDs = containerBundleIDs
        bundleIDs.insert(bundleID)
        UserDefaults.standard.set(Array(bundleIDs).sorted(), forKey: containerAppsKey)
    }

    static func unmarkContainerApp(_ bundleID: String) {
        var bundleIDs = containerBundleIDs
        bundleIDs.remove(bundleID)
        UserDefaults.standard.set(Array(bundleIDs).sorted(), forKey: containerAppsKey)
    }

    /// Name of the app's folder inside LiveContainer (e.g. "com.example.app.app"), if it is installed there.
    static func installedFolderName(for bundleID: String) -> String? {
        guard let applicationsURL,
              let folders = try? FileManager.default.contentsOfDirectory(at: applicationsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return nil }

        for folder in folders where folder.pathExtension == "app" {
            let infoURL = folder.appendingPathComponent("Info.plist")
            guard let info = NSDictionary(contentsOf: infoURL),
                  let identifier = info["CFBundleIdentifier"] as? String,
                  identifier == bundleID
            else { continue }
            return folder.lastPathComponent
        }
        return nil
    }

    // MARK: - Routing

    /// Decides whether an install/update goes to the container instead of being sideloaded.
    /// - Apps already living in the container stay there (this is how source updates reach them).
    /// - Brand new apps go there only when no sideloading slot is left.
    static func shouldRoute(_ operation: AppOperation) -> Bool {
        guard isAvailable else { return false }

        switch operation {
        case .install, .update, .reinstall: break
        default: return false
        }

        let bundleID = operation.bundleIdentifier
        guard !bundleID.isAltStoreAppID else { return false }

        if isContainerApp(bundleID) { return true }
        if UserDefaults.standard.bool(forKey: "SCDisableContainerFallback") { return false }

        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        var route = false
        context.performAndWait {
            let predicate = NSPredicate(format: "%K == %@", #keyPath(InstalledApp.bundleIdentifier), bundleID)
            if InstalledApp.first(satisfying: predicate, in: context) != nil {
                // Already managed the regular way (active, or deactivated with a backup): keep it that way.
                route = false
                return
            }
            route = !hasFreeSideloadingSlot(in: context)
        }
        return route
    }

    /// True when the operation never talks to the device (container installs, removal of container apps).
    static func skipsDevice(_ operation: AppOperation) -> Bool {
        guard isAvailable else { return false }
        switch operation {
        case .removeApp, .removeDeactivatedApp:
            return isContainerApp(operation.bundleIdentifier)
        default:
            return shouldRoute(operation)
        }
    }
    
    private static func hasFreeSideloadingSlot(in context: NSManagedObjectContext) -> Bool {
        guard !UserDefaults.standard.isAppLimitDisabled,
              let limit = UserDefaults.standard.activeAppsLimit
        else { return true }

        let activeApps = InstalledApp.fetchActiveApps(in: context)
            .filter { ($0.team?.type ?? .unknown) == .free }
        let usedSlots = activeApps.map(\.requiredActiveSlots).reduce(0, +)
        return usedSlots < limit
    }

    // MARK: - Direct install (no hand-off, SideStore stays open)
    
    /// Copies an app bundle straight into LiveContainer's Applications folder, without leaving SideStore.
    /// LiveContainer patches and signs it the first time it is launched. On an update, the app's
    /// LiveContainer settings (data container, tweaks folder, options) are kept.
    static func installDirectly(appBundleURL: URL, bundleID: String) throws {
        guard let applicationsURL else {
            throw OperationError.invalidParameters("ContainerBridge: LiveContainer is not available")
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: applicationsURL, withIntermediateDirectories: true, attributes: nil)
        
        let existingFolder = installedFolderName(for: bundleID)
        var folderName = existingFolder ?? "\(bundleID).app"
        if existingFolder == nil, fileManager.fileExists(atPath: applicationsURL.appendingPathComponent(folderName).path) {
            folderName = "\(bundleID)_\(Int(Date().timeIntervalSince1970)).app"
        }
        let destinationURL = applicationsURL.appendingPathComponent(folderName, isDirectory: true)
        
        // Settings to carry over (they live inside the app folder, which is replaced).
        let appInfo: NSMutableDictionary
        if existingFolder != nil,
           let previous = NSMutableDictionary(contentsOf: destinationURL.appendingPathComponent("LCAppInfo.plist")) {
            appInfo = previous
            // the new binary has to be patched again
            appInfo.removeObject(forKey: "LCPatchRevision")
        } else {
            // LiveContainer applies its usual defaults for a new app on first launch
            appInfo = ["SCDirectInstall": true]
        }
        
        // Copy next to the destination first (name without ".app", so LiveContainer never lists it), then swap.
        let stagingURL = applicationsURL.appendingPathComponent(".sc-staging-\(UUID().uuidString)", isDirectory: true)
        try fileManager.copyItem(at: appBundleURL, to: stagingURL)
        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }
        
        guard appInfo.write(to: destinationURL.appendingPathComponent("LCAppInfo.plist"), atomically: true) else {
            throw OperationError.invalidParameters("ContainerBridge: could not write LCAppInfo.plist")
        }
        markContainerApp(bundleID)
    }
    
    /// Configuration profile that adds a Home Screen icon opening the app in LiveContainer
    /// (same profile LiveContainer itself generates).
    static func homeScreenProfile(for bundleID: String, name: String) -> Data? {
        guard let applicationsURL, let folderName = installedFolderName(for: bundleID) else { return nil }
        
        var icon: UIImage?
        if let app = ALTApplication(fileURL: applicationsURL.appendingPathComponent(folderName)) {
            icon = app.icon
        }
        guard let iconData = (icon ?? UIImage(systemName: "app.fill"))?.pngData() else { return nil }
        
        var components = URLComponents()
        components.scheme = "livecontainer"
        components.host = "livecontainer-launch"
        components.queryItems = [URLQueryItem(name: "bundle-name", value: folderName)]
        guard let launchURL = components.url?.absoluteString else { return nil }
        
        let description = "Opens \(name) in SideStore"
        let payload: [String: Any] = [
            "FullScreen": true,
            "Icon": iconData,
            "IgnoreManifestScope": true,
            "IsRemovable": true,
            "Label": name,
            "PayloadDescription": description,
            "PayloadDisplayName": name,
            "PayloadIdentifier": "\(bundleID).webclip",
            "PayloadType": "com.apple.webClip.managed",
            "PayloadUUID": UUID().uuidString,
            "PayloadVersion": 1,
            "Precomposed": true,
            "URL": launchURL
        ]
        let profile: [String: Any] = [
            "PayloadContent": [payload],
            "PayloadDescription": description,
            "PayloadDisplayName": name,
            "PayloadIdentifier": "\(bundleID).webclip.profile",
            "PayloadOrganization": "SideStore",
            "PayloadRemovalDisallowed": false,
            "PayloadType": "Configuration",
            "PayloadUUID": UUID().uuidString,
            "PayloadVersion": 1
        ]
        return try? PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
    }
    
    // MARK: - Hand-off to LiveContainer

    /// Copies a packaged app next to LiveContainer and queues its installation there.
    static func queueInstall(ipaURL: URL, bundleID: String) throws {
        guard let pendingDirectoryURL else {
            throw OperationError.invalidParameters("ContainerBridge: LiveContainer is not available")
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: pendingDirectoryURL, withIntermediateDirectories: true, attributes: nil)

        let safeName = bundleID.replacingOccurrences(of: "/", with: "_")
        let destinationURL = pendingDirectoryURL.appendingPathComponent("\(safeName).ipa")
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: ipaURL, to: destinationURL)

        var queue = UserDefaults.standard.stringArray(forKey: queuedInstallsKey) ?? []
        queue.removeAll { $0 == destinationURL.path }
        queue.append(destinationURL.path)
        UserDefaults.standard.set(queue, forKey: queuedInstallsKey)
    }

    static var hasQueuedInstalls: Bool {
        return !(UserDefaults.standard.stringArray(forKey: queuedInstallsKey) ?? []).isEmpty
    }

    /// Sends the next queued app to LiveContainer. The app restarts into LiveContainer, installs it,
    /// then comes back to SideStore, where this is called again until the queue is empty.
    @MainActor
    static func performNextQueuedInstall() {
        guard isAvailable else { return }

        var queue = UserDefaults.standard.stringArray(forKey: queuedInstallsKey) ?? []
        while !queue.isEmpty {
            // Each file is attempted once: it leaves the queue before the hand-off, so a failed
            // install can never make the app bounce back and forth forever.
            let path = queue.removeFirst()
            UserDefaults.standard.set(queue, forKey: queuedInstallsKey)

            guard FileManager.default.fileExists(atPath: path) else { continue }

            var components = URLComponents()
            components.scheme = "livecontainer"
            components.host = "install"
            components.queryItems = [
                URLQueryItem(name: "url", value: URL(fileURLWithPath: path).absoluteString),
                URLQueryItem(name: "sc-return", value: "1")
            ]
            guard let deepLink = components.url else { continue }

            UserDefaults.standard.synchronize()
            restartIntoHost(deepLink: deepLink)
            return
        }
    }

    @MainActor
    static func open(_ installedApp: InstalledApp) -> Bool {
        guard let folderName = installedFolderName(for: installedApp.bundleIdentifier) else { return false }
        return restartIntoHost(host: "livecontainer-launch", folderName: folderName)
    }

    @MainActor
    static func addToHomeScreen(_ installedApp: InstalledApp) -> Bool {
        guard let folderName = installedFolderName(for: installedApp.bundleIdentifier) else { return false }
        return restartIntoHost(host: "sc-webclip", folderName: folderName)
    }

    /// Deletes the app (not its record) from LiveContainer, together with its data folders.
    static func removeFromContainer(bundleID: String) {
        defer { unmarkContainerApp(bundleID) }

        guard let applicationsURL, let hostHomeURL,
              let folderName = installedFolderName(for: bundleID)
        else { return }

        let fileManager = FileManager.default
        let appURL = applicationsURL.appendingPathComponent(folderName, isDirectory: true)

        if let info = NSDictionary(contentsOf: appURL.appendingPathComponent("LCAppInfo.plist")),
           let containers = info["LCContainers"] as? [[String: Any]]
        {
            let dataURL = hostHomeURL.appendingPathComponent("Documents/Data/Application", isDirectory: true)
            for container in containers {
                guard let name = container["folderName"] as? String, !name.isEmpty else { continue }
                try? fileManager.removeItem(at: dataURL.appendingPathComponent(name, isDirectory: true))
            }
        }

        try? fileManager.removeItem(at: appURL)
    }

    @MainActor
    @discardableResult
    private static func restartIntoHost(host: String, folderName: String) -> Bool {
        var components = URLComponents()
        components.scheme = "livecontainer"
        components.host = host
        components.queryItems = [URLQueryItem(name: "bundle-name", value: folderName)]
        guard let deepLink = components.url else { return false }
        return restartIntoHost(deepLink: deepLink)
    }

    /// Leaves SideStore and restarts the app in LiveContainer's own interface, which picks up `deepLink`.
    @MainActor
    @discardableResult
    private static func restartIntoHost(deepLink: URL) -> Bool {
        guard let hostDefaults, let sharedUtilsClass else { return false }

        let selector = NSSelectorFromString("launchToGuestAppWithClassicMode:")
        guard let method = class_getClassMethod(sharedUtilsClass, selector) else { return false }

        hostDefaults.set(deepLink.absoluteString, forKey: pendingDeepLinkKey)
        hostDefaults.synchronize()

        typealias LaunchFunction = @convention(c) (AnyClass, Selector, UInt) -> Bool
        let launch = unsafeBitCast(method_getImplementation(method), to: LaunchFunction.self)
        return launch(sharedUtilsClass, selector, 0)
    }
}
