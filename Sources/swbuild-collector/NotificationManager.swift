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

/// Manages system notifications for build events using osascript (works from CLI)
final class NotificationManager: @unchecked Sendable {

    init() {
        // No initialization needed - we use osascript which doesn't require setup
    }

    func showBuildStartedNotification(build: Build, port: Int) {
        #if os(macOS)
        let title = "Build Started"
        let body = "\(build.configuration) build started"

        showNotification(title: title, body: body)
        #endif
    }

    func showBuildCompletedNotification(build: Build, port: Int) {
        #if os(macOS)
        let title: String
        let body: String
        let sound: String

        switch build.status {
        case "succeeded":
            title = "Build Succeeded ✓"
            body = "\(build.configuration) build completed in \(formatDuration(build.durationSeconds))"
            sound = "Glass"
        case "failed":
            let errorText = build.errorCount == 1 ? "1 error" : "\(build.errorCount) errors"
            title = "Build Failed ✗"
            body = "\(build.configuration) build failed with \(errorText)"
            sound = "Basso"
        case "cancelled":
            title = "Build Cancelled"
            body = "\(build.configuration) build was cancelled"
            sound = "Pop"
        default:
            title = "Build Completed"
            body = "\(build.configuration) build finished"
            sound = "Glass"
        }

        showNotification(title: title, body: body, sound: sound)
        #endif
    }

    private func showNotification(title: String, body: String, sound: String = "default") {
        #if os(macOS)
        // Use osascript to show notification - works from CLI without app bundle
        let script = """
        display notification "\(body.replacingOccurrences(of: "\"", with: "\\\""))" with title "\(title.replacingOccurrences(of: "\"", with: "\\\""))" sound name "\(sound)"
        """

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            // Fallback to console output
            print("[\(title)] \(body)")
        }
        #else
        // Fallback: print to console
        print("[\(title)] \(body)")
        #endif
    }

    private func formatDuration(_ seconds: Double) -> String {
        if seconds < 1 {
            return String(format: "%.0fms", seconds * 1000)
        } else if seconds < 60 {
            return String(format: "%.1fs", seconds)
        } else {
            let mins = Int(seconds / 60)
            let secs = Int(seconds.truncatingRemainder(dividingBy: 60))
            return "\(mins)m \(secs)s"
        }
    }
}
