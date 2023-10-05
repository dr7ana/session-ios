// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

public enum ConfigurationSyncJob: JobExecutor {
    public static let maxFailureCount: Int = -1
    public static let requiresThreadId: Bool = true
    public static let requiresInteractionId: Bool = false
    private static let maxRunFrequency: TimeInterval = 3
    private static let waitTimeForExpirationUpdate: TimeInterval = 1
    
    public static func run(
        _ job: Job,
        queue: DispatchQueue,
        success: @escaping (Job, Bool, Dependencies) -> (),
        failure: @escaping (Job, Error?, Bool, Dependencies) -> (),
        deferred: @escaping (Job, Dependencies) -> (),
        using dependencies: Dependencies
    ) {
        guard Identity.userCompletedRequiredOnboarding(using: dependencies) else {
            return success(job, true, dependencies)
        }
        
        // It's possible for multiple ConfigSyncJob's with the same target (user/group) to try to run at the
        // same time since as soon as one is started we will enqueue a second one, rather than adding dependencies
        // between the jobs we just continue to defer the subsequent job while the first one is running in
        // order to prevent multiple configurationSync jobs with the same target from running at the same time
        guard
            dependencies[singleton: .jobRunner]
                .jobInfoFor(state: .running, variant: .configurationSync)
                .filter({ key, info in
                    key != job.id &&                // Exclude this job
                    info.threadId == job.threadId   // Exclude jobs for different ids
                })
                .isEmpty
        else {
            // Defer the job to run 'maxRunFrequency' from when this one ran (if we don't it'll try start
            // it again immediately which is pointless)
            let updatedJob: Job? = dependencies[singleton: .storage].write { db in
                try job
                    .with(nextRunTimestamp: dependencies.dateNow.timeIntervalSince1970 + maxRunFrequency)
                    .saved(db)
            }
            
            SNLog("[ConfigurationSyncJob] For \(job.threadId ?? "UnknownId") deferred due to in progress job")
            return deferred(updatedJob ?? job, dependencies)
        }
        
        // If we don't have a userKeyPair yet then there is no need to sync the configuration
        // as the user doesn't exist yet (this will get triggered on the first launch of a
        // fresh install due to the migrations getting run)
        guard
            let sessionIdHexString: String = job.threadId,
            let pendingConfigChanges: [SessionUtil.PushData] = dependencies[singleton: .storage]
                .read(using: dependencies, { db in
                    try SessionUtil.pendingChanges(db, sessionIdHexString: sessionIdHexString, using: dependencies)
                })
        else {
            SNLog("[ConfigurationSyncJob] For \(job.threadId ?? "UnknownId") failed due to invalid data")
            return failure(job, StorageError.generic, false, dependencies)
        }
        
        // If there are no pending changes then the job can just complete (next time something
        // is updated we want to try and run immediately so don't scuedule another run in this case)
        guard !pendingConfigChanges.isEmpty else {
            SNLog("[ConfigurationSyncJob] For \(sessionIdHexString) completed with no pending changes")
            return success(job, true, dependencies)
        }
        
        // Merge all obsolete hashes into a single set
        let allObsoleteHashes: Set<String>? = pendingConfigChanges
            .map { $0.obsoleteHashes }
            .reduce([], +)
            .nullIfEmpty()?
            .asSet()
        let jobStartTimestamp: TimeInterval = dependencies.dateNow.timeIntervalSince1970
        let messageSendTimestamp: Int64 = SnodeAPI.currentOffsetTimestampMs(using: dependencies)
        
        SNLog("[ConfigurationSyncJob] For \(sessionIdHexString) started with \(pendingConfigChanges.count) change\(pendingConfigChanges.count == 1 ? "" : "s")")
        dependencies[singleton: .storage]
            .readPublisher { db -> HTTP.PreparedRequest<HTTP.BatchResponse> in
                try SnodeAPI.preparedSequence(
                    db,
                    requests: try pendingConfigChanges
                        .map { pushData -> ErasedPreparedRequest in
                            try SnodeAPI
                                .preparedSendMessage(
                                    db,
                                    message: SnodeMessage(
                                        recipient: sessionIdHexString,
                                        data: pushData.data.base64EncodedString(),
                                        ttl: pushData.variant.ttl,
                                        timestampMs: UInt64(messageSendTimestamp)
                                    ),
                                    in: pushData.variant.namespace,
                                    authInfo: try SnodeAPI.AuthenticationInfo(
                                        db,
                                        sessionIdHexString: sessionIdHexString,
                                        using: dependencies
                                    ),
                                    using: dependencies
                                )
                        }
                        .appending(
                            try allObsoleteHashes.map { serverHashes -> ErasedPreparedRequest in
                                // TODO: Seems like older hashes aren't getting exposed via this method? (ie. I keep getting old ones when polling but not sure if they are included and not getting deleted, or just not included...)
                                // TODO: Need to test this in updated groups
                                try SnodeAPI.preparedDeleteMessages(
                                    serverHashes: Array(serverHashes),
                                    requireSuccessfulDeletion: false,
                                    authInfo: try SnodeAPI.AuthenticationInfo(
                                        db,
                                        sessionIdHexString: sessionIdHexString,
                                        using: dependencies
                                    ),
                                    using: dependencies
                                )
                            }
                        ),
                    requireAllBatchResponses: false,
                    associatedWith: sessionIdHexString,
                    using: dependencies
                )
            }
            .flatMap { $0.send(using: dependencies) }
            .subscribe(on: queue)
            .receive(on: queue)
            .map { (_: ResponseInfoType, response: HTTP.BatchResponse) -> [ConfigDump] in
                /// The number of responses returned might not match the number of changes sent but they will be returned
                /// in the same order, this means we can just `zip` the two arrays as it will take the smaller of the two and
                /// correctly align the response to the change
                zip(response, pendingConfigChanges)
                    .compactMap { (subResponse: Any, pushData: SessionUtil.PushData) -> ConfigDump? in
                        /// If the request wasn't successful then just ignore it (the next time we sync this config we will try
                        /// to send the changes again)
                        guard
                            let typedResponse: HTTP.BatchSubResponse<SendMessagesResponse> = (subResponse as? HTTP.BatchSubResponse<SendMessagesResponse>),
                            200...299 ~= typedResponse.code,
                            !typedResponse.failedToParseBody,
                            let sendMessageResponse: SendMessagesResponse = typedResponse.body
                        else { return nil }
                        
                        /// Since this change was successful we need to mark it as pushed and generate any config dumps
                        /// which need to be stored
                        return SessionUtil.markingAsPushed(
                            seqNo: pushData.seqNo,
                            serverHash: sendMessageResponse.hash,
                            sentTimestamp: messageSendTimestamp,
                            variant: pushData.variant,
                            sessionIdHexString: sessionIdHexString,
                            using: dependencies
                        )
                    }
            }
            .sinkUntilComplete(
                receiveCompletion: { result in
                    switch result {
                        case .finished: SNLog("[ConfigurationSyncJob] For \(sessionIdHexString) completed")
                        case .failure(let error):
                            SNLog("[ConfigurationSyncJob] For \(sessionIdHexString) failed due to error: \(error)")
                            failure(job, error, false, dependencies)
                    }
                },
                receiveValue: { (configDumps: [ConfigDump]) in
                    // Flag to indicate whether the job should be finished or will run again
                    var shouldFinishCurrentJob: Bool = false
                    
                    // Lastly we need to save the updated dumps to the database
                    let updatedJob: Job? = dependencies[singleton: .storage].write { db in
                        // Save the updated dumps to the database
                        try configDumps.forEach { try $0.save(db) }
                        
                        // When we complete the 'ConfigurationSync' job we want to immediately schedule
                        // another one with a 'nextRunTimestamp' set to the 'maxRunFrequency' value to
                        // throttle the config sync requests
                        let nextRunTimestamp: TimeInterval = (jobStartTimestamp + maxRunFrequency)
                        
                        // If another 'ConfigurationSync' job was scheduled then update that one
                        // to run at 'nextRunTimestamp' and make the current job stop
                        if
                            let existingJob: Job = try? Job
                                .filter(Job.Columns.id != job.id)
                                .filter(Job.Columns.variant == Job.Variant.configurationSync)
                                .filter(Job.Columns.threadId == sessionIdHexString)
                                .order(Job.Columns.nextRunTimestamp.asc)
                                .fetchOne(db)
                        {
                            // If the next job isn't currently running then delay it's start time
                            // until the 'nextRunTimestamp'
                            if !dependencies[singleton: .jobRunner].isCurrentlyRunning(existingJob) {
                                _ = try existingJob
                                    .with(nextRunTimestamp: nextRunTimestamp)
                                    .saved(db)
                            }
                            
                            // If there is another job then we should finish this one
                            shouldFinishCurrentJob = true
                            return job
                        }
                        
                        return try job
                            .with(nextRunTimestamp: nextRunTimestamp)
                            .saved(db)
                    }
                    
                    success((updatedJob ?? job), shouldFinishCurrentJob, dependencies)
                }
            )
    }
}

// MARK: - Convenience

public extension ConfigurationSyncJob {
    static func enqueue(
        _ db: Database,
        sessionIdHexString: String,
        using dependencies: Dependencies = Dependencies()
    ) {
        // Upsert a config sync job if needed
        dependencies[singleton: .jobRunner].upsert(
            db,
            job: ConfigurationSyncJob.createIfNeeded(db, sessionIdHexString: sessionIdHexString, using: dependencies),
            canStartJob: true,
            using: dependencies
        )
    }
    
    @discardableResult static func createIfNeeded(
        _ db: Database,
        sessionIdHexString: String,
        using dependencies: Dependencies = Dependencies()
    ) -> Job? {
        /// The ConfigurationSyncJob will automatically reschedule itself to run again after 3 seconds so if there is an existing
        /// job then there is no need to create another instance
        ///
        /// **Note:** Jobs with different `threadId` values can run concurrently
        guard
            dependencies[singleton: .jobRunner]
                .jobInfoFor(state: .running, variant: .configurationSync)
                .filter({ _, info in info.threadId == sessionIdHexString })
                .isEmpty,
            (try? Job
                .filter(Job.Columns.variant == Job.Variant.configurationSync)
                .filter(Job.Columns.threadId == sessionIdHexString)
                .isEmpty(db))
                .defaulting(to: false)
        else { return nil }
        
        // Otherwise create a new job
        return Job(
            variant: .configurationSync,
            behaviour: .recurring,
            threadId: sessionIdHexString
        )
    }
    
    static func run(
        sessionIdHexString: String,
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<Void, Error> {
        // Trigger the job emitting the result when completed
        return Deferred {
            Future { resolver in
                ConfigurationSyncJob.run(
                    Job(variant: .configurationSync, threadId: sessionIdHexString),
                    queue: .global(qos: .userInitiated),
                    success: { _, _, _ in resolver(Result.success(())) },
                    failure: { _, error, _, _ in resolver(Result.failure(error ?? HTTPError.generic)) },
                    deferred: { _, _ in },
                    using: dependencies
                )
            }
        }
        .eraseToAnyPublisher()
    }
}
