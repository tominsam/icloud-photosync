// Copyright 2026 Thomas Insam. All rights reserved.

import Foundation
import CoreData

actor Database {
    private(set) var persistentContainer: NSPersistentContainer

    init() {
        var persistentContainer: NSPersistentContainer?
        Self.loadPersistentContainer { container in
            persistentContainer = container
        }
        self.persistentContainer = persistentContainer!
    }
    
    func perform<Result>(block: @escaping @Sendable (NSManagedObjectContext) throws -> Result) async rethrows -> Result {
        let context = persistentContainer.newBackgroundContext()
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
