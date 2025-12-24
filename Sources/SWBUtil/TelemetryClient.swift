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
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif os(Windows)
import WinSDK
#endif

/// Environment variable to disable telemetry (set to "0" to disable)
public let telemetryEnabledEnvironmentVariable = EnvironmentKey("SWIFTBUILD_TELEMETRY")

/// Environment variable name for the telemetry socket path
public let telemetrySocketEnvironmentVariable = EnvironmentKey("SWIFTBUILD_TELEMETRY_SOCKET")

/// A client for sending telemetry events to an external collector via Unix socket.
///
/// The client uses fire-and-forget semantics to avoid impacting build performance.
/// Events are serialized using MsgPack with a length-prefix protocol:
/// - 4 bytes: payload length (little-endian uint32)
/// - N bytes: MsgPack-encoded event
public final class TelemetryClient: @unchecked Sendable {
    /// Well-known socket path that the collector uses by default
    private static let defaultSocketPath = "/tmp/swiftbuild-telemetry.sock"

    /// Shared instance that connects if socket is available
    public static let shared: TelemetryClient? = {
        // Check if telemetry is explicitly disabled
        if getEnvironmentVariable(telemetryEnabledEnvironmentVariable) == "0" {
            return nil
        }

        // Use socket path from environment, or default
        let socketPath = getEnvironmentVariable(telemetrySocketEnvironmentVariable) ?? defaultSocketPath

        // Only create client if socket exists (collector is running)
        guard FileManager.default.fileExists(atPath: socketPath) else {
            return nil
        }

        return TelemetryClient(socketPath: socketPath)
    }()

    /// The socket path for the telemetry collector
    private let socketPath: String

    /// File descriptor for the socket connection
    private var socketFD: Int32 = -1

    /// Queue for thread-safe socket operations
    private let queue = DispatchQueue(label: "com.apple.swiftbuild.telemetry", qos: .utility)

    /// Whether the client is connected
    private var isConnected: Bool = false

    /// Creates a new telemetry client
    /// - Parameter socketPath: Path to the Unix socket
    public init(socketPath: String) {
        self.socketPath = socketPath
        connect()
    }

    deinit {
        disconnect()
    }

    // MARK: - Connection Management

    /// Attempt to connect to the telemetry collector
    private func connect() {
        queue.async { [weak self] in
            self?._connect()
        }
    }

    private func _connect() {
        guard !isConnected else { return }

        #if os(Windows)
        // Windows doesn't support Unix sockets
        return
        #else

        // Create socket
        socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return }

        // Set non-blocking mode
        let flags = fcntl(socketFD, F_GETFL, 0)
        _ = fcntl(socketFD, F_SETFL, flags | O_NONBLOCK)

        // Prepare address
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        // Copy socket path
        let pathBytes = socketPath.utf8
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard pathBytes.count < maxLen else {
            close(socketFD)
            socketFD = -1
            return
        }

        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxLen) { dest in
                for (i, byte) in pathBytes.enumerated() {
                    dest[i] = CChar(bitPattern: byte)
                }
                dest[pathBytes.count] = 0
            }
        }

        // Connect
        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(socketFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        if connectResult == 0 || errno == EINPROGRESS {
            isConnected = true
        } else {
            close(socketFD)
            socketFD = -1
        }
        #endif
    }

    /// Disconnect from the telemetry collector
    private func disconnect() {
        queue.sync {
            _disconnect()
        }
    }

    private func _disconnect() {
        #if !os(Windows)
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
        isConnected = false
        #endif
    }

    // MARK: - Event Sending

    /// Send a telemetry event to the collector
    /// - Parameter event: The event to send
    public func send<E: TelemetryEvent>(_ event: E) {
        queue.async { [weak self] in
            self?._send(event)
        }
    }

    private func _send<E: TelemetryEvent>(_ event: E) {
        if !isConnected {
            _connect()
            guard isConnected else { return }
        }

        // Encode event to MsgPack
        let encoder = MsgPackEncoder()
        event.encode(to: encoder)
        let payload = encoder.bytes

        // Create length-prefixed message
        var message = [UInt8]()
        message.reserveCapacity(4 + payload.count)

        // Length prefix (little-endian uint32)
        let length = UInt32(payload.count)
        message.append(UInt8(truncatingIfNeeded: length))
        message.append(UInt8(truncatingIfNeeded: length >> 8))
        message.append(UInt8(truncatingIfNeeded: length >> 16))
        message.append(UInt8(truncatingIfNeeded: length >> 24))

        // Payload
        message.append(contentsOf: payload)

        // Send (fire-and-forget)
        _sendBytes(message)
    }

    private func _sendBytes(_ bytes: [UInt8]) {
        #if !os(Windows)
        guard socketFD >= 0 else { return }

        bytes.withUnsafeBytes { buffer in
            var totalSent = 0
            while totalSent < bytes.count {
                let sent = Darwin.send(socketFD, buffer.baseAddress! + totalSent, bytes.count - totalSent, MSG_NOSIGNAL)
                if sent <= 0 {
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        return
                    }
                    _disconnect()
                    return
                }
                totalSent += sent
            }
        }
        #endif
    }

    /// Flush any buffered events
    public func flush() {
        // Events are sent immediately, nothing to flush
    }
}

// MARK: - MSG_NOSIGNAL Compatibility

#if canImport(Darwin)
private let MSG_NOSIGNAL: Int32 = 0
#endif

// MARK: - Convenience Extension

extension TelemetryClient {
    /// Send a build started event
    public func buildStarted(sessionID: String, configuration: String, targetCount: Int, action: String) {
        send(BuildStartedEvent(sessionID: sessionID, configuration: configuration, targetCount: targetCount, action: action))
    }

    /// Send a build completed event
    public func buildCompleted(sessionID: String, result: BuildResultStatus, durationNanos: UInt64, errorCount: Int = 0, warningCount: Int = 0) {
        send(BuildCompletedEvent(sessionID: sessionID, result: result, durationNanos: durationNanos, errorCount: errorCount, warningCount: warningCount))
    }

    /// Send a target started event
    public func targetStarted(sessionID: String, targetName: String, targetGUID: String) {
        send(TargetStartedEvent(sessionID: sessionID, targetName: targetName, targetGUID: targetGUID))
    }

    /// Send a target completed event
    public func targetCompleted(sessionID: String, targetName: String, targetGUID: String, result: BuildResultStatus, durationNanos: UInt64) {
        send(TargetCompletedEvent(sessionID: sessionID, targetName: targetName, targetGUID: targetGUID, result: result, durationNanos: durationNanos))
    }

    /// Send a task started event
    public func taskStarted(sessionID: String, taskSignature: String, taskType: String, targetName: String?, ruleInfo: String) {
        send(TaskStartedEvent(sessionID: sessionID, taskSignature: taskSignature, taskType: taskType, targetName: targetName, ruleInfo: ruleInfo))
    }

    /// Send a task completed event
    public func taskCompleted(sessionID: String, taskSignature: String, result: TaskResultStatus, durationNanos: UInt64, exitCode: Int? = nil) {
        send(TaskCompletedEvent(sessionID: sessionID, taskSignature: taskSignature, result: result, durationNanos: durationNanos, exitCode: exitCode))
    }

    /// Send a task up-to-date event
    public func taskUpToDate(sessionID: String, taskSignature: String, taskType: String, targetName: String?) {
        send(TaskUpToDateEvent(sessionID: sessionID, taskSignature: taskSignature, taskType: taskType, targetName: targetName))
    }

    /// Send a diagnostic event
    public func diagnosticEmitted(sessionID: String, severity: DiagnosticSeverity, message: String, filePath: String? = nil, line: Int? = nil, column: Int? = nil, taskSignature: String? = nil) {
        send(DiagnosticEmittedEvent(sessionID: sessionID, severity: severity, message: message, filePath: filePath, line: line, column: column, taskSignature: taskSignature))
    }

    /// Send a build progress event
    public func buildProgress(sessionID: String, totalTasks: Int, completedTasks: Int, runningTasks: Int, pendingTasks: Int) {
        send(BuildProgressEvent(sessionID: sessionID, totalTasks: totalTasks, completedTasks: completedTasks, runningTasks: runningTasks, pendingTasks: pendingTasks))
    }
}
