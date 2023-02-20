// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Sodium
import SessionUtilitiesKit

public class UpdateExpiryResponse: SnodeRecursiveResponse<UpdateExpiryResponse.SwarmItem> {}

// MARK: - SwarmItem

public extension UpdateExpiryResponse {
    class SwarmItem: SnodeSwarmItem {
        private enum CodingKeys: String, CodingKey {
            case updated
            case expiry
        }
        
        public let updated: [String]
        public let expiry: UInt64?
        
        // MARK: - Initialization
        
        required init(from decoder: Decoder) throws {
            let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
            
            updated = ((try? container.decode([String].self, forKey: .updated)) ?? [])
            expiry = try? container.decode(UInt64.self, forKey: .expiry)
            
            try super.init(from: decoder)
        }
    }
}

// MARK: - ValidatableResponse

extension UpdateExpiryResponse: ValidatableResponse {
    typealias ValidationData = [String]
    typealias ValidationResponse = (hashes: [String], expiry: UInt64)
    
    /// All responses in the swarm must be valid
    internal static var requiredSuccessfulResponses: Int { -1 }
    
    internal func validResultMap(
        sodium: Sodium,
        userX25519PublicKey: String,
        validationData: [String]
    ) throws -> [String: (hashes: [String], expiry: UInt64)] {
        let validationMap: [String: (hashes: [String], expiry: UInt64)] = try swarm.reduce(into: [:]) { result, next in
            guard
                !next.value.failed,
                let signatureBase64: String = next.value.signatureBase64,
                let encodedSignature: Data = Data(base64Encoded: signatureBase64)
            else {
                result[next.key] = ([], 0)
                
                if let reason: String = next.value.reason, let statusCode: Int = next.value.code {
                    SNLog("Couldn't update expiry from: \(next.key) due to error: \(reason) (\(statusCode)).")
                }
                else {
                    SNLog("Couldn't update expiry from: \(next.key).")
                }
                return
            }
            
            /// Signature of
            /// `( PUBKEY_HEX || EXPIRY || RMSG[0] || ... || RMSG[N] || UMSG[0] || ... || UMSG[M] )`
            /// where RMSG are the requested expiry hashes and UMSG are the actual updated hashes.  The signature uses
            /// the node's ed25519 pubkey.
            let verificationBytes: [UInt8] = userX25519PublicKey.bytes
                .appending(contentsOf: "\(String(describing: next.value.expiry))".data(using: .ascii)?.bytes)
                .appending(contentsOf: validationData.joined().bytes)
                .appending(contentsOf: next.value.updated.joined().bytes)
            let isValid: Bool = sodium.sign.verify(
                message: verificationBytes,
                publicKey: Data(hex: next.key).bytes,
                signature: encodedSignature.bytes
            )
            
            // If the update signature is invalid then we want to fail here
            guard isValid else { throw SnodeAPIError.signatureVerificationFailed }
            
            // If we didn't get an `expiry` value from the snode then don't bother adding it to the result
            // as it's not valid data
            guard let expiry: UInt64 = next.value.expiry else { return }
            
            result[next.key] = (hashes: next.value.updated, expiry: expiry)
        }
        
        return try Self.validated(map: validationMap, totalResponseCount: swarm.count)
    }
}
