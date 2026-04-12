// Copyright 2026 Thomas Insam. All rights reserved.

import Foundation
import CoreData

/// Ugly Core Data wrapper to make loading and using a database tolerable.
actor Database {
    private(set) var persistentContainer: NSPersistentContainer

    init() {
        // loadPersistentContainer calls the completion handler synchronously
        // by default, but I don't _completely_ trust this to hold in all cases.
        // I'm basically fine blocking app startup on this, it'll never be expensive
        // enough for it to matter.
        let semaphore = DispatchSemaphore(value: 0)
        var persistentContainer: NSPersistentContainer?
        Self.loadPersistentContainer { container in
            persistentContainer = container
            semaphore.signal()
        }
        semaphore.wait()
        self.persistentContainer = persistentContainer!
    }

    /// Creates a new background thread context, then calls the block with this context. The block
    /// will happen on a background thread, and if it makes changes to objects it is responsible
    /// for saving those changes before returning.
    func perform<Result>(block: @escaping @Sendable (NSManagedObjectContext) throws -> Result) async rethrows -> Result {
        let context = persistentContainer.newBackgroundContext()
        defer {
            // maybe too much?
            assert(!context.hasChanges)
        }
        return try await context.perform {
            try block(context)
        }
    }

    static func loadPersistentContainer(completion: @escaping (NSPersistentContainer) -> Void) {
        let persistentContainer = NSPersistentContainer(name: "PhotoSync")

        // this completion handler is called synchonously by default
        persistentContainer.loadPersistentStores(completionHandler: { _, error in
            if let error {
                NSLog("%@", "Failed to open database \(error), re-creating")
                let storeURL = persistentContainer.persistentStoreCoordinator.persistentStores.first!.url!
                try! persistentContainer.persistentStoreCoordinator.destroyPersistentStore(at: storeURL, ofType: NSSQLiteStoreType, options: nil)
                persistentContainer.loadPersistentStores { _, error in
                    if let error = error as NSError? {
                        fatalError(error.localizedDescription)
                    }
                    persistentContainer.viewContext.automaticallyMergesChangesFromParent = true
                    completion(persistentContainer)
                }
            } else {
                persistentContainer.viewContext.automaticallyMergesChangesFromParent = true
                completion(persistentContainer)
            }
        })
    }
}
