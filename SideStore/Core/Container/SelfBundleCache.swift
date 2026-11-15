//
//  SelfBundleCache.swift
//  SideStore
//
//  SideStore shell: SideStore keeps a pristine copy of the running app so it can refresh or
//  re-sign itself. When that copy is missing, those operations fail with "targetAppBundle is nil".
//  This rebuilds the copy on demand from the running app, and reports the real reason if it cannot.
//  needs proper testing on device
//

import Foundation
import SideSign

enum SelfBundleCache
{
    /// Copies the running app, restores its original bundle identifiers and stores it in the app cache.
    static func rebuild() throws -> (signature: String, appBundle: ALTApplication)
    {
        let fileManager = FileManager.default
        let bundleURL = Bundle.Info.activeBundleURL
        
        let temporaryDirectory = fileManager.uniqueTemporaryURL()
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true, attributes: nil)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }
        
        let temporaryAppURL = temporaryDirectory.appendingPathComponent("App.app")
        try fileManager.copyItem(at: bundleURL, to: temporaryAppURL)
        
        guard let temporaryApp = ALTApplication(fileURL: temporaryAppURL) else {
            throw OperationError.invalidApp(reason: "Could not read a copy of the running app (\(bundleURL.lastPathComponent)).")
        }
        
        let resignedBundleID = temporaryApp.bundleIdentifier
        let originalBundleID = StoreApp.altstoreAppID
        
        try temporaryApp.updateInfoPlist(with: [kCFBundleIdentifierKey as String: originalBundleID])
        for appExtension in temporaryApp.appExtensions {
            let originalExtensionID = appExtension.bundleIdentifier.replacingOccurrences(of: resignedBundleID, with: originalBundleID)
            try appExtension.updateInfoPlist(with: [kCFBundleIdentifierKey as String: originalExtensionID])
        }
        
        let (signature, cachedURL) = try CacheAppOperation.cachePayload(for: temporaryAppURL)
        guard let cachedApp = ALTApplication(fileURL: cachedURL) else {
            throw OperationError.invalidApp(reason: "The cached copy of the running app could not be read back.")
        }
        
        debugLog("[SelfBundleCache] Rebuilt cached copy of the running app (signature \(signature))")
        return (signature, cachedApp)
    }
}
