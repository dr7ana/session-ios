import SessionUtilitiesKit

// TODO:
// • Threads don't show up on the first message; only on the second.
// • Profile pictures aren't showing up.

internal enum MessageReceiver {

    internal enum Error : LocalizedError {
        case invalidMessage
        case unknownMessage
        case unknownEnvelopeType
        case noUserPublicKey
        case noData
        case senderBlocked
        // Shared sender keys
        case invalidGroupPublicKey
        case noGroupPrivateKey
        case sharedSecretGenerationFailed
        case selfSend

        internal var isRetryable: Bool {
            switch self {
            case .invalidMessage, .unknownMessage, .unknownEnvelopeType, .noData, .senderBlocked, .selfSend: return false
            default: return true
            }
        }

        internal var errorDescription: String? {
            switch self {
            case .invalidMessage: return "Invalid message."
            case .unknownMessage: return "Unknown message type."
            case .unknownEnvelopeType: return "Unknown envelope type."
            case .noUserPublicKey: return "Couldn't find user key pair."
            case .noData: return "Received an empty envelope."
            case .senderBlocked: return "Received a message from a blocked user."
            // Shared sender keys
            case .invalidGroupPublicKey: return "Invalid group public key."
            case .noGroupPrivateKey: return "Missing group private key."
            case .sharedSecretGenerationFailed: return "Couldn't generate a shared secret."
            case .selfSend: return "Message addressed at self."
            }
        }
    }

    internal static func parse(_ data: Data, using transaction: Any) throws -> Message {
        // Parse the envelope
        let envelope = try SNProtoEnvelope.parseData(data)
        // Decrypt the contents
        let plaintext: Data
        let sender: String
        switch envelope.type {
        case .unidentifiedSender: (plaintext, sender) = try decryptWithSignalProtocol(envelope: envelope, using: transaction)
        case .closedGroupCiphertext: (plaintext, sender) = try decryptWithSharedSenderKeys(envelope: envelope, using: transaction)
        default: throw Error.unknownEnvelopeType
        }
        // Don't process the envelope any further if the sender is blocked
        guard !Configuration.shared.storage.isBlocked(sender) else { throw Error.senderBlocked }
        // Parse the proto
        let proto: SNProtoContent
        do {
            proto = try SNProtoContent.parseData((plaintext as NSData).removePadding())
        } catch {
            SNLog("Couldn't parse proto due to error: \(error).")
            throw error
        }
        // Parse the message
        let message: Message? = {
            if let readReceipt = ReadReceipt.fromProto(proto) { return readReceipt }
            if let sessionRequest = SessionRequest.fromProto(proto) { return sessionRequest }
            if let nullMessage = NullMessage.fromProto(proto) { return nullMessage }
            if let typingIndicator = TypingIndicator.fromProto(proto) { return typingIndicator }
            if let closedGroupUpdate = ClosedGroupUpdate.fromProto(proto) { return closedGroupUpdate }
            if let expirationTimerUpdate = ExpirationTimerUpdate.fromProto(proto) { return expirationTimerUpdate }
            if let visibleMessage = VisibleMessage.fromProto(proto) { return visibleMessage }
            return nil
        }()
        if let message = message {
            message.sender = sender
            message.recipient = Configuration.shared.storage.getUserPublicKey()
            message.receivedTimestamp = NSDate.millisecondTimestamp()
            guard message.isValid else { throw Error.invalidMessage }
            return message
        } else {
            throw Error.unknownMessage
        }
    }

    internal static func handle(_ message: Message, messageServerID: UInt64?, using transaction: Any) {
        switch message {
        case let message as ReadReceipt: handleReadReceipt(message, using: transaction)
        case let message as SessionRequest: handleSessionRequest(message, using: transaction)
        case let message as NullMessage: handleNullMessage(message, using: transaction)
        case let message as TypingIndicator: handleTypingIndicator(message, using: transaction)
        case let message as ClosedGroupUpdate: handleClosedGroupUpdate(message, using: transaction)
        case let message as ExpirationTimerUpdate: handleExpirationTimerUpdate(message, using: transaction)
        case let message as VisibleMessage: handleVisibleMessage(message, using: transaction)
        default: fatalError()
        }
    }

    private static func handleReadReceipt(_ message: ReadReceipt, using transaction: Any) {
        Configuration.shared.storage.markMessagesAsRead(message.timestamps!, from: message.sender!, at: message.receivedTimestamp!)
    }

    private static func handleSessionRequest(_ message: SessionRequest, using transaction: Any) {
        // TODO: Implement
    }

    private static func handleNullMessage(_ message: NullMessage, using transaction: Any) {
        // TODO: Implement
    }

    private static func handleTypingIndicator(_ message: TypingIndicator, using transaction: Any) {
        let storage = Configuration.shared.storage
        switch message.kind! {
        case .started: storage.showTypingIndicatorIfNeeded(for: message.sender!)
        case .stopped: storage.hideTypingIndicatorIfNeeded(for: message.sender!)
        }
    }

    private static func handleClosedGroupUpdate(_ message: ClosedGroupUpdate, using transaction: Any) {

    }

    private static func handleExpirationTimerUpdate(_ message: ExpirationTimerUpdate, using transaction: Any) {
        let storage = Configuration.shared.storage
        if message.duration! > 0 {
            storage.setExpirationTimer(to: message.duration!, for: message.sender!, using: transaction)
        } else {
            storage.disableExpirationTimer(for: message.sender!, using: transaction)
        }
    }

    private static func handleVisibleMessage(_ message: VisibleMessage, using transaction: Any) {
        let storage = Configuration.shared.storage
        // Update profile if needed
        if let profile = message.profile {
            storage.updateProfile(for: message.sender!, from: profile, using: transaction)
        }
        // Persist the message
        let (threadID, tsIncomingMessage) = storage.persist(message, using: transaction)
        message.threadID = threadID
        // Cancel any typing indicators
        storage.cancelTypingIndicatorsIfNeeded(for: message.sender!)
        // Notify the user if needed
        storage.notifyUserIfNeeded(for: tsIncomingMessage, threadID: threadID)
    }
}
