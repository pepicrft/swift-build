//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - Telemetry Event Protocol

/// Protocol that all telemetry events must implement.
/// Events are sent to an external collector via Unix socket using MsgPack encoding.
public protocol TelemetryEvent: Sendable {
    /// The type identifier for this event (e.g., "build_started", "task_completed")
    static var eventType: String { get }

    /// Timestamp in nanoseconds since epoch
    var timestamp: UInt64 { get }

    /// Session identifier to correlate events from the same build
    var sessionID: String { get }

    /// Encode the event to MsgPack format
    func encode(to encoder: MsgPackEncoder)
}

// MARK: - Build Lifecycle Events

/// Emitted when a build operation starts
public struct BuildStartedEvent: TelemetryEvent {
    public static let eventType = "build_started"

    public let timestamp: UInt64
    public let sessionID: String
    public let configuration: String
    public let targetCount: Int
    public let action: String

    public init(sessionID: String, configuration: String, targetCount: Int, action: String) {
        self.timestamp = Self.currentTimestamp()
        self.sessionID = sessionID
        self.configuration = configuration
        self.targetCount = targetCount
        self.action = action
    }

    public func encode(to encoder: MsgPackEncoder) {
        encoder.beginMap(6)
        encoder.append("type")
        encoder.append(Self.eventType)
        encoder.append("timestamp")
        encoder.append(timestamp)
        encoder.append("session_id")
        encoder.append(sessionID)
        encoder.append("configuration")
        encoder.append(configuration)
        encoder.append("target_count")
        encoder.append(Int64(targetCount))
        encoder.append("action")
        encoder.append(action)
        encoder.endMap()
    }
}

/// Build result status
public enum BuildResultStatus: String, Sendable {
    case succeeded
    case failed
    case cancelled
}

/// Emitted when a build operation completes
public struct BuildCompletedEvent: TelemetryEvent {
    public static let eventType = "build_completed"

    public let timestamp: UInt64
    public let sessionID: String
    public let result: BuildResultStatus
    public let durationNanos: UInt64
    public let errorCount: Int
    public let warningCount: Int

    public init(sessionID: String, result: BuildResultStatus, durationNanos: UInt64, errorCount: Int = 0, warningCount: Int = 0) {
        self.timestamp = Self.currentTimestamp()
        self.sessionID = sessionID
        self.result = result
        self.durationNanos = durationNanos
        self.errorCount = errorCount
        self.warningCount = warningCount
    }

    public func encode(to encoder: MsgPackEncoder) {
        encoder.beginMap(7)
        encoder.append("type")
        encoder.append(Self.eventType)
        encoder.append("timestamp")
        encoder.append(timestamp)
        encoder.append("session_id")
        encoder.append(sessionID)
        encoder.append("result")
        encoder.append(result.rawValue)
        encoder.append("duration_nanos")
        encoder.append(durationNanos)
        encoder.append("error_count")
        encoder.append(Int64(errorCount))
        encoder.append("warning_count")
        encoder.append(Int64(warningCount))
        encoder.endMap()
    }
}

// MARK: - Target Lifecycle Events

/// Emitted when a target starts building
public struct TargetStartedEvent: TelemetryEvent {
    public static let eventType = "target_started"

    public let timestamp: UInt64
    public let sessionID: String
    public let targetName: String
    public let targetGUID: String

    public init(sessionID: String, targetName: String, targetGUID: String) {
        self.timestamp = Self.currentTimestamp()
        self.sessionID = sessionID
        self.targetName = targetName
        self.targetGUID = targetGUID
    }

    public func encode(to encoder: MsgPackEncoder) {
        encoder.beginMap(5)
        encoder.append("type")
        encoder.append(Self.eventType)
        encoder.append("timestamp")
        encoder.append(timestamp)
        encoder.append("session_id")
        encoder.append(sessionID)
        encoder.append("target_name")
        encoder.append(targetName)
        encoder.append("target_guid")
        encoder.append(targetGUID)
        encoder.endMap()
    }
}

/// Emitted when a target completes building
public struct TargetCompletedEvent: TelemetryEvent {
    public static let eventType = "target_completed"

    public let timestamp: UInt64
    public let sessionID: String
    public let targetName: String
    public let targetGUID: String
    public let result: BuildResultStatus
    public let durationNanos: UInt64

    public init(sessionID: String, targetName: String, targetGUID: String, result: BuildResultStatus, durationNanos: UInt64) {
        self.timestamp = Self.currentTimestamp()
        self.sessionID = sessionID
        self.targetName = targetName
        self.targetGUID = targetGUID
        self.result = result
        self.durationNanos = durationNanos
    }

    public func encode(to encoder: MsgPackEncoder) {
        encoder.beginMap(7)
        encoder.append("type")
        encoder.append(Self.eventType)
        encoder.append("timestamp")
        encoder.append(timestamp)
        encoder.append("session_id")
        encoder.append(sessionID)
        encoder.append("target_name")
        encoder.append(targetName)
        encoder.append("target_guid")
        encoder.append(targetGUID)
        encoder.append("result")
        encoder.append(result.rawValue)
        encoder.append("duration_nanos")
        encoder.append(durationNanos)
        encoder.endMap()
    }
}

// MARK: - Task Lifecycle Events

/// Emitted when a task starts executing
public struct TaskStartedEvent: TelemetryEvent {
    public static let eventType = "task_started"

    public let timestamp: UInt64
    public let sessionID: String
    public let taskSignature: String
    public let taskType: String
    public let targetName: String?
    public let ruleInfo: String

    public init(sessionID: String, taskSignature: String, taskType: String, targetName: String?, ruleInfo: String) {
        self.timestamp = Self.currentTimestamp()
        self.sessionID = sessionID
        self.taskSignature = taskSignature
        self.taskType = taskType
        self.targetName = targetName
        self.ruleInfo = ruleInfo
    }

    public func encode(to encoder: MsgPackEncoder) {
        encoder.beginMap(7)
        encoder.append("type")
        encoder.append(Self.eventType)
        encoder.append("timestamp")
        encoder.append(timestamp)
        encoder.append("session_id")
        encoder.append(sessionID)
        encoder.append("task_signature")
        encoder.append(taskSignature)
        encoder.append("task_type")
        encoder.append(taskType)
        encoder.append("target_name")
        if let targetName = targetName {
            encoder.append(targetName)
        } else {
            encoder.appendNil()
        }
        encoder.append("rule_info")
        encoder.append(ruleInfo)
        encoder.endMap()
    }
}

/// Task result status
public enum TaskResultStatus: String, Sendable {
    case succeeded
    case failed
    case cancelled
    case skipped
}

/// Emitted when a task completes
public struct TaskCompletedEvent: TelemetryEvent {
    public static let eventType = "task_completed"

    public let timestamp: UInt64
    public let sessionID: String
    public let taskSignature: String
    public let result: TaskResultStatus
    public let durationNanos: UInt64
    public let exitCode: Int?

    public init(sessionID: String, taskSignature: String, result: TaskResultStatus, durationNanos: UInt64, exitCode: Int? = nil) {
        self.timestamp = Self.currentTimestamp()
        self.sessionID = sessionID
        self.taskSignature = taskSignature
        self.result = result
        self.durationNanos = durationNanos
        self.exitCode = exitCode
    }

    public func encode(to encoder: MsgPackEncoder) {
        encoder.beginMap(7)
        encoder.append("type")
        encoder.append(Self.eventType)
        encoder.append("timestamp")
        encoder.append(timestamp)
        encoder.append("session_id")
        encoder.append(sessionID)
        encoder.append("task_signature")
        encoder.append(taskSignature)
        encoder.append("result")
        encoder.append(result.rawValue)
        encoder.append("duration_nanos")
        encoder.append(durationNanos)
        encoder.append("exit_code")
        if let exitCode = exitCode {
            encoder.append(Int64(exitCode))
        } else {
            encoder.appendNil()
        }
        encoder.endMap()
    }
}

/// Emitted when a task is determined to be up-to-date (cached)
public struct TaskUpToDateEvent: TelemetryEvent {
    public static let eventType = "task_up_to_date"

    public let timestamp: UInt64
    public let sessionID: String
    public let taskSignature: String
    public let taskType: String
    public let targetName: String?

    public init(sessionID: String, taskSignature: String, taskType: String, targetName: String?) {
        self.timestamp = Self.currentTimestamp()
        self.sessionID = sessionID
        self.taskSignature = taskSignature
        self.taskType = taskType
        self.targetName = targetName
    }

    public func encode(to encoder: MsgPackEncoder) {
        encoder.beginMap(6)
        encoder.append("type")
        encoder.append(Self.eventType)
        encoder.append("timestamp")
        encoder.append(timestamp)
        encoder.append("session_id")
        encoder.append(sessionID)
        encoder.append("task_signature")
        encoder.append(taskSignature)
        encoder.append("task_type")
        encoder.append(taskType)
        encoder.append("target_name")
        if let targetName = targetName {
            encoder.append(targetName)
        } else {
            encoder.appendNil()
        }
        encoder.endMap()
    }
}

// MARK: - Diagnostic Events

/// Diagnostic severity level
public enum DiagnosticSeverity: String, Sendable {
    case note
    case warning
    case error
}

/// Emitted when a diagnostic (warning/error) is produced
public struct DiagnosticEmittedEvent: TelemetryEvent {
    public static let eventType = "diagnostic_emitted"

    public let timestamp: UInt64
    public let sessionID: String
    public let severity: DiagnosticSeverity
    public let message: String
    public let filePath: String?
    public let line: Int?
    public let column: Int?
    public let taskSignature: String?

    public init(sessionID: String, severity: DiagnosticSeverity, message: String, filePath: String? = nil, line: Int? = nil, column: Int? = nil, taskSignature: String? = nil) {
        self.timestamp = Self.currentTimestamp()
        self.sessionID = sessionID
        self.severity = severity
        self.message = message
        self.filePath = filePath
        self.line = line
        self.column = column
        self.taskSignature = taskSignature
    }

    public func encode(to encoder: MsgPackEncoder) {
        encoder.beginMap(9)
        encoder.append("type")
        encoder.append(Self.eventType)
        encoder.append("timestamp")
        encoder.append(timestamp)
        encoder.append("session_id")
        encoder.append(sessionID)
        encoder.append("severity")
        encoder.append(severity.rawValue)
        encoder.append("message")
        encoder.append(message)
        encoder.append("file_path")
        if let filePath = filePath {
            encoder.append(filePath)
        } else {
            encoder.appendNil()
        }
        encoder.append("line")
        if let line = line {
            encoder.append(Int64(line))
        } else {
            encoder.appendNil()
        }
        encoder.append("column")
        if let column = column {
            encoder.append(Int64(column))
        } else {
            encoder.appendNil()
        }
        encoder.append("task_signature")
        if let taskSignature = taskSignature {
            encoder.append(taskSignature)
        } else {
            encoder.appendNil()
        }
        encoder.endMap()
    }
}

// MARK: - Task Invalidation Events

/// Reason why a task was invalidated
public enum InvalidationReason: String, Sendable {
    case sourceChanged = "source_changed"
    case dependencyChanged = "dependency_changed"
    case buildSettingsChanged = "build_settings_changed"
    case cacheEvicted = "cache_evicted"
    case signatureMismatch = "signature_mismatch"
    case forcedRebuild = "forced_rebuild"
}

/// Emitted when a task is invalidated and must be rebuilt
public struct TaskInvalidatedEvent: TelemetryEvent {
    public static let eventType = "task_invalidated"

    public let timestamp: UInt64
    public let sessionID: String
    public let taskSignature: String
    public let reason: InvalidationReason
    public let changedInputs: [String]

    public init(sessionID: String, taskSignature: String, reason: InvalidationReason, changedInputs: [String] = []) {
        self.timestamp = Self.currentTimestamp()
        self.sessionID = sessionID
        self.taskSignature = taskSignature
        self.reason = reason
        self.changedInputs = changedInputs
    }

    public func encode(to encoder: MsgPackEncoder) {
        encoder.beginMap(6)
        encoder.append("type")
        encoder.append(Self.eventType)
        encoder.append("timestamp")
        encoder.append(timestamp)
        encoder.append("session_id")
        encoder.append(sessionID)
        encoder.append("task_signature")
        encoder.append(taskSignature)
        encoder.append("reason")
        encoder.append(reason.rawValue)
        encoder.append("changed_inputs")
        encoder.append(changedInputs) { encoder.append($0) }
        encoder.endMap()
    }
}

// MARK: - Progress Events

/// Emitted periodically to report build progress
public struct BuildProgressEvent: TelemetryEvent {
    public static let eventType = "build_progress"

    public let timestamp: UInt64
    public let sessionID: String
    public let totalTasks: Int
    public let completedTasks: Int
    public let runningTasks: Int
    public let pendingTasks: Int

    public init(sessionID: String, totalTasks: Int, completedTasks: Int, runningTasks: Int, pendingTasks: Int) {
        self.timestamp = Self.currentTimestamp()
        self.sessionID = sessionID
        self.totalTasks = totalTasks
        self.completedTasks = completedTasks
        self.runningTasks = runningTasks
        self.pendingTasks = pendingTasks
    }

    public func encode(to encoder: MsgPackEncoder) {
        encoder.beginMap(7)
        encoder.append("type")
        encoder.append(Self.eventType)
        encoder.append("timestamp")
        encoder.append(timestamp)
        encoder.append("session_id")
        encoder.append(sessionID)
        encoder.append("total_tasks")
        encoder.append(Int64(totalTasks))
        encoder.append("completed_tasks")
        encoder.append(Int64(completedTasks))
        encoder.append("running_tasks")
        encoder.append(Int64(runningTasks))
        encoder.append("pending_tasks")
        encoder.append(Int64(pendingTasks))
        encoder.endMap()
    }
}

// MARK: - Timestamp Helper

extension TelemetryEvent {
    /// Get current timestamp in nanoseconds
    public static func currentTimestamp() -> UInt64 {
        var timespec = timespec()
        clock_gettime(CLOCK_REALTIME, &timespec)
        return UInt64(timespec.tv_sec) * 1_000_000_000 + UInt64(timespec.tv_nsec)
    }
}

