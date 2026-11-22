//
//  InjectTweaksOperation.swift
//  SideStore
//
//  SideStore shell: injects the tweaks chosen for an app into its staged copy, right before signing.
//  Does nothing when the app has no tweak. See InjectedTweaks.
//  needs proper testing on device
//

import Foundation
import SideSign

final class InjectTweaksOperation: BasePipelineOperation<InstallAppOperationContext, [String]>, @unchecked Sendable {
    
    override func execute(parentProgress: Progress?) async throws -> [String] {
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        self.setProgress(10)
        
        let bundleID = self.context.bundleIdentifier
        guard InjectedTweaks.hasEnabledTweaks(for: bundleID) else {
            self.setProgress(100)
            return []
        }
        
        guard let appBundle = self.context.targetAppBundle else {
            throw OperationError.invalidParameters("InjectTweaksOperation: context.targetAppBundle is nil")
        }
        
        // Only ever modify the staged copy, never the cached original.
        let appURL = appBundle.fileURL
        guard appURL.standardizedFileURL.path.hasPrefix(self.context.temporaryDirectory.standardizedFileURL.path) else {
            debugLog("[InjectTweaksOperation] App is not staged (\(appURL.path)); tweaks not injected")
            self.setProgress(100)
            return []
        }
        
        let injected = try InjectedTweaks.inject(into: appURL, bundleID: bundleID)
        
        // reload the bundle so later steps see the new files
        if let reloaded = ALTApplication(fileURL: appURL) {
            self.context.targetAppBundle = reloaded
        }
        debugLog("[InjectTweaksOperation] Injected into \(bundleID): \(injected)")
        self.setProgress(100)
        return injected
    }
}
