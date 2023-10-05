// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit

/// This migration goes through the current state of the database and generates config dumps for the user config types
enum _014_GenerateInitialUserConfigDumps: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "GenerateInitialUserConfigDumps" // stringlint:disable
    static let needsConfigSync: Bool = true
    static let minExpectedRunDuration: TimeInterval = 4.0
    static let fetchedTables: [(TableRecord & FetchableRecord).Type] = [
        Identity.self, SessionThread.self, Contact.self, Profile.self, ClosedGroup.self,
        OpenGroup.self, DisappearingMessagesConfiguration.self, GroupMember.self, ConfigDump.self
    ]
    static let createdOrAlteredTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: Database, using dependencies: Dependencies) throws {
        // If we have no ed25519 key then there is no need to create cached dump data
        guard Identity.fetchUserEd25519KeyPair(db) != nil else {
            Storage.update(progress: 1, for: self, in: target, using: dependencies)
            return
        }
        
        // Create the initial config state
        let userSessionId: SessionId = getUserSessionId(db, using: dependencies)
        let timestampMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
        
        SessionUtil.loadState(db, using: dependencies)
        
        // Retrieve all threads (we are going to base the config dump data on the active
        // threads rather than anything else in the database)
        let allThreads: [String: SessionThread] = try SessionThread
            .fetchAll(db)
            .reduce(into: [:]) { result, next in result[next.id] = next }
        
        // MARK: - UserProfile Config Dump
        
        try dependencies[cache: .sessionUtil]
            .config(for: .userProfile, sessionId: userSessionId)
            .mutate { config in
                try SessionUtil.update(
                    profile: Profile.fetchOrCreateCurrentUser(db),
                    in: config
                )
                
                try SessionUtil.updateNoteToSelf(
                    priority: {
                        guard allThreads[userSessionId.hexString]?.shouldBeVisible == true else { return SessionUtil.hiddenPriority }
                        
                        return Int32(allThreads[userSessionId.hexString]?.pinnedPriority ?? 0)
                    }(),
                    in: config
                )
                
                if config.needsDump {
                    try SessionUtil
                        .createDump(
                            config: config,
                            for: .userProfile,
                            sessionId: userSessionId,
                            timestampMs: timestampMs
                        )?
                        .save(db)
                }
            }
        
        // MARK: - Contact Config Dump
        
        try dependencies[cache: .sessionUtil]
            .config(for: .contacts, sessionId: userSessionId)
            .mutate { config in
                // Exclude Note to Self, community, group and outgoing blinded message requests
                let validContactIds: [String] = allThreads
                    .values
                    .filter { thread in
                        thread.variant == .contact &&
                        thread.id != userSessionId.hexString &&
                        (try? SessionId(from: thread.id))?.prefix == .standard
                    }
                    .map { $0.id }
                let contactsData: [ContactInfo] = try Contact
                    .filter(
                        Contact.Columns.isBlocked == true ||
                        validContactIds.contains(Contact.Columns.id)
                    )
                    .including(optional: Contact.profile)
                    .asRequest(of: ContactInfo.self)
                    .fetchAll(db)
                let threadIdsNeedingContacts: [String] = validContactIds
                    .filter { contactId in !contactsData.contains(where: { $0.contact.id == contactId }) }
                
                try SessionUtil.upsert(
                    contactData: contactsData
                        .appending(
                            contentsOf: threadIdsNeedingContacts
                                .map { contactId in
                                    ContactInfo(
                                        contact: Contact.fetchOrCreate(db, id: contactId),
                                        profile: nil
                                    )
                                }
                        )
                        .map { data in
                            SessionUtil.SyncedContactInfo(
                                id: data.contact.id,
                                contact: data.contact,
                                profile: data.profile,
                                priority: {
                                    guard allThreads[data.contact.id]?.shouldBeVisible == true else {
                                        return SessionUtil.hiddenPriority
                                    }
                                    
                                    return Int32(allThreads[data.contact.id]?.pinnedPriority ?? 0)
                                }(),
                                created: allThreads[data.contact.id]?.creationDateTimestamp
                            )
                        },
                    in: config
                )
                
                if config.needsDump {
                    try SessionUtil
                        .createDump(
                            config: config,
                            for: .contacts,
                            sessionId: userSessionId,
                            timestampMs: timestampMs
                        )?
                        .save(db)
                }
            }
        
        // MARK: - ConvoInfoVolatile Config Dump
        
        try dependencies[cache: .sessionUtil]
            .config(for: .convoInfoVolatile, sessionId: userSessionId)
            .mutate { config in
                let volatileThreadInfo: [SessionUtil.VolatileThreadInfo] = SessionUtil.VolatileThreadInfo
                    .fetchAll(db, ids: Array(allThreads.keys))
                
                try SessionUtil.upsert(
                    convoInfoVolatileChanges: volatileThreadInfo,
                    in: config
                )
                
                if config.needsDump {
                    try SessionUtil
                        .createDump(
                            config: config,
                            for: .convoInfoVolatile,
                            sessionId: userSessionId,
                            timestampMs: timestampMs
                        )?
                        .save(db)
                }
            }
        
        // MARK: - UserGroups Config Dump
        
        try dependencies[cache: .sessionUtil]
            .config(for: .userGroups, sessionId: userSessionId)
            .mutate { config in
                let legacyGroupData: [SessionUtil.LegacyGroupInfo] = try SessionUtil.LegacyGroupInfo.fetchAll(db)
                let communityData: [SessionUtil.OpenGroupUrlInfo] = try SessionUtil.OpenGroupUrlInfo
                    .fetchAll(db, ids: Array(allThreads.keys))
                
                try SessionUtil.upsert(
                    legacyGroups: legacyGroupData,
                    in: config
                )
                try SessionUtil.upsert(
                    communities: communityData
                        .map { urlInfo in
                            SessionUtil.CommunityInfo(
                                urlInfo: urlInfo,
                                priority: Int32(allThreads[urlInfo.threadId]?.pinnedPriority ?? 0)
                            )
                        },
                    in: config
                )
                
                if config.needsDump {
                    try SessionUtil
                        .createDump(
                            config: config,
                            for: .userGroups,
                            sessionId: userSessionId,
                            timestampMs: timestampMs
                        )?
                        .save(db)
                }
        }
                
        // MARK: - Threads
        
        try SessionUtil.updatingThreads(db, Array(allThreads.values), using: dependencies)
        
        // MARK: - Syncing
        
        // Enqueue a config sync job to ensure the generated configs get synced
        db.afterNextTransactionNestedOnce(dedupeId: SessionUtil.syncDedupeId(userSessionId.hexString)) { db in
            ConfigurationSyncJob.enqueue(db, sessionIdHexString: userSessionId.hexString)
        }
        
        Storage.update(progress: 1, for: self, in: target, using: dependencies)
    }
    
    struct ContactInfo: FetchableRecord, Decodable, ColumnExpressible {
        typealias Columns = CodingKeys
        enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
            case contact
            case profile
        }
        
        let contact: Contact
        let profile: Profile?
    }

    struct GroupInfo: FetchableRecord, Decodable, ColumnExpressible {
        typealias Columns = CodingKeys
        enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
            case closedGroup
            case disappearingMessagesConfiguration
            case groupMembers
        }
        
        let closedGroup: ClosedGroup
        let disappearingMessagesConfiguration: DisappearingMessagesConfiguration?
        let groupMembers: [GroupMember]
    }
}
