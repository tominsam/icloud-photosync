// Copyright 2020 Thomas Insam. All rights reserved.

@preconcurrency import CoreData

extension NSManagedObjectContext {
    func insertObject<A: NSManagedObject>() -> A {
        return NSEntityDescription.insertNewObject(forEntityName: A.entity().managedObjectClassName, into: self) as! A
    }

    // If a core data context gets too large, it gets slow. This will save and
    // flush - useful if you're inserting a ton of objects that you're not going
    // to fetch again.
    func save(andReset: Bool) throws {
        try self.save()
        if andReset {
            self.reset()
        }
    }
}

// Local protocol for my managed objects
public protocol ManagedObject: NSFetchRequestResult {
    static var entityName: String { get }
    static var defaultSortDescriptors: [NSSortDescriptor] { get }
}

extension ManagedObject {
    /// Create a fetch request for a specific predicate, using the default sort ordering of the object
    static func fetch(with predicate: NSPredicate? = nil) -> NSFetchRequest<Self> {
        let request = NSFetchRequest<Self>(entityName: entityName)
        request.sortDescriptors = defaultSortDescriptors
        if let predicate = predicate {
            request.predicate = predicate
        }
        request.returnsObjectsAsFaults = false
        return request
    }

    /// Fetches objects from a context based on a simple query. eg `Foo.matching("id == %@", "id")`
    /// Returned sort order matches default ordering of object. Must be run on the context thread!
    static func matching(_ predicate: String?, args: [Any] = [], limit: Int? = nil, in context: NSManagedObjectContext) throws -> [Self] {
        let fetchRequest = fetch(with: NSPredicate(format: predicate ?? "1=1", argumentArray: args))
        if let limit = limit {
            fetchRequest.fetchLimit = limit
        }
        return try context.fetch(fetchRequest)
    }

    /// Count objects matching a query.
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
