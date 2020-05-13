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
}

public protocol ManagedObject: class, NSFetchRequestResult {
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

    static func matching(_ predicate: String? = nil, args: [Any] = [], limit: Int? = nil, in context: NSManagedObjectContext) -> [Self] {
        let fetchRequest = self.fetch(with: NSPredicate(format: predicate ?? "1=1", argumentArray: args))
        if let limit = limit {
            fetchRequest.fetchLimit = limit
        }
        return try! context.fetch(fetchRequest)
    }

    static func count(_ predicate: String? = nil, args: [Any] = [], in context: NSManagedObjectContext) -> Int {
        let fetchRequest = self.fetch(with: NSPredicate(format: predicate ?? "1=1", argumentArray: args))
        return try! context.count(for: fetchRequest)
    }
}

extension NSManagedObject {
    public static var entityName: String {
        return entity().managedObjectClassName
    }
}
