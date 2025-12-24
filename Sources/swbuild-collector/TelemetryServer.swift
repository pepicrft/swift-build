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
#endif

/// Server that listens for telemetry events on a Unix socket
final class TelemetryServer: @unchecked Sendable {
    let socketPath: String
    let buildStore: BuildStore
    let verbose: Bool

    private var serverFD: Int32 = -1
    private var isRunning = false

    init(socketPath: String, buildStore: BuildStore, verbose: Bool = false) {
        self.socketPath = socketPath
        self.buildStore = buildStore
        self.verbose = verbose
    }

    func start() async throws {
        // Remove existing socket file
        unlink(socketPath)

        // Create socket
        serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            throw TelemetryError.socketCreationFailed(errno: errno)
        }

        // Set socket options
        var reuseAddr: Int32 = 1
        setsockopt(serverFD, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))

        // Bind to address
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = socketPath.utf8
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard pathBytes.count < maxLen else {
            close(serverFD)
            throw TelemetryError.socketPathTooLong
        }

        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxLen) { dest in
                for (i, byte) in pathBytes.enumerated() {
                    dest[i] = CChar(bitPattern: byte)
                }
                dest[pathBytes.count] = 0
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            close(serverFD)
            throw TelemetryError.bindFailed(errno: errno)
        }

        // Listen for connections
        guard listen(serverFD, 10) == 0 else {
            close(serverFD)
            throw TelemetryError.listenFailed(errno: errno)
        }

        isRunning = true
        print("Telemetry server listening on \(socketPath)")

        // Accept connections
        while isRunning {
            let clientFD = accept(serverFD, nil, nil)
            if clientFD >= 0 {
                Task {
                    await handleClient(fd: clientFD)
                }
            } else if errno != EINTR {
                if verbose {
                    print("Accept failed: \(errno)")
                }
            }
        }
    }

    func stop() {
        isRunning = false
        if serverFD >= 0 {
            close(serverFD)
            serverFD = -1
        }
        unlink(socketPath)
    }

    private func handleClient(fd: Int32) async {
        defer { close(fd) }

        if verbose {
            print("Client connected")
        }

        var buffer = [UInt8](repeating: 0, count: 65536)

        while isRunning {
            // Read length prefix (4 bytes, little-endian)
            var lengthBytes = [UInt8](repeating: 0, count: 4)
            let lengthRead = recv(fd, &lengthBytes, 4, MSG_WAITALL)

            guard lengthRead == 4 else {
                if lengthRead <= 0 {
                    if verbose {
                        print("Client disconnected")
                    }
                }
                break
            }

            // Parse length (little-endian uint32)
            let payloadLength = Int(lengthBytes[0]) |
                               (Int(lengthBytes[1]) << 8) |
                               (Int(lengthBytes[2]) << 16) |
                               (Int(lengthBytes[3]) << 24)

            guard payloadLength > 0 && payloadLength < buffer.count else {
                if verbose {
                    print("Invalid payload length: \(payloadLength)")
                }
                continue
            }

            // Read payload
            let payloadRead = recv(fd, &buffer, payloadLength, MSG_WAITALL)

            guard payloadRead == payloadLength else {
                if verbose {
                    print("Failed to read full payload: got \(payloadRead), expected \(payloadLength)")
                }
                continue
            }

            // Decode MsgPack event
            let payloadSlice = ArraySlice(buffer[0..<payloadLength])
            await processEvent(payloadSlice)
        }
    }

    private func processEvent(_ payload: ArraySlice<UInt8>) async {
        let decoder = MsgPackDecoder(payload)

        // Read map
        guard let mapCount = decoder.readBeginMap() else {
            if verbose {
                print("Failed to read event map")
            }
            return
        }

        var eventData: [String: Any] = [:]

        for _ in 0..<mapCount {
            guard let key = decoder.readString() else { continue }

            // Read value based on expected type
            if let stringValue = decoder.readString() {
                eventData[key] = stringValue
            } else if let intValue = decoder.readInt64() {
                eventData[key] = intValue
            } else if let uintValue = decoder.readUInt64() {
                eventData[key] = uintValue
            } else if decoder.readNil() {
                eventData[key] = nil
            }
        }

        guard let eventType = eventData["type"] as? String else {
            if verbose {
                print("Event missing type field")
            }
            return
        }

        guard let sessionID = eventData["session_id"] as? String else {
            if verbose {
                print("Event missing session_id field")
            }
            return
        }

        if verbose {
            print("Received event: \(eventType) for session \(sessionID)")
        }

        // Handle event types
        switch eventType {
        case "build_started":
            let configuration = eventData["configuration"] as? String ?? ""
            let action = eventData["action"] as? String ?? "build"
            await buildStore.handleBuildStarted(sessionID: sessionID, configuration: configuration, action: action)

        case "build_completed":
            let result = eventData["result"] as? String ?? "unknown"
            let errorCount = (eventData["error_count"] as? Int64).map(Int.init) ?? 0
            let warningCount = (eventData["warning_count"] as? Int64).map(Int.init) ?? 0
            await buildStore.handleBuildCompleted(sessionID: sessionID, result: result, errorCount: errorCount, warningCount: warningCount)

        case "target_started":
            let targetName = eventData["target_name"] as? String ?? ""
            let targetGUID = eventData["target_guid"] as? String ?? ""
            await buildStore.handleTargetStarted(sessionID: sessionID, targetName: targetName, targetGUID: targetGUID)

        case "target_completed":
            let targetName = eventData["target_name"] as? String ?? ""
            let targetGUID = eventData["target_guid"] as? String ?? ""
            let result = eventData["result"] as? String ?? "unknown"
            await buildStore.handleTargetCompleted(sessionID: sessionID, targetName: targetName, targetGUID: targetGUID, result: result)

        case "task_started":
            let taskSignature = eventData["task_signature"] as? String ?? ""
            let taskType = eventData["task_type"] as? String ?? ""
            let targetName = eventData["target_name"] as? String
            let ruleInfo = eventData["rule_info"] as? String ?? ""
            await buildStore.handleTaskStarted(sessionID: sessionID, taskSignature: taskSignature, taskType: taskType, targetName: targetName, ruleInfo: ruleInfo)

        case "task_completed":
            let taskSignature = eventData["task_signature"] as? String ?? ""
            let result = eventData["result"] as? String ?? "unknown"
            let exitCode = (eventData["exit_code"] as? Int64).map(Int.init)
            await buildStore.handleTaskCompleted(sessionID: sessionID, taskSignature: taskSignature, result: result, exitCode: exitCode)

        case "task_up_to_date":
            let taskSignature = eventData["task_signature"] as? String ?? ""
            let taskType = eventData["task_type"] as? String ?? ""
            let targetName = eventData["target_name"] as? String
            await buildStore.handleTaskUpToDate(sessionID: sessionID, taskSignature: taskSignature, taskType: taskType, targetName: targetName)

        default:
            if verbose {
                print("Unknown event type: \(eventType)")
            }
        }
    }
}

// MARK: - MsgPack Decoder (simplified)

/// Simple MsgPack decoder for reading telemetry events
final class MsgPackDecoder {
    private let bytes: ArraySlice<UInt8>
    private var position: Int

    init(_ bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
        self.position = bytes.startIndex
    }

    private func readByte() -> UInt8? {
        guard position < bytes.endIndex else { return nil }
        let byte = bytes[position]
        position += 1
        return byte
    }

    private func readBytes(_ count: Int) -> [UInt8]? {
        guard position + count <= bytes.endIndex else { return nil }
        let result = Array(bytes[position..<(position + count)])
        position += count
        return result
    }

    func readNil() -> Bool {
        guard let byte = readByte() else { return false }
        if byte == 0xc0 {
            return true
        }
        position -= 1
        return false
    }

    func readInt64() -> Int64? {
        guard let byte = readByte() else { return nil }

        switch byte {
        case 0xd3: // int64
            guard let data = readBytes(8) else { return nil }
            var value: Int64 = 0
            for b in data {
                value = (value << 8) | Int64(b)
            }
            return value
        default:
            position -= 1
            return nil
        }
    }

    func readUInt64() -> UInt64? {
        guard let byte = readByte() else { return nil }

        switch byte {
        case 0xcf: // uint64
            guard let data = readBytes(8) else { return nil }
            var value: UInt64 = 0
            for b in data {
                value = (value << 8) | UInt64(b)
            }
            return value
        default:
            position -= 1
            return nil
        }
    }

    func readString() -> String? {
        guard let byte = readByte() else { return nil }

        let length: Int
        switch byte {
        case let b where (b & 0b1110_0000) == 0b1010_0000: // fixstr
            length = Int(b & 0b0001_1111)
        case 0xd9: // str8
            guard let len = readByte() else { return nil }
            length = Int(len)
        case 0xda: // str16
            guard let data = readBytes(2) else { return nil }
            length = (Int(data[0]) << 8) | Int(data[1])
        case 0xdb: // str32
            guard let data = readBytes(4) else { return nil }
            length = (Int(data[0]) << 24) | (Int(data[1]) << 16) | (Int(data[2]) << 8) | Int(data[3])
        default:
            position -= 1
            return nil
        }

        guard let data = readBytes(length) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func readBeginMap() -> Int? {
        guard let byte = readByte() else { return nil }

        switch byte {
        case let b where (b & 0b1111_0000) == 0b1000_0000: // fixmap
            return Int(b & 0b0000_1111)
        case 0xde: // map16
            guard let data = readBytes(2) else { return nil }
            return (Int(data[0]) << 8) | Int(data[1])
        case 0xdf: // map32
            guard let data = readBytes(4) else { return nil }
            return (Int(data[0]) << 24) | (Int(data[1]) << 16) | (Int(data[2]) << 8) | Int(data[3])
        default:
            position -= 1
            return nil
        }
    }
}

// MARK: - Errors

enum TelemetryError: Error {
    case socketCreationFailed(errno: Int32)
    case socketPathTooLong
    case bindFailed(errno: Int32)
    case listenFailed(errno: Int32)
}
