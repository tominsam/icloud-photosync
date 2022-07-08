//
//  CoreData+Extensions.swift
//  PhotoSync
//
//  Created by Thomas Insam on 4/10/20.
//  Copyright © 2020 Thomas Insam. All rights reserved.
//

import CoreData

extension NSManagedObjectContext {
    func insertObject<A: NSManagedObject>() -> A {
        return NSEntityDescription.insertNewObject(forEntityName: A.entity().managedObjectClassName, into: self) as! A
    }

    func performSave(andReset: Bool = false) async throws {
        try await self.perform {
            try self.save()
            if andReset {
                self.reset()
            }
        }
    }
}

public protocol ManagedObject: NSFetchRequestResult {
    static var entityName: String { get }
    static var defaultSortDescriptors: [NSSortDescriptor] { get }
}

extension ManagedObject {
    static func fetch(with predicate: NSPredicate? = nil) -> NSFetchRequest<Self> {
        let request = NSFetchRequest<Self>(entityName: entityName)
        request.sortDescriptors = defaultSortDescriptors
        if let predicate = predicate {
            request.predicate = predicate
        }
        request.returnsObjectsAsFaults = false
        return request
    }

    static func matching(_ predicate: String?, args: [Any] = [], limit: Int? = nil, in context: NSManagedObjectContext) async throws -> [Self] {
        let fetchRequest = fetch(with: NSPredicate(format: predicate ?? "1=1", argumentArray: args))
        if let limit = limit {
            fetchRequest.fetchLimit = limit
        }
        return try await context.perform {
            try context.fetch(fetchRequest)
        }
    }

    static func count(_ predicate: String? = nil, args: [Any] = [], in context: NSManagedObjectContext) -> Int {
        let fetchRequest = fetch(with: NSPredicate(format: predicate ?? "1=1", argumentArray: args))
        return try! context.count(for: fetchRequest)
    }
}

public extension NSManagedObject {
    static var entityName: String {
        return entity().managedObjectClassName
    }
}
