//
//  ContainerInstallOperation.swift
//  SideStore
//
//  Final step of the "container" install pipeline (see ContainerBridge).
//  Instead of signing the app and sending it to the device, it packages the untouched app,
//  queues it for LiveContainer, and records it in My Apps as an inactive (container) app.
//  needs proper testing on device
//

import Foundation
import CoreData
import SideSign

final class ContainerInstallOperation: BasePipelineOperation<InstallAppOperationContext, InstalledApp>, @unchecked Sendable {
    
    private let storeAppID: NSManagedObjectID?
    
    init(context: InstallAppOperationContext, app: AppProtocol) throws {
        self.storeAppID = Self.storeAppID(for: app)
        try super.init(context: context)
    }
    
    // The source app this install comes from (nil for a plain .ipa file), read on the object's own queue.
    private static func storeAppID(for app: AppProtocol) -> NSManagedObjectID? {
        guard let object = app as? NSManagedObject, let objectContext = object.managedObjectContext else { return nil }
        
        var objectID: NSManagedObjectID?
        objectContext.performAndWait {
            if let storeApp = object as? StoreApp {
                objectID = storeApp.objectID
            } else if let appVersion = object as? AppVersion {
                objectID = appVersion.app?.objectID
            } else if let installedApp = object as? InstalledApp {
                objectID = installedApp.storeApp?.objectID
            }
        }
        return objectID
    }
    
    override func execute(parentProgress: Progress?) async throws -> InstalledApp {
        debugLog("[ContainerInstallOperation] execute() started")
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        self.setProgress(5)
        
        guard let appBundle = self.context.targetAppBundle else {
            throw OperationError.invalidParameters("ContainerInstallOperation: context.targetAppBundle is nil")
        }
        guard let appBundleFingerprint = self.context.appBundleFingerprint else {
            throw OperationError.invalidParameters("ContainerInstallOperation: context.appBundleFingerprint is nil")
        }
        
        let bundleID = self.context.bundleIdentifier
        
        // 1. Package the app as-is. LiveContainer patches and signs it itself.
        let ipaURL = try FileManager.default.zipAppBundle(at: appBundle.fileURL, compressionLevel: .none)
        self.setProgress(60)
        try ContainerBridge.queueInstall(ipaURL: ipaURL, bundleID: bundleID)
        self.setProgress(80)
        
        // 2. Record it so it shows up in My Apps and keeps receiving updates from its source.
        @Managed var appVersion = self.context.appVersion
        let storeBuildVersion = $appVersion.buildVersion
        let storeAppID = self.storeAppID
        let releaseTrackID = self.context.releaseTrack?.objectID
        
        let backgroundContext = self.context.dbBackgroundContext
        let installedApp = await backgroundContext.perform {
            let predicate = NSPredicate(format: "%K == %@", #keyPath(InstalledApp.bundleIdentifier), bundleID)
            let installedApp = InstalledApp.first(satisfying: predicate, in: backgroundContext)
                ?? InstalledApp(containerAppBundle: appBundle,
                                originalBundleIdentifier: bundleID,
                                storeBuildVersion: storeBuildVersion,
                                context: backgroundContext)
            
            installedApp.updateForContainer(appBundle: appBundle, storeBuildVersion: storeBuildVersion)
            installedApp.appBundleFingerprint = appBundleFingerprint
            
            if let storeAppID, let storeAppInContext = backgroundContext.object(with: storeAppID) as? StoreApp {
                installedApp.storeApp = storeAppInContext
                
                if let releaseTrackID {
                    installedApp.releaseTrack = backgroundContext.object(with: releaseTrackID) as? ReleaseTrack
                } else if installedApp.releaseTrack == nil {
                    installedApp.releaseTrack = storeAppInContext.latestSupportedVersion?.releaseTrack
                }
            }
            return installedApp
        }
        
        ContainerBridge.markContainerApp(bundleID)
        self.context.installedApp = installedApp
        
        self.setProgress(100)
        debugLog("[ContainerInstallOperation] queued '\(bundleID)' for LiveContainer")
        return installedApp
    }
}
