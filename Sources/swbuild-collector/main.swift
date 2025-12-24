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
import ArgumentParser
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@main
struct SwiftBuildCollector: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swbuild-collector",
        abstract: "A telemetry collector for Swift Build that provides real-time build monitoring",
        version: "1.0.0"
    )

    @Option(name: .shortAndLong, help: "Unix socket path for receiving telemetry events")
    var socket: String = "/tmp/swiftbuild-telemetry.sock"

    @Option(name: .shortAndLong, help: "HTTP port for the web UI")
    var port: Int = 8384

    @Flag(name: .shortAndLong, help: "Enable verbose logging")
    var verbose: Bool = false

    mutating func run() async throws {
        // Check if a collector is already running on this port
        if isPortInUse(port) {
            print("Telemetry collector already running at http://localhost:\(port)")
            // Exit successfully - the existing collector will handle it
            return
        }

        print("Starting Swift Build Collector...")
        print("  Socket: \(socket)")
        print("  Web UI: http://localhost:\(port)")

        // Create the build store to track builds
        let buildStore = BuildStore()

        // Start the telemetry server
        let telemetryServer = TelemetryServer(socketPath: socket, buildStore: buildStore, verbose: verbose)

        // Start the HTTP server for web UI
        let httpServer = HTTPServer(port: port, buildStore: buildStore)

        // Create notification manager
        let notificationManager = NotificationManager()

        // Capture port value for closures
        let httpPort = port

        // Connect notification manager to build store
        buildStore.onBuildStarted = { build in
            notificationManager.showBuildStartedNotification(build: build, port: httpPort)
        }

        buildStore.onBuildCompleted = { build in
            notificationManager.showBuildCompletedNotification(build: build, port: httpPort)
        }

        // Start servers concurrently
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await telemetryServer.start()
            }

            group.addTask {
                try await httpServer.start()
            }

            // Wait for both servers (they run indefinitely)
            try await group.waitForAll()
        }
    }

    /// Check if a port is already in use by attempting to connect to it
    private func isPortInUse(_ port: Int) -> Bool {
        #if canImport(Darwin)
        let socketFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        #else
        let socketFD = Glibc.socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard socketFD >= 0 else { return false }
        defer { close(socketFD) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(socketFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        return result == 0
    }
}
