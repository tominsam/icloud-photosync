//  Copyright 2022 Thomas Insam. All rights reserved.

import CoreData
import Foundation
import SwiftyDropbox

@objc(SyncToken)
public class SyncToken: NSManagedObject, ManagedObject {

    public enum SyncTokenType: String, RawRepresentable {
        case dropboxAuth
        case dropboxListFolder
        case photoKit

        var version: Int {
            switch self {
            case .dropboxAuth:
                return 1
            case .dropboxListFolder:
                return 2
            case .photoKit:
                return 1
            }
        }
    }

    public static var defaultSortDescriptors: [NSSortDescriptor] {
        return [NSSortDescriptor(key: "type", ascending: true)]
    }

    @NSManaged public var type: String!
    @NSManaged public var value: Data!
}

public extension SyncToken {
    static func insertOrUpdate(type: SyncTokenType, value: NSSecureCoding, into context: NSManagedObjectContext) async throws {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.encode(value, forKey: "data")
        archiver.encode(type.version, forKey: "version")
        try await insertOrUpdate(type: type, value: archiver.encodedData, into: context)
        try await context.performSave()
    }

    @discardableResult
    private static func insertOrUpdate(type: SyncTokenType, value: Data, into context: NSManagedObjectContext) async throws -> SyncToken {
        let existing = try await SyncToken.matching("type == %@", args: [type.rawValue], in: context).first
        if let existing = existing {
            existing.value = value
            return existing
        } else {
            let created: SyncToken = await context.perform { context.insertObject() }
            created.type = type.rawValue
            created.value = value
            return created
        }
    }

    static func dataFor<T: NSObject & NSSecureCoding>(type: SyncTokenType, in context: NSManagedObjectContext) async throws -> T? {
        let data = try await SyncToken.matching("type == %@", args: [type.rawValue], in: context).first?.value
        guard let data = data else {
            return nil
        }
        let dearchiver = try NSKeyedUnarchiver(forReadingFrom: data)
        let version = dearchiver.decodeInteger(forKey: "version")
        guard version == type.version else {
            NSLog("%@", "Invalidating token of type \(type) because the version changed")
            return nil
        }
        return dearchiver.decodeObject(of: T.self, forKey: "data")
    }

}
