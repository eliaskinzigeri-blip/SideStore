//
//  UpdateFlagSync.swift
//  SideStore
//
//  SideStore shell: keeps the "Updates" section of My Apps filled.
//
//  My Apps lists updates with a database query on InstalledApp.hasUpdate, but the stored column was
//  never written (the Swift property of the same name is computed from the source's latest version),
//  so the query found nothing and updates only showed on each app's page in its source.
//  This writes the computed value into the stored column whenever the database changes.
//  needs proper testing on device
//

import Foundation
import CoreData

enum UpdateFlagSync
{
    private static let queue = DispatchQueue(label: "io.sidestore.shell.update-flag-sync")
    private static var isScheduled = false
    private static var observer: NSObjectProtocol?

    /// Starts watching the database, and syncs once right away.
    static func start()
    {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .NSManagedObjectContextDidSave, object: nil, queue: nil) { notification in
            guard let context = notification.object as? NSManagedObjectContext,
                  context.persistentStoreCoordinator === DatabaseManager.shared.persistentContainer.persistentStoreCoordinator
            else { return }
            scheduleSync()
        }
        scheduleSync()
    }

    static func scheduleSync()
    {
        queue.async {
            guard !isScheduled else { return }
            isScheduled = true
            // gather the saves of one burst (e.g. a source refresh) into a single pass
            queue.asyncAfter(deadline: .now() + 0.8) {
                isScheduled = false
                sync()
            }
        }
    }

    private static func sync()
    {
        guard DatabaseManager.shared.isStarted else { return }
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        context.performAndWait {
            let fetchRequest = InstalledApp.fetchRequest() as NSFetchRequest<InstalledApp>
            fetchRequest.relationshipKeyPathsForPrefetching = [#keyPath(InstalledApp.storeApp)]
            guard let apps = try? context.fetch(fetchRequest) else { return }

            for app in apps {
                let current = app.hasUpdate
                let stored = (app.primitiveValue(forKey: "hasUpdate") as? Bool) ?? false
                guard current != stored else { continue }
                app.willChangeValue(forKey: "hasUpdate")
                app.setPrimitiveValue(current, forKey: "hasUpdate")
                app.didChangeValue(forKey: "hasUpdate")
            }

            guard context.hasChanges else { return }
            do {
                try context.save()
                debugLog("[UpdateFlagSync] Updates list refreshed")
            } catch {
                debugLog("[UpdateFlagSync] Could not save update flags: \(error)")
            }
        }
    }
}
