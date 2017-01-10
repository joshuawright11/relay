//
//  Relay.swift
//  Relay
//
//  Created by Evan Kimia on 12/20/16.
//  Copyright © 2016 zero. All rights reserved.
//

import Foundation
import GRDB
import CocoaLumberjack


public class Relay: DDAbstractLogger, URLSessionTaskDelegate {
    weak var delegate: RelayDelegate?
    var identifier: String
    var configuration: RelayRemoteConfiguration?
    var dbQueue: DatabaseQueue?
    var urlSession: URLSessionProtocol?
    var uploadRetries = 3

    private let urlSessionIdentifier: String?

    /// Initializes the logger using GRDB to interface with SQLite, and your standard URLSession for uploading
    /// logs to the specified server.
    ///
    /// - Parameters:
    ///   - dbPath: Location for storing the database containing logs. Please be careful not to specify a nonpersistent
    ///   location for production use.
    ///
    ///   - configuration: Remote configuration for uploading logs. See the `persistentDictionary` method on `LogRecord` for information
    ///   on the JSON body and the `RelayRemoteConfiguration` class for options.
    ///
    ///   - session: session to use to upload the logs. If one is not provided a background session will be made
    ///
    /// - Throws: A DatabaseError is thrown whenever an SQLite error occurs. See the GRDB documentation here
    ///   for more information: https://github.com/groue/GRDB.swift#documentation
    ///
    required public init(identifier: String, configuration: RelayRemoteConfiguration? = nil, session: URLSessionProtocol? = nil) throws {
        
        self.identifier = identifier
        self.configuration = configuration
        
        dbQueue = try DatabaseQueue(path: try getRelayDirectory() + identifier + ".sqlite")
        
        if let session = session {
            urlSession = session
        } else {
//            // Setup a background NSURLSession
//            let backgroundConfig = URLSessionConfiguration.background(withIdentifier: "zerofinancial.inc.logger")
//            urlSession = URLSession(configuration: backgroundConfig)
        }
        
        urlSessionIdentifier = urlSession?.configuration.identifier
        
        try dbQueue?.inDatabase { db in
            guard try !db.tableExists(identifier) else { return }

            try db.create(table: LogRecord.TableName) { t in
                t.column("uuid", .text).primaryKey()
                t.column("message", .text)
                t.column("flag", .integer).notNull()
                t.column("level", .integer).notNull()
                t.column("context", .text)
                t.column("file", .text)
                t.column("function", .text)
                t.column("line", .integer)
                t.column("date", .datetime)
                t.column("upload_task_id", .integer)
                t.column("logger_identifier", .text)
                t.column("upload_retries", .integer).notNull().defaults(to: 0)
            }
        }
    }
    
    override init() {
        fatalError("Please use init(dbPath:) instead.")
    }
    
    deinit {
        urlSession?.finishTasksAndInvalidate()
    }
    
    func reset() throws {
        try dbQueue?.inDatabase({ db in
            try db.drop(table: identifier)
        })
    }
    
    typealias taskCompletion = (Data?, URLResponse?, Error?) -> Swift.Void
    
    func flushLogs() throws {
        try dbQueue?.inDatabase({ db in
            let logRecords = try LogRecord.filter(Column("upload_task_id") == nil).fetchAll(db)
            for record in logRecords {
                do {
                    try uploadLogRecord(logRecord: record, db: db)
                    try record.update(db)
                } catch {
                    print(error)
                }
            }
        })
    }
    
    private func uploadLogRecord(logRecord: LogRecord, db: Database) throws {
        let jsonData = try JSONSerialization.data(withJSONObject: logRecord.dict(), options: .prettyPrinted)
        let logUploadRequest = URLRequest(url: configuration!.host)
        let task = urlSession?.uploadTask(with: logUploadRequest, from: jsonData)
        logRecord.uploadTaskID = task?.taskIdentifier
        try logRecord.update(db)
        task?.resume()
    }
    
    func cleanup() throws {
        // Get our tasks from the session and ensure we dont have a log record associated with a nonexistent task.
        urlSession?.getAllTasks { tasks in
            try! self.dbQueue!.inTransaction { db in
                for record in try LogRecord.filter(Column("upload_task_id") != nil).fetchAll(db) {
                    if tasks.flatMap({ record.uploadTaskID == $0.taskIdentifier }).first == nil {
                        record.uploadTaskID = nil
                        try record.update(db)
                        try self.uploadLogRecord(logRecord: record, db: db)
                    }
                }
                
                return .commit
            }
        }
    }
    
    public func processLogUploadTask(task: URLSessionUploadTask) throws {
        try dbQueue?.inDatabase { db in
            guard let record = try LogRecord.filter(Column("upload_task_id") == task.taskIdentifier).fetchOne(db) else { return  }
            if let httpResponse = task.response as? HTTPURLResponse {
                if httpResponse.statusCode != 200 {
                    record.uploadTaskID = nil
                    record.uploadRetries += 1
                    try record.update(db)
                    // Should we toss it or try uploading it again?
                    if record.uploadRetries < uploadRetries {
                        try uploadLogRecord(logRecord: record, db: db)
                    } else {
                        try record.delete(db)
                    }
                    delegate?.relay(relay: self, didFailToUploadLogRecord: record, error: task.error, response: httpResponse)
                } else {
                    try record.delete(db)
                    delegate?.relay(relay: self, didUploadLogRecord: record)
                }
            }
        }
    }
    
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let task = task as? URLSessionUploadTask {
            do {
            try processLogUploadTask(task: task)
            } catch {
                print(error)
            }
        }
    }
    
    // MARK: DDAbstractLogger Methods

    override public func log(message logMessage: DDLogMessage!) {
        // Generate a LogRecord from a LogMessage
        let logRecord = LogRecord(logMessage: logMessage, loggerIdentifier: identifier)
        try! dbQueue?.inDatabase({ db in
            try logRecord.save(db)
        })
    }
}
