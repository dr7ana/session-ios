// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

extension OpenGroupAPI {
    public enum Endpoint: EndpointType {
        // Utility
        
        case onion
        case batch
        case sequence
        case capabilities
        
        // Rooms
        
        case rooms
        case room(String)
        case roomPollInfo(String, Int64)
        
        // Messages
        
        case roomMessage(String)
        case roomMessageIndividual(String, id: UInt64)
        case roomMessagesRecent(String)
        case roomMessagesBefore(String, id: UInt64)
        case roomMessagesSince(String, seqNo: Int64)
        
        // Pinning
        
        case roomPinMessage(String, id: UInt64)
        case roomUnpinMessage(String, id: UInt64)
        case roomUnpinAll(String)
        
        // Files
        
        case roomFile(String)
        case roomFileIndividual(String, UInt64)
        
        // Inbox/Outbox (Message Requests)
        
        case inbox
        case inboxSince(id: Int64)
        case inboxFor(sessionId: String)
        
        case outbox
        case outboxSince(id: Int64)
        
        // Users
        
        case userBan(String)
        case userUnban(String)
        case userPermission(String)
        case userModerator(String)
        case userDeleteMessages(String)
        
        var path: String {
            switch self {
                // Utility
                
                case .onion: return "oxen/v4/lsrpc"
                case .batch: return "batch"
                case .sequence: return "sequence"
                case .capabilities: return "capabilities"
                    
                // Rooms
                    
                case .rooms: return "rooms"
                case .room(let roomToken): return "room/\(roomToken)"
                case .roomPollInfo(let roomToken, let infoUpdated): return "room/\(roomToken)/pollInfo/\(infoUpdated)"
                    
                // Messages
                
                case .roomMessage(let roomToken):
                    return "room/\(roomToken)/message"
                    
                case .roomMessageIndividual(let roomToken, let messageId):
                    return "room/\(roomToken)/message/\(messageId)"
                
                case .roomMessagesRecent(let roomToken):
                    return "room/\(roomToken)/messages/recent"
                    
                case .roomMessagesBefore(let roomToken, let messageId):
                    return "room/\(roomToken)/messages/before/\(messageId)"
                    
                case .roomMessagesSince(let roomToken, let seqNo):
                    return "room/\(roomToken)/messages/since/\(seqNo)"
                    
                // Pinning
                    
                case .roomPinMessage(let roomToken, let messageId):
                    return "room/\(roomToken)/pin/\(messageId)"
                    
                case .roomUnpinMessage(let roomToken, let messageId):
                    return "room/\(roomToken)/unpin/\(messageId)"
                    
                case .roomUnpinAll(let roomToken):
                    return "room/\(roomToken)/unpin/all"
                    
                // Files
                
                case .roomFile(let roomToken): return "room/\(roomToken)/file"
                case .roomFileIndividual(let roomToken, let fileId): return "room/\(roomToken)/file/\(fileId)"
                    
                // Inbox/Outbox (Message Requests)
    
                case .inbox: return "inbox"
                case .inboxSince(let id): return "inbox/since/\(id)"
                case .inboxFor(let sessionId): return "inbox/\(sessionId)"
                    
                case .outbox: return "outbox"
                case .outboxSince(let id): return "outbox/since/\(id)"
                
                // Users
                
                case .userBan(let sessionId): return "user/\(sessionId)/ban"
                case .userUnban(let sessionId): return "user/\(sessionId)/unban"
                case .userPermission(let sessionId): return "user/\(sessionId)/permission"
                case .userModerator(let sessionId): return "user/\(sessionId)/moderator"
                case .userDeleteMessages(let sessionId): return "user/\(sessionId)/deleteMessages"
            }
        }
    }
}
