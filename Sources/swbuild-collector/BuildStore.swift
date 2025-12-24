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

/// Represents a target within a build
final class BuildTarget: @unchecked Sendable {
    let id: String
    let name: String
    var status: String = "pending"
    var startTime: Date?
    var endTime: Date?
    var tasks: [BuildTask] = []

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    var durationSeconds: Double? {
        guard let start = startTime, let end = endTime else { return nil }
        return end.timeIntervalSince(start)
    }

    func toJSON() -> [String: Any] {
        var json: [String: Any] = [
            "id": id,
            "name": name,
            "status": status,
            "taskCount": tasks.count
        ]
        if let start = startTime {
            json["startTime"] = ISO8601DateFormatter().string(from: start)
        }
        if let end = endTime {
            json["endTime"] = ISO8601DateFormatter().string(from: end)
        }
        if let duration = durationSeconds {
            json["durationSeconds"] = duration
        }
        json["tasks"] = tasks.map { $0.toJSON() }
        return json
    }
}

/// Represents a task within a target
final class BuildTask: @unchecked Sendable {
    let signature: String
    let type: String
    let ruleInfo: String
    var status: String = "pending"
    var startTime: Date?
    var endTime: Date?
    var exitCode: Int?

    init(signature: String, type: String, ruleInfo: String) {
        self.signature = signature
        self.type = type
        self.ruleInfo = ruleInfo
    }

    var durationSeconds: Double? {
        guard let start = startTime, let end = endTime else { return nil }
        return end.timeIntervalSince(start)
    }

    func toJSON() -> [String: Any] {
        var json: [String: Any] = [
            "signature": signature,
            "type": type,
            "ruleInfo": ruleInfo,
            "status": status
        ]
        if let start = startTime {
            json["startTime"] = ISO8601DateFormatter().string(from: start)
        }
        if let end = endTime {
            json["endTime"] = ISO8601DateFormatter().string(from: end)
        }
        if let duration = durationSeconds {
            json["durationSeconds"] = duration
        }
        if let code = exitCode {
            json["exitCode"] = code
        }
        return json
    }
}

/// Represents a complete build
final class Build: @unchecked Sendable {
    let sessionID: String
    let configuration: String
    let action: String
    var status: String = "running"
    let startTime: Date
    var endTime: Date?
    var targets: [String: BuildTarget] = [:]
    var tasksBySignature: [String: BuildTask] = [:]
    var errorCount: Int = 0
    var warningCount: Int = 0

    init(sessionID: String, configuration: String, action: String) {
        self.sessionID = sessionID
        self.configuration = configuration
        self.action = action
        self.startTime = Date()
    }

    var durationSeconds: Double {
        let end = endTime ?? Date()
        return end.timeIntervalSince(startTime)
    }

    var targetCount: Int {
        targets.count
    }

    var completedTargetCount: Int {
        targets.values.filter { $0.status == "succeeded" || $0.status == "failed" }.count
    }

    var totalTaskCount: Int {
        tasksBySignature.count
    }

    var completedTaskCount: Int {
        tasksBySignature.values.filter { $0.status == "succeeded" || $0.status == "failed" || $0.status == "cached" }.count
    }

    var runningTaskCount: Int {
        tasksBySignature.values.filter { $0.status == "running" }.count
    }

    func toJSON() -> [String: Any] {
        return [
            "sessionID": sessionID,
            "configuration": configuration,
            "action": action,
            "status": status,
            "startTime": ISO8601DateFormatter().string(from: startTime),
            "endTime": endTime.map { ISO8601DateFormatter().string(from: $0) } as Any,
            "durationSeconds": durationSeconds,
            "targetCount": targetCount,
            "completedTargetCount": completedTargetCount,
            "totalTaskCount": totalTaskCount,
            "completedTaskCount": completedTaskCount,
            "runningTaskCount": runningTaskCount,
            "errorCount": errorCount,
            "warningCount": warningCount,
            "targets": targets.values.map { $0.toJSON() }
        ]
    }
}

/// Thread-safe store for tracking builds
actor BuildStore {
    private var builds: [String: Build] = [:]
    private var buildHistory: [Build] = []
    private let maxHistory = 50

    // Callbacks for notifications
    nonisolated(unsafe) var onBuildStarted: ((Build) -> Void)?
    nonisolated(unsafe) var onBuildCompleted: ((Build) -> Void)?

    func handleBuildStarted(sessionID: String, configuration: String, action: String) {
        let build = Build(sessionID: sessionID, configuration: configuration, action: action)
        builds[sessionID] = build

        // Notify
        onBuildStarted?(build)
    }

    func handleBuildCompleted(sessionID: String, result: String, errorCount: Int, warningCount: Int) {
        guard let build = builds[sessionID] else { return }

        build.status = result
        build.endTime = Date()
        build.errorCount = errorCount
        build.warningCount = warningCount

        // Move to history
        buildHistory.insert(build, at: 0)
        if buildHistory.count > maxHistory {
            buildHistory.removeLast()
        }

        // Notify
        onBuildCompleted?(build)
    }

    func handleTargetStarted(sessionID: String, targetName: String, targetGUID: String) {
        guard let build = builds[sessionID] else { return }

        let target = BuildTarget(id: targetGUID, name: targetName)
        target.status = "running"
        target.startTime = Date()
        build.targets[targetGUID] = target
    }

    func handleTargetCompleted(sessionID: String, targetName: String, targetGUID: String, result: String) {
        guard let build = builds[sessionID],
              let target = build.targets[targetGUID] else { return }

        target.status = result
        target.endTime = Date()
    }

    func handleTaskStarted(sessionID: String, taskSignature: String, taskType: String, targetName: String?, ruleInfo: String) {
        guard let build = builds[sessionID] else { return }

        let task = BuildTask(signature: taskSignature, type: taskType, ruleInfo: ruleInfo)
        task.status = "running"
        task.startTime = Date()
        build.tasksBySignature[taskSignature] = task

        // Associate with target if known
        if let targetName = targetName {
            for (_, target) in build.targets where target.name == targetName {
                target.tasks.append(task)
                break
            }
        }
    }

    func handleTaskCompleted(sessionID: String, taskSignature: String, result: String, exitCode: Int?) {
        guard let build = builds[sessionID],
              let task = build.tasksBySignature[taskSignature] else { return }

        task.status = result
        task.endTime = Date()
        task.exitCode = exitCode
    }

    func handleTaskUpToDate(sessionID: String, taskSignature: String, taskType: String, targetName: String?) {
        guard let build = builds[sessionID] else { return }

        let task = BuildTask(signature: taskSignature, type: taskType, ruleInfo: "up-to-date")
        task.status = "cached"
        task.startTime = Date()
        task.endTime = Date()
        build.tasksBySignature[taskSignature] = task

        // Associate with target if known
        if let targetName = targetName {
            for (_, target) in build.targets where target.name == targetName {
                target.tasks.append(task)
                break
            }
        }
    }

    func getCurrentBuild() -> Build? {
        builds.values.first { $0.status == "running" }
    }

    func getBuild(sessionID: String) -> Build? {
        builds[sessionID] ?? buildHistory.first { $0.sessionID == sessionID }
    }

    func getAllBuilds() -> [Build] {
        var all = Array(builds.values)
        all.append(contentsOf: buildHistory)
        return all.sorted { $0.startTime > $1.startTime }
    }

    func getRecentBuilds(limit: Int = 10) -> [Build] {
        Array(getAllBuilds().prefix(limit))
    }
}
