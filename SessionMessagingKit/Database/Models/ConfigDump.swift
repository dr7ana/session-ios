// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

public struct ConfigDump: Codable, Equatable, Hashable, FetchableRecord, PersistableRecord, TableRecord, ColumnExpressible {
    public static var databaseTableName: String { "configDump" }
    
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case variant
        case publicKey
        case data
        case timestampMs
    }
    
    public enum Variant: String, Codable, DatabaseValueConvertible {
        case userProfile
        case contacts
        case convoInfoVolatile
        case userGroups
        
        case groupInfo
        case groupMembers
        case groupKeys
    }
    
    /// The type of config this dump is for
    public let variant: Variant
    
    /// The public key for the swarm this dump is for
    ///
    /// **Note:** For user config items this will be an empty string
    public let publicKey: String
    
    /// The data for this dump
    public let data: Data
    
    /// When the configDump was created in milliseconds since epoch
    public let timestampMs: Int64
    
    internal init(
        variant: Variant,
        publicKey: String,
        data: Data,
        timestampMs: Int64
    ) {
        self.variant = variant
        self.publicKey = publicKey
        self.data = data
        self.timestampMs = timestampMs
    }
}

// MARK: - Convenience

public extension ConfigDump.Variant {
    static let userVariants: Set<ConfigDump.Variant> = [
        .userProfile, .contacts, .convoInfoVolatile, .userGroups
    ]
    static let groupVariants: Set<ConfigDump.Variant> = [
        .groupInfo, .groupMembers, .groupKeys
    ]
    
    var configMessageKind: SharedConfigMessage.Kind {
        switch self {
            case .userProfile: return .userProfile
            case .contacts: return .contacts
            case .convoInfoVolatile: return .convoInfoVolatile
            case .userGroups: return .userGroups
                
            case .groupInfo: return .groupInfo
            case .groupMembers: return .groupMembers
            case .groupKeys: return .groupKeys
        }
    }
    
    var namespace: SnodeAPI.Namespace {
        switch self {
            case .userProfile: return SnodeAPI.Namespace.configUserProfile
            case .contacts: return SnodeAPI.Namespace.configContacts
            case .convoInfoVolatile: return SnodeAPI.Namespace.configConvoInfoVolatile
            case .userGroups: return SnodeAPI.Namespace.configUserGroups
            
            case .groupInfo: return SnodeAPI.Namespace.configGroupInfo
            case .groupMembers: return SnodeAPI.Namespace.configGroupMembers
            case .groupKeys: return SnodeAPI.Namespace.configGroupKeys
        }
    }
    
    /// This value defines the order that the ConfigDump records should be loaded in, we need to load the `groupKeys`
    /// config _after_ the `groupInfo` and `groupMembers` configs as it requires those to be passed as arguments
    var loadOrder: Int {
        switch self {
            case .groupKeys: return 1
            default: return 0
        }
    }
    
    /// This value defines the order that the SharedConfigMessages should be processed in, while we re-process config
    /// messages every time we poll this will prevent an edge-case where data/logic between different config messages
    /// could be dependant on each other (eg. there could be `convoInfoVolatile` data related to a new conversation
    /// which hasn't been created yet because it's associated `contacts`/`userGroups` message hasn't yet been
    /// processed (without this we would have to wait until the next poll for it to be processed correctly)
    var processingOrder: Int {
        switch self {
            case .userProfile, .contacts, .groupKeys: return 0
            case .userGroups, .groupInfo, .groupMembers: return 1
            case .convoInfoVolatile: return 2
        }
    }
}
