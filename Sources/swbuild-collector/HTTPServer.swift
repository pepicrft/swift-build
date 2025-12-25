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

/// Represents a detected coding agent
struct CodingAgent {
    let id: String
    let name: String
    let command: String

    func toJSON() -> [String: Any] {
        return [
            "id": id,
            "name": name,
            "command": command
        ]
    }
}

/// Actor to manage running explain processes
actor ExplainProcessManager {
    private var processes: [String: Process] = [:]

    func register(_ process: Process, id: String) {
        processes[id] = process
    }

    func unregister(id: String) {
        processes.removeValue(forKey: id)
    }

    func cancel(id: String) -> Bool {
        if let process = processes[id] {
            if process.isRunning {
                process.terminate()
            }
            processes.removeValue(forKey: id)
            return true
        }
        return false
    }
}

/// Simple HTTP server for the web UI
final class HTTPServer: @unchecked Sendable {
    let port: Int
    let buildStore: BuildStore

    private var serverFD: Int32 = -1
    private var isRunning = false

    /// Cached list of detected agents
    private var detectedAgents: [CodingAgent] = []

    /// Track running explain processes for cancellation
    private let processManager = ExplainProcessManager()

    init(port: Int, buildStore: BuildStore) {
        self.port = port
        self.buildStore = buildStore
        self.detectedAgents = Self.detectAgents()
    }

    /// Detect available coding agents on the system
    private static func detectAgents() -> [CodingAgent] {
        var agents: [CodingAgent] = []

        let agentDefinitions: [(id: String, name: String, commands: [String])] = [
            ("claude", "Claude Code", ["claude"]),
            ("codex", "OpenAI Codex", ["codex"]),
            ("cursor", "Cursor", ["cursor"]),
            ("copilot", "GitHub Copilot", ["gh copilot"]),
            ("aider", "Aider", ["aider"]),
            ("cody", "Sourcegraph Cody", ["cody"]),
        ]

        for (id, name, commands) in agentDefinitions {
            for command in commands {
                if isCommandAvailable(command.split(separator: " ").first.map(String.init) ?? command) {
                    agents.append(CodingAgent(id: id, name: name, command: command))
                    break
                }
            }
        }

        return agents
    }

    /// Check if a command is available in PATH
    private static func isCommandAvailable(_ command: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    func start() async throws {
        // Create socket
        serverFD = socket(AF_INET, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            throw HTTPError.socketCreationFailed(errno: errno)
        }

        // Set socket options
        var reuseAddr: Int32 = 1
        setsockopt(serverFD, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))

        // Bind to address
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            close(serverFD)
            throw HTTPError.bindFailed(errno: errno)
        }

        // Listen for connections
        guard listen(serverFD, 50) == 0 else {
            close(serverFD)
            throw HTTPError.listenFailed(errno: errno)
        }

        isRunning = true
        print("HTTP server listening on http://localhost:\(port)")

        // Accept connections
        while isRunning {
            let clientFD = accept(serverFD, nil, nil)
            if clientFD >= 0 {
                Task {
                    await handleClient(fd: clientFD)
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
    }

    private func handleClient(fd: Int32) async {
        defer { close(fd) }

        // Read request
        var buffer = [UInt8](repeating: 0, count: 8192)
        let bytesRead = recv(fd, &buffer, buffer.count - 1, 0)

        guard bytesRead > 0 else { return }

        let requestString = String(decoding: buffer[0..<bytesRead], as: UTF8.self)
        let lines = requestString.split(separator: "\r\n")

        guard let firstLine = lines.first else { return }
        let parts = firstLine.split(separator: " ")

        guard parts.count >= 2 else { return }

        let method = String(parts[0])
        let path = String(parts[1])

        // Extract body for POST requests
        var body = ""
        if method == "POST" {
            // Find the empty line that separates headers from body
            if let bodyStart = requestString.range(of: "\r\n\r\n") {
                body = String(requestString[bodyStart.upperBound...])
            }
        }

        // Route request
        let response: HTTPResponse
        if method == "GET" {
            response = await handleGET(path: path)
        } else if method == "POST" {
            response = await handlePOST(path: path, body: body)
        } else {
            response = HTTPResponse(status: 405, contentType: "text/plain", body: "Method Not Allowed")
        }

        // Send response
        let responseString = response.toString()
        _ = responseString.withCString { ptr in
            send(fd, ptr, strlen(ptr), 0)
        }
    }

    private func handleGET(path: String) async -> HTTPResponse {
        switch path {
        case "/":
            return HTTPResponse(status: 200, contentType: "text/html", body: generateHTML())

        case "/api/builds":
            let builds = await buildStore.getAllBuilds()
            return jsonResponse(builds.map { $0.toJSON() })

        case "/api/builds/current":
            if let build = await buildStore.getCurrentBuild() {
                return jsonResponse(build.toJSON())
            } else {
                return jsonResponse(nil as [String: Any]?)
            }

        case let p where p.hasPrefix("/api/builds/"):
            let sessionID = String(p.dropFirst("/api/builds/".count))
            if let build = await buildStore.getBuild(sessionID: sessionID) {
                return jsonResponse(build.toJSON())
            } else {
                return HTTPResponse(status: 404, contentType: "application/json", body: "{\"error\": \"Build not found\"}")
            }

        case "/api/events":
            // Server-Sent Events endpoint for real-time updates
            return HTTPResponse(
                status: 200,
                contentType: "text/event-stream",
                headers: ["Cache-Control": "no-cache", "Connection": "keep-alive"],
                body: "event: ping\ndata: connected\n\n"
            )

        case "/api/agents":
            return jsonResponse(detectedAgents.map { $0.toJSON() })

        default:
            return HTTPResponse(status: 404, contentType: "text/plain", body: "Not Found")
        }
    }

    private func handlePOST(path: String, body: String) async -> HTTPResponse {
        switch path {
        case "/api/explain":
            return await handleExplainRequest(body: body)
        case "/api/explain/cancel":
            return await handleCancelExplain(body: body)
        default:
            return HTTPResponse(status: 404, contentType: "text/plain", body: "Not Found")
        }
    }

    private func handleCancelExplain(body: String) async -> HTTPResponse {
        guard let jsonData = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let requestId = json["requestId"] as? String else {
            return HTTPResponse(status: 400, contentType: "application/json", body: "{\"error\": \"Invalid request body\"}")
        }

        let cancelled = await processManager.cancel(id: requestId)
        return jsonResponse(["cancelled": cancelled])
    }

    private func handleExplainRequest(body: String) async -> HTTPResponse {
        // Parse the request body
        guard let jsonData = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let agentId = json["agentId"] as? String,
              let itemType = json["type"] as? String,
              let itemName = json["name"] as? String else {
            return HTTPResponse(status: 400, contentType: "application/json", body: "{\"error\": \"Invalid request body\"}")
        }

        // Get or generate request ID for cancellation support
        let requestId = json["requestId"] as? String ?? UUID().uuidString

        // Find the agent
        guard let agent = detectedAgents.first(where: { $0.id == agentId }) else {
            return HTTPResponse(status: 400, contentType: "application/json", body: "{\"error\": \"Agent not found\"}")
        }

        // Build context from additional info
        let ruleInfo = json["ruleInfo"] as? String ?? ""
        let taskType = json["taskType"] as? String ?? ""
        let signature = json["signature"] as? String ?? ""
        let filePaths = json["filePaths"] as? [String] ?? []
        let taskCount = json["taskCount"] as? Int ?? 0
        let taskTypes = json["taskTypes"] as? [String] ?? []
        let directories = json["directories"] as? [String] ?? []
        let exampleFiles = json["exampleFiles"] as? [String] ?? []

        // Build the prompt with rich context
        let prompt: String
        if itemType == "task" {
            var context = """
            Explain this Xcode build task in simple terms (2-3 sentences max):

            Task: \(itemName)
            Type: \(taskType.isEmpty ? "N/A" : taskType)
            """
            if !ruleInfo.isEmpty {
                context += "\nFull command: \(ruleInfo)"
            }
            if !filePaths.isEmpty {
                context += "\nFile paths involved:\n" + filePaths.map { "  - \($0)" }.joined(separator: "\n")
            }
            if !signature.isEmpty && signature.count < 200 {
                context += "\nSignature: \(signature)"
            }
            context += """

            You can use your tools to read these files if needed for more context.
            What does this task do in the context of building an iOS/macOS app?
            """
            prompt = context
        } else {
            var context = """
            Explain this Xcode build target in simple terms (2-3 sentences max):

            Target: \(itemName)
            Task count: \(taskCount)
            """
            if !taskTypes.isEmpty {
                context += "\nTask types in this target: \(taskTypes.joined(separator: ", "))"
            }
            if !directories.isEmpty {
                context += "\nSource directories:\n" + directories.map { "  - \($0)" }.joined(separator: "\n")
            }
            if !exampleFiles.isEmpty {
                context += "\nExample files:\n" + exampleFiles.map { "  - \($0)" }.joined(separator: "\n")
            }
            context += """

            You can use your tools to explore these directories or read files if needed.
            What is this target's purpose in an iOS/macOS project?
            """
            prompt = context
        }

        // Invoke the agent
        let explanation = await invokeAgent(agent: agent, prompt: prompt, requestId: requestId)
        return jsonResponse(["explanation": explanation, "requestId": requestId])
    }

    private func invokeAgent(agent: CodingAgent, prompt: String, requestId: String) async -> String {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        // Determine the command to run
        let commandParts = agent.command.split(separator: " ")
        let executable = String(commandParts.first ?? "")

        // Find the full path using which
        let whichProcess = Process()
        let whichPipe = Pipe()
        whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProcess.arguments = [executable]
        whichProcess.standardOutput = whichPipe
        whichProcess.standardError = FileHandle.nullDevice

        do {
            try whichProcess.run()
            whichProcess.waitUntilExit()
        } catch {
            return "Could not find \(agent.name) executable."
        }

        let whichData = whichPipe.fileHandleForReading.readDataToEndOfFile()
        let executablePath = String(data: whichData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !executablePath.isEmpty else {
            return "Could not find \(agent.name) executable."
        }

        process.executableURL = URL(fileURLWithPath: executablePath)

        // Build arguments based on agent type
        switch agent.id {
        case "claude":
            process.arguments = ["--print", prompt]
        case "codex":
            process.arguments = ["--prompt", prompt]
        case "aider":
            process.arguments = ["--message", prompt, "--yes"]
        default:
            // Generic fallback
            process.arguments = [prompt]
        }

        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // Register process for cancellation
        await processManager.register(process, id: requestId)

        defer {
            // Cleanup: remove process from tracking
            Task {
                await processManager.unregister(id: requestId)
            }
        }

        do {
            try process.run()

            // Set a timeout
            let deadline = DispatchTime.now() + .seconds(30)
            DispatchQueue.global().asyncAfter(deadline: deadline) { [weak process] in
                if let p = process, p.isRunning {
                    p.terminate()
                }
            }

            process.waitUntilExit()
        } catch {
            return "Failed to run \(agent.name): \(error.localizedDescription)"
        }

        // Check if process was terminated (cancelled)
        if process.terminationStatus == 15 || process.terminationStatus == 9 {
            return "Request cancelled"
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if output.isEmpty {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !errorOutput.isEmpty {
                return "Error from \(agent.name): \(errorOutput)"
            }
            return "No response from \(agent.name)"
        }

        return output
    }

    private func jsonResponse(_ data: Any?) -> HTTPResponse {
        guard let data = data else {
            return HTTPResponse(status: 200, contentType: "application/json", body: "null")
        }

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
            return HTTPResponse(status: 200, contentType: "application/json", body: jsonString)
        } catch {
            return HTTPResponse(status: 500, contentType: "application/json", body: "{\"error\": \"JSON serialization failed\"}")
        }
    }

    private func generateHTML() -> String {
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>Swift Build Monitor</title>
            <script src="https://cdn.tailwindcss.com"></script>
            <script src="https://unpkg.com/react@18/umd/react.production.min.js" crossorigin></script>
            <script src="https://unpkg.com/react-dom@18/umd/react-dom.production.min.js" crossorigin></script>
            <script src="https://unpkg.com/@babel/standalone/babel.min.js"></script>
            <script>
                tailwind.config = {
                    theme: {
                        extend: {
                            colors: {
                                background: 'hsl(0 0% 100%)',
                                foreground: 'hsl(240 10% 3.9%)',
                                card: { DEFAULT: 'hsl(0 0% 100%)', foreground: 'hsl(240 10% 3.9%)' },
                                popover: { DEFAULT: 'hsl(0 0% 100%)', foreground: 'hsl(240 10% 3.9%)' },
                                primary: { DEFAULT: 'hsl(240 5.9% 10%)', foreground: 'hsl(0 0% 98%)' },
                                secondary: { DEFAULT: 'hsl(240 4.8% 95.9%)', foreground: 'hsl(240 5.9% 10%)' },
                                muted: { DEFAULT: 'hsl(240 4.8% 95.9%)', foreground: 'hsl(240 3.8% 46.1%)' },
                                accent: { DEFAULT: 'hsl(240 4.8% 95.9%)', foreground: 'hsl(240 5.9% 10%)' },
                                destructive: { DEFAULT: 'hsl(0 84.2% 60.2%)', foreground: 'hsl(0 0% 98%)' },
                                border: 'hsl(240 5.9% 90%)',
                                input: 'hsl(240 5.9% 90%)',
                                ring: 'hsl(240 5.9% 10%)',
                                chart: {
                                    '1': 'hsl(220 70% 50%)',
                                    '2': 'hsl(160 60% 45%)',
                                    '3': 'hsl(30 80% 55%)',
                                    '4': 'hsl(280 65% 60%)',
                                    '5': 'hsl(340 75% 55%)',
                                },
                            },
                            borderRadius: { lg: '0.5rem', md: 'calc(0.5rem - 2px)', sm: 'calc(0.5rem - 4px)' },
                        }
                    }
                }
            </script>
            <style>
                @keyframes pulse-slow { 0%, 100% { opacity: 1; } 50% { opacity: 0.5; } }
                .animate-pulse-slow { animation: pulse-slow 2s ease-in-out infinite; }
                @keyframes slide-down { from { height: 0; } to { height: var(--radix-collapsible-content-height); } }
                @keyframes slide-up { from { height: var(--radix-collapsible-content-height); } to { height: 0; } }
                .collapsible-content[data-state="open"] { animation: slide-down 200ms ease-out; }
                .collapsible-content[data-state="closed"] { animation: slide-up 200ms ease-out; }
                .scrollbar-thin::-webkit-scrollbar { width: 6px; height: 6px; }
                .scrollbar-thin::-webkit-scrollbar-track { background: transparent; }
                .scrollbar-thin::-webkit-scrollbar-thumb { background: hsl(240 5.9% 85%); border-radius: 3px; }
                .scrollbar-thin::-webkit-scrollbar-thumb:hover { background: hsl(240 5.9% 75%); }
            </style>
        </head>
        <body class="bg-background text-foreground min-h-screen antialiased">
            <div id="root"></div>
            <script type="text/babel">
                const { useState, useEffect, useCallback, useMemo, useRef } = React;

                // Utilities
                const formatDuration = (seconds) => {
                    if (!seconds && seconds !== 0) return '-';
                    if (seconds < 0.001) return '<1ms';
                    if (seconds < 1) return Math.round(seconds * 1000) + 'ms';
                    if (seconds < 60) return seconds.toFixed(1) + 's';
                    const mins = Math.floor(seconds / 60);
                    const secs = Math.round(seconds % 60);
                    return mins + 'm ' + secs + 's';
                };

                const formatTime = (isoString) => {
                    if (!isoString) return '-';
                    return new Date(isoString).toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', second: '2-digit' });
                };

                // Helper to remove trailing backslashes (from escaped spaces in paths)
                // Uses String.fromCharCode to avoid escaping complexity in nested Swift/JS strings
                const BS = String.fromCharCode(92); // backslash character
                const removeTrailingBS = (s) => {
                    if (!s) return '';
                    while (s.endsWith(BS)) {
                        s = s.slice(0, -1);
                    }
                    return s;
                };

                const formatTimeShort = (isoString) => {
                    if (!isoString) return '-';
                    return new Date(isoString).toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit' });
                };

                // Human-readable rule name mapping
                const ruleNameMap = {
                    'WriteAuxiliaryFile': 'Write Support File',
                    'MkDir': 'Create Directory',
                    'CreateBuildDirectory': 'Create Build Directory',
                    'CompileC': 'Compile C/Objective-C',
                    'CompileSwift': 'Compile Swift',
                    'CompileSwiftSources': 'Compile Swift Sources',
                    'SwiftDriver': 'Swift Driver',
                    'SwiftCompile': 'Swift Compile',
                    'SwiftEmitModule': 'Emit Swift Module',
                    'SwiftMergeGeneratedHeaders': 'Merge Swift Headers',
                    'Ld': 'Link Binary',
                    'Libtool': 'Create Static Library',
                    'CpHeader': 'Copy Header',
                    'Copy': 'Copy File',
                    'CopySwiftLibs': 'Copy Swift Libraries',
                    'CopyPNGFile': 'Copy PNG',
                    'CopyStringsFile': 'Copy Strings',
                    'CpResource': 'Copy Resource',
                    'ProcessInfoPlistFile': 'Process Info.plist',
                    'ProcessProductPackaging': 'Process Packaging',
                    'ProcessProductPackagingDER': 'Process DER Packaging',
                    'CodeSign': 'Code Sign',
                    'ValidateEmbeddedBinary': 'Validate Embedded Binary',
                    'Touch': 'Update Timestamp',
                    'RegisterExecutionPolicyException': 'Register Security Exception',
                    'RegisterWithLaunchServices': 'Register with Launch Services',
                    'ExtractAppIntentsMetadata': 'Extract App Intents',
                    'AppIntentsSSUTraining': 'Train App Intents',
                    'LinkAssetCatalog': 'Link Asset Catalog',
                    'LinkAssetCatalogSignature': 'Sign Asset Catalog',
                    'CompileAssetCatalog': 'Compile Assets',
                    'CompileStoryboard': 'Compile Storyboard',
                    'CompileXIB': 'Compile XIB',
                    'LinkStoryboards': 'Link Storyboards',
                    'ProcessXCFramework': 'Process XCFramework',
                    'GenerateDSYMFile': 'Generate Debug Symbols',
                    'Strip': 'Strip Binary',
                    'SetOwnerAndGroup': 'Set Permissions',
                    'SetMode': 'Set File Mode',
                    'Ditto': 'Copy with Ditto',
                    'PBXCp': 'Copy Files',
                    'PhaseScriptExecution': 'Run Script',
                    'Gate': 'Build Gate',
                    'ClangStatCache': 'Clang Stats Cache',
                    'SwiftExplicitDependencyCompileModuleFromInterface': 'Compile Swift Module Interface',
                    'SwiftExplicitDependencyGeneratePcm': 'Generate PCM',
                    'WriteFile': 'Write',
                    'Copy': 'Copy',
                    'CpResource': 'Copy Resource',
                    'MkDir': 'Create Directory',
                    'Mkdir': 'Create Directory',
                    'CreateBuildDirectory': 'Create Build Directory',
                    'CopyAndPreserveArchs': 'Copy Framework',
                    'CompileAssetCatalogVariant': 'Compile Assets',
                    'ProcessInfoPlistFile': 'Process Info.plist',
                    'ProcessProductPackaging': 'Process Entitlements',
                    'ProcessProductPackagingDER': 'Process Entitlements DER',
                    'SwiftCompile': 'Swift Compile',
                    'SwiftDriver': 'Swift Driver',
                    'SwiftEmitModule': 'Swift Emit Module',
                    'SwiftMergeGeneratedHeaders': 'Swift Merge Headers',
                    'CpHeader': 'Copy Header',
                };

                const getReadableRuleName = (ruleInfo, taskType) => {
                    if (!ruleInfo && !taskType) return 'Task';
                    const parts = ruleInfo ? ruleInfo.split(' ') : [];
                    const ruleName = parts[0] || taskType;
                    const readableName = ruleNameMap[ruleName] || ruleName || 'Task';

                    // For generic tasks, try to extract a meaningful filename
                    const genericRules = [
                        'WriteFile', 'WriteAuxiliaryFile', 'Copy', 'CpResource', 'Touch',
                        'MkDir', 'Mkdir', 'CreateBuildDirectory', 'PBXCp', 'Ditto',
                        'CopyPlistFile', 'CopyStringsFile', 'CopyPNGFile', 'CpHeader',
                        'CopyAndPreserveArchs', 'CompileAssetCatalogVariant',
                        'LinkAssetCatalog', 'LinkAssetCatalogSignature',
                        'ProcessInfoPlistFile', 'RegisterExecutionPolicyException',
                        'CompileAssetCatalog', 'ProcessProductPackaging',
                        'ProcessProductPackagingDER', 'CodeSign', 'ValidateEmbeddedBinary',
                        'CompileXIB', 'CompileStoryboard', 'LinkStoryboards',
                        'CompileC', 'CompileSwift', 'CompileSwiftSources',
                        'Ld', 'Libtool', 'GenerateDSYMFile', 'Strip',
                        'SwiftCompile', 'SwiftDriver', 'SwiftEmitModule', 'SwiftMergeGeneratedHeaders'
                    ];
                    if (genericRules.includes(ruleName)) {
                        // Special handling for SwiftCompile - extract first .swift file from "Compiling X.swift, Y.swift"
                        if (ruleName === 'SwiftCompile') {
                            const match = ruleInfo.match(/Compiling[\\\\]?\\s+([^,\\\\]+\\.swift)/);
                            if (match) {
                                return `${readableName}: ${match[1]}`;
                            }
                        }
                        // Special handling for SwiftDriver - extract module name
                        if (ruleName === 'SwiftDriver') {
                            // Format: SwiftDriver ModuleName normal arm64 ...
                            if (parts[1] && !parts[1].includes('/')) {
                                const moduleName = removeTrailingBS(parts[1]);
                                return `${readableName}: ${moduleName}`;
                            }
                        }
                        // Special handling for SwiftEmitModule - extract module name
                        if (ruleName === 'SwiftEmitModule') {
                            // Format: SwiftEmitModule normal arm64 Emitting module for ModuleName
                            // Or: SwiftEmitModule ModuleName normal arm64
                            const match = ruleInfo.match(/Emitting\\s+module\\s+for\\s*(\\w+)/i);
                            if (match) {
                                return `${readableName}: ${match[1]}`;
                            }
                            // Fallback: check if second part is the module name
                            if (parts[1] && !parts[1].includes('/') && !['normal', 'debug', 'release'].includes(parts[1].toLowerCase())) {
                                const moduleName = removeTrailingBS(parts[1]);
                                return `${readableName}: ${moduleName}`;
                            }
                        }
                        // Special handling for LinkStoryboards - extract storyboard name
                        if (ruleName === 'LinkStoryboards') {
                            // Format: LinkStoryboards /path/to/Something.storyboardc
                            const storyboardPath = parts.find(p => p.includes('.storyboard'));
                            if (storyboardPath) {
                                let fileName = storyboardPath.split('/').pop() || '';
                                fileName = removeTrailingBS(fileName);
                                // Remove trailing 'c' from .storyboardc
                                if (fileName.endsWith('.storyboardc')) {
                                    fileName = fileName.slice(0, -1);
                                }
                                if (fileName) {
                                    return `${readableName}: ${fileName}`;
                                }
                            }
                        }
                        // Find the first path in ruleInfo (handle escaped spaces)
                        const pathPart = parts.slice(1).find(p => p.includes('/'));
                        if (pathPart) {
                            // Remove trailing backslash from escaped spaces and get filename
                            const fileName = removeTrailingBS(pathPart.split('/').pop() || '');
                            if (fileName) {
                                return `${readableName}: ${fileName}`;
                            }
                        }
                    }

                    return readableName;
                };

                // Icons
                const ChevronRight = ({ className }) => (
                    <svg className={className} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                        <path strokeLinecap="round" strokeLinejoin="round" d="M9 5l7 7-7 7" />
                    </svg>
                );

                const ChevronDown = ({ className }) => (
                    <svg className={className} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                        <path strokeLinecap="round" strokeLinejoin="round" d="M19 9l-7 7-7-7" />
                    </svg>
                );

                const Clock = ({ className }) => (
                    <svg className={className} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                        <circle cx="12" cy="12" r="10" /><path d="M12 6v6l4 2" />
                    </svg>
                );

                const CheckCircle = ({ className }) => (
                    <svg className={className} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                        <path strokeLinecap="round" strokeLinejoin="round" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z" />
                    </svg>
                );

                const XCircle = ({ className }) => (
                    <svg className={className} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                        <path strokeLinecap="round" strokeLinejoin="round" d="M10 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2m7-2a9 9 0 11-18 0 9 9 0 0118 0z" />
                    </svg>
                );

                const Loader = ({ className }) => (
                    <svg className={className + ' animate-spin'} fill="none" viewBox="0 0 24 24">
                        <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
                        <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z" />
                    </svg>
                );

                const Package = ({ className }) => (
                    <svg className={className} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                        <path strokeLinecap="round" strokeLinejoin="round" d="M20 7l-8-4-8 4m16 0l-8 4m8-4v10l-8 4m0-10L4 7m8 4v10M4 7v10l8 4" />
                    </svg>
                );

                const Layers = ({ className }) => (
                    <svg className={className} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                        <path strokeLinecap="round" strokeLinejoin="round" d="M12 2L2 7l10 5 10-5-10-5zM2 17l10 5 10-5M2 12l10 5 10-5" />
                    </svg>
                );

                const QuestionMark = ({ className }) => (
                    <svg className={className} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                        <path strokeLinecap="round" strokeLinejoin="round" d="M8.228 9c.549-1.165 2.03-2 3.772-2 2.21 0 4 1.343 4 3 0 1.4-1.278 2.575-3.006 2.907-.542.104-.994.54-.994 1.093m0 3h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
                    </svg>
                );

                // Badge Component
                const Badge = ({ children, variant = 'default', className = '' }) => {
                    const variants = {
                        default: 'bg-primary text-primary-foreground',
                        secondary: 'bg-secondary text-secondary-foreground border-border',
                        destructive: 'bg-red-100 text-red-700 border-red-200',
                        outline: 'border border-border bg-transparent',
                        success: 'bg-emerald-100 text-emerald-700 border-emerald-200',
                        warning: 'bg-amber-100 text-amber-700 border-amber-200',
                        info: 'bg-blue-100 text-blue-700 border-blue-200',
                    };
                    return (
                        <span className={`inline-flex items-center rounded-md border px-2 py-0.5 text-xs font-medium transition-colors ${variants[variant]} ${className}`}>
                            {children}
                        </span>
                    );
                };

                // Status Badge with icon
                const StatusBadge = ({ status, size = 'default' }) => {
                    const config = {
                        running: { variant: 'info', icon: Loader, label: 'Building' },
                        succeeded: { variant: 'success', icon: CheckCircle, label: 'Succeeded' },
                        failed: { variant: 'destructive', icon: XCircle, label: 'Failed' },
                        cancelled: { variant: 'secondary', icon: XCircle, label: 'Cancelled' },
                        pending: { variant: 'secondary', icon: Clock, label: 'Pending' },
                        cached: { variant: 'outline', icon: CheckCircle, label: 'Cached' },
                    };
                    const { variant, icon: Icon, label } = config[status] || config.pending;
                    const sizeClass = size === 'sm' ? 'text-[10px] px-1.5 py-0' : '';
                    return (
                        <Badge variant={variant} className={`gap-1 ${status === 'running' ? 'animate-pulse-slow' : ''} ${sizeClass}`}>
                            <Icon className={size === 'sm' ? 'h-2.5 w-2.5' : 'h-3 w-3'} />
                            {label}
                        </Badge>
                    );
                };

                // Progress Bar
                const Progress = ({ value, className = '' }) => (
                    <div className={`relative h-1.5 w-full overflow-hidden rounded-full bg-secondary ${className}`}>
                        <div className="h-full bg-primary transition-all duration-300 ease-out" style={{ width: `${Math.min(100, Math.max(0, value))}%` }} />
                    </div>
                );

                // Card Components
                const Card = ({ children, className = '' }) => (
                    <div className={`rounded-lg border border-border bg-card text-card-foreground shadow-sm ${className}`}>{children}</div>
                );
                const CardHeader = ({ children, className = '' }) => (
                    <div className={`flex flex-col space-y-1.5 p-4 ${className}`}>{children}</div>
                );
                const CardTitle = ({ children, className = '' }) => (
                    <h3 className={`font-semibold leading-none tracking-tight ${className}`}>{children}</h3>
                );
                const CardDescription = ({ children, className = '' }) => (
                    <p className={`text-sm text-muted-foreground ${className}`}>{children}</p>
                );
                const CardContent = ({ children, className = '' }) => (
                    <div className={`p-4 pt-0 ${className}`}>{children}</div>
                );

                // Color palette for targets (distinct, accessible colors)
                const TARGET_COLORS = [
                    { bg: 'rgb(59, 130, 246)', light: 'rgba(59, 130, 246, 0.2)', name: 'blue' },
                    { bg: 'rgb(16, 185, 129)', light: 'rgba(16, 185, 129, 0.2)', name: 'emerald' },
                    { bg: 'rgb(249, 115, 22)', light: 'rgba(249, 115, 22, 0.2)', name: 'orange' },
                    { bg: 'rgb(139, 92, 246)', light: 'rgba(139, 92, 246, 0.2)', name: 'violet' },
                    { bg: 'rgb(236, 72, 153)', light: 'rgba(236, 72, 153, 0.2)', name: 'pink' },
                    { bg: 'rgb(20, 184, 166)', light: 'rgba(20, 184, 166, 0.2)', name: 'teal' },
                    { bg: 'rgb(245, 158, 11)', light: 'rgba(245, 158, 11, 0.2)', name: 'amber' },
                    { bg: 'rgb(99, 102, 241)', light: 'rgba(99, 102, 241, 0.2)', name: 'indigo' },
                    { bg: 'rgb(244, 63, 94)', light: 'rgba(244, 63, 94, 0.2)', name: 'rose' },
                    { bg: 'rgb(34, 197, 94)', light: 'rgba(34, 197, 94, 0.2)', name: 'green' },
                    { bg: 'rgb(168, 85, 247)', light: 'rgba(168, 85, 247, 0.2)', name: 'purple' },
                    { bg: 'rgb(6, 182, 212)', light: 'rgba(6, 182, 212, 0.2)', name: 'cyan' },
                ];

                // Parallelism Timeline Component (like Xcode Build Timeline)
                const ParallelismTimeline = function(props) {
                    const build = props.build;
                    const targetColors = props.targetColors || {};
                    const scrollRef = useRef(null);
                    const userScrolledRef = useRef(false);
                    const lastScrollLeftRef = useRef(0);

                    // Save scroll position before updates
                    var saveScrollPosition = function() {
                        var el = scrollRef.current;
                        if (el) {
                            lastScrollLeftRef.current = el.scrollLeft;
                        }
                    };

                    // Restore scroll position after render (unless user is following the end)
                    useEffect(function() {
                        var el = scrollRef.current;
                        if (!el) return;

                        if (userScrolledRef.current) {
                            // User has scrolled, restore their position
                            el.scrollLeft = lastScrollLeftRef.current;
                        }
                        // If user hasn't scrolled yet, don't force any scroll position
                    });

                    // Track when user manually scrolls
                    var handleScroll = function() {
                        var el = scrollRef.current;
                        if (el) {
                            // Mark that user has interacted with scroll
                            userScrolledRef.current = true;
                            lastScrollLeftRef.current = el.scrollLeft;
                        }
                    };

                    // Create a stable key for memoization based on task count and timing
                    const buildKey = useMemo(function() {
                        if (!build || !build.targets) return '';
                        var taskCount = 0;
                        var latestEnd = 0;
                        for (var i = 0; i < build.targets.length; i++) {
                            var tasks = build.targets[i].tasks || [];
                            taskCount += tasks.length;
                            for (var j = 0; j < tasks.length; j++) {
                                if (tasks[j].endTime) {
                                    var end = new Date(tasks[j].endTime).getTime();
                                    if (end > latestEnd) latestEnd = end;
                                }
                            }
                        }
                        return taskCount + ':' + latestEnd + ':' + build.targets.length;
                    }, [build]);

                    // Memoize heavy timeline computation
                    const timelineData = useMemo(function() {
                        if (!build || !build.targets || build.targets.length === 0) return null;

                        var tasks = [];
                        var colors = targetColors;

                        for (var ti = 0; ti < build.targets.length; ti++) {
                            var target = build.targets[ti];
                            var color = colors[target.name] || TARGET_COLORS[0];
                            var targetTasks = target.tasks || [];
                            for (var j = 0; j < targetTasks.length; j++) {
                                var task = targetTasks[j];
                                if (task.startTime) {
                                    tasks.push({
                                        id: ti + '-' + j,
                                        name: getReadableRuleName(task.ruleInfo, task.type),
                                        targetName: target.name,
                                        color: color,
                                        status: task.status,
                                        cached: task.status === 'cached',
                                        start: new Date(task.startTime).getTime(),
                                        end: task.endTime ? new Date(task.endTime).getTime() : Date.now(),
                                    });
                                }
                            }
                        }

                        if (tasks.length === 0) return null;

                        var timestamps = tasks.map(function(t) { return t.start; }).concat(tasks.map(function(t) { return t.end; }));
                        var minT = Math.min.apply(null, timestamps);
                        var maxT = Math.max.apply(null, timestamps);
                        var dur = maxT - minT;
                        if (dur <= 0) return null;

                        var durSec = dur / 1000;
                        var pxPerSec = 20;
                        var chartWidth = Math.max(600, durSec * pxPerSec);

                        tasks.sort(function(a, b) { return a.start - b.start; });

                        var rowEnds = [];
                        for (var i = 0; i < tasks.length; i++) {
                            var t = tasks[i];
                            var row = -1;
                            for (var r = 0; r < rowEnds.length; r++) {
                                if (t.start >= rowEnds[r]) {
                                    row = r;
                                    break;
                                }
                            }
                            if (row === -1) {
                                row = rowEnds.length;
                                rowEnds.push(0);
                            }
                            t.row = row;
                            t.leftPx = ((t.start - minT) / 1000) * pxPerSec;
                            t.widthPx = Math.max(3, ((t.end - t.start) / 1000) * pxPerSec);
                            rowEnds[row] = t.end;
                        }

                        var numRows = rowEnds.length;
                        var rh = 18;
                        var maxRows = 15;
                        var height = Math.max(50, Math.min(numRows, maxRows) * rh + 32);

                        var interval = durSec < 10 ? 1 : durSec < 60 ? 5 : durSec < 300 ? 30 : 60;
                        var labels = [];
                        for (var s = 0; s <= durSec; s += interval) {
                            labels.push({
                                leftPx: s * pxPerSec,
                                txt: s < 60 ? s + 's' : Math.floor(s/60) + 'm' + (s%60 > 0 ? s%60 + 's' : ''),
                            });
                        }

                        return { tasks: tasks, chartWidth: chartWidth, numRows: numRows, height: height, labels: labels, rh: rh, colors: colors };
                    }, [buildKey, targetColors]);

                    if (!timelineData) return null;

                    var tasks = timelineData.tasks;
                    var chartWidth = timelineData.chartWidth;
                    var numRows = timelineData.numRows;
                    var height = timelineData.height;
                    var labels = timelineData.labels;
                    var rh = timelineData.rh;
                    var colors = timelineData.colors;
                    var colorKeys = Object.keys(colors);

                    // Create Y-axis row labels (show every row or every other for many rows)
                    var rowLabels = [];
                    var rowStep = numRows > 10 ? 2 : 1;
                    for (var row = 0; row < numRows; row += rowStep) {
                        rowLabels.push(row + 1);
                    }

                    // Count cached tasks
                    var cachedCount = 0;
                    for (var ci = 0; ci < tasks.length; ci++) {
                        if (tasks[ci].cached) cachedCount++;
                    }

                    // Find first task index for each target (for legend click)
                    var firstTaskByTarget = {};
                    for (var fi = 0; fi < tasks.length; fi++) {
                        var tgt = tasks[fi].targetName;
                        if (firstTaskByTarget[tgt] === undefined) {
                            firstTaskByTarget[tgt] = fi;
                        }
                    }

                    // Scroll to target's first task
                    var scrollToTarget = function(targetName) {
                        var idx = firstTaskByTarget[targetName];
                        if (idx !== undefined) {
                            var el = document.getElementById('task-bar-' + idx);
                            if (el) {
                                el.scrollIntoView({ behavior: 'smooth', block: 'center', inline: 'center' });
                                el.style.outline = '2px solid white';
                                el.style.outlineOffset = '1px';
                                el.style.zIndex = '10';
                                setTimeout(function() {
                                    el.style.outline = '';
                                    el.style.outlineOffset = '';
                                    el.style.zIndex = '';
                                }, 2000);
                            }
                        }
                    };

                    // Format duration for bar label
                    var formatDur = function(ms) {
                        var s = ms / 1000;
                        if (s < 1) return Math.round(ms) + 'ms';
                        if (s < 60) return s.toFixed(1) + 's';
                        return Math.floor(s / 60) + 'm' + Math.round(s % 60) + 's';
                    };

                    return (
                        <Card className="mb-6">
                            <CardHeader className="pb-2">
                                <CardTitle className="text-base">Build Parallelism</CardTitle>
                                <CardDescription>
                                    Peak: {numRows} concurrent tasks
                                    {cachedCount > 0 && <span className="ml-2">| {cachedCount} cached (striped)</span>}
                                </CardDescription>
                            </CardHeader>
                            <CardContent>
                                {/* Legend - scrollable, clickable */}
                                <div className="overflow-x-auto mb-3 pb-1">
                                    <div className="flex gap-3 text-xs">
                                        {colorKeys.map(function(name) {
                                            return (
                                                <button
                                                    key={name}
                                                    onClick={function() { scrollToTarget(name); }}
                                                    className="flex items-center gap-1.5 shrink-0 hover:bg-secondary/50 px-1.5 py-0.5 rounded transition-colors"
                                                >
                                                    <div className="w-2.5 h-2.5 rounded-sm shrink-0" style={{ backgroundColor: colors[name].bg }}></div>
                                                    <span className="text-muted-foreground whitespace-nowrap">{name}</span>
                                                </button>
                                            );
                                        })}
                                    </div>
                                </div>
                                {/* Chart with horizontal scroll - pixel-based so bars don't shift */}
                                <div className="overflow-x-auto" ref={scrollRef} onScroll={handleScroll}>
                                    <div className="flex" style={{ width: chartWidth + 40 }}>
                                        {/* Y-axis */}
                                        <div className="flex flex-col justify-between pr-2 text-[9px] text-muted-foreground shrink-0" style={{ height: height - 20, paddingTop: 2 }}>
                                            {rowLabels.map(function(r) {
                                                return <span key={r} className="leading-none">{r}</span>;
                                            })}
                                        </div>
                                        {/* Chart area */}
                                        <div
                                            className="relative bg-secondary/30 rounded overflow-hidden"
                                            style={{ height: height, width: chartWidth }}
                                        >
                                            {labels.map(function(l, idx) {
                                                return <div key={idx} className="absolute top-0 bottom-5 w-px bg-border/40" style={{ left: l.leftPx }}></div>;
                                            })}
                                            {tasks.map(function(t, idx) {
                                                var showLabel = t.widthPx > 80;
                                                var durMs = t.end - t.start;
                                                var isCached = t.cached;
                                                var barStyle = {
                                                    left: t.leftPx,
                                                    width: t.widthPx,
                                                    top: t.row * rh + 2,
                                                    height: rh - 3,
                                                };
                                                if (isCached) {
                                                    // Cached: striped pattern with lower opacity
                                                    barStyle.background = 'repeating-linear-gradient(45deg, ' + t.color.bg + ', ' + t.color.bg + ' 2px, ' + t.color.light + ' 2px, ' + t.color.light + ' 4px)';
                                                    barStyle.opacity = 0.7;
                                                } else {
                                                    barStyle.backgroundColor = t.color.bg;
                                                }
                                                return (
                                                    <div
                                                        key={t.id}
                                                        id={'task-bar-' + idx}
                                                        className="absolute rounded-sm overflow-hidden cursor-default hover:brightness-110 transition-all"
                                                        title={t.name + ' | ' + t.targetName + ' | ' + formatDur(durMs) + (isCached ? ' | CACHED' : '')}
                                                        style={barStyle}
                                                    >
                                                        {showLabel && (
                                                            <span className="absolute inset-0 flex items-center px-1 text-[8px] font-medium text-white truncate" style={{ textShadow: '0 0 2px rgba(0,0,0,0.5)' }}>
                                                                {isCached ? '⚡ ' : ''}{t.name}
                                                            </span>
                                                        )}
                                                    </div>
                                                );
                                            })}
                                            <div className="absolute bottom-0 left-0 right-0 h-5 border-t border-border/40 flex items-center">
                                                {labels.map(function(l, idx) {
                                                    return <span key={idx} className="absolute text-[9px] text-muted-foreground" style={{ left: l.leftPx, transform: 'translateX(-50%)' }}>{l.txt}</span>;
                                                })}
                                            </div>
                                        </div>
                                    </div>
                                </div>
                            </CardContent>
                        </Card>
                    );
                };

                // Simple markdown to HTML converter
                const renderMarkdown = (text) => {
                    if (!text) return '';
                    return text
                        // Bold: **text** or __text__
                        .replace(/\\*\\*(.+?)\\*\\*/g, '<strong>$1</strong>')
                        .replace(/__(.+?)__/g, '<strong>$1</strong>')
                        // Italic: *text* or _text_
                        .replace(/\\*([^*]+)\\*/g, '<em>$1</em>')
                        .replace(/_([^_]+)_/g, '<em>$1</em>')
                        // Code: `text`
                        .replace(/`([^`]+)`/g, '<code class="px-1 py-0.5 rounded bg-black/10 text-xs">$1</code>')
                        // Line breaks
                        .replace(/\\n/g, '<br/>');
                };

                // Collapsible Task Detail
                const TaskDetail = ({ task, isExpanded, explanation, isLoadingExplanation, onRequestExplain, hasAgent }) => {
                    if (!isExpanded) return null;
                    const ruleInfo = task.ruleInfo || '';
                    const rawFilePath = ruleInfo.includes('/') ? ruleInfo.split(' ').find(s => s.includes('/')) : null;
                    // Clean up file path - remove trailing backslashes from escaped spaces
                    const filePath = rawFilePath ? removeTrailingBS(rawFilePath) : null;

                    return (
                        <div className="mt-2 p-3 rounded-md bg-secondary text-xs space-y-2 font-mono overflow-hidden">
                            {task.type && (
                                <div className="flex gap-2">
                                    <span className="text-muted-foreground shrink-0">Type:</span>
                                    <span className="text-foreground break-all">{task.type}</span>
                                </div>
                            )}
                            {ruleInfo && (
                                <div className="flex gap-2">
                                    <span className="text-muted-foreground shrink-0">Rule:</span>
                                    <span className="text-foreground break-all">{removeTrailingBS(ruleInfo.split(' ')[0])}</span>
                                </div>
                            )}
                            {filePath && (
                                <div className="flex gap-2">
                                    <span className="text-muted-foreground shrink-0">File:</span>
                                    <span className="text-blue-600 break-all">{removeTrailingBS(filePath.split('/').slice(-2).join('/'))}</span>
                                </div>
                            )}
                            {task.startTime && (
                                <div className="flex gap-2">
                                    <span className="text-muted-foreground shrink-0">Started:</span>
                                    <span className="text-foreground">{formatTime(task.startTime)}</span>
                                </div>
                            )}
                            {task.durationSeconds != null && (
                                <div className="flex gap-2">
                                    <span className="text-muted-foreground shrink-0">Duration:</span>
                                    <span className="text-foreground">{formatDuration(task.durationSeconds)}</span>
                                </div>
                            )}
                            {task.exitCode != null && (
                                <div className="flex gap-2">
                                    <span className="text-muted-foreground shrink-0">Exit:</span>
                                    <span className={task.exitCode === 0 ? 'text-emerald-600' : 'text-red-600'}>{task.exitCode}</span>
                                </div>
                            )}
                            {task.signature && (
                                <div className="flex gap-2">
                                    <span className="text-muted-foreground shrink-0">Sig:</span>
                                    <span className="text-muted-foreground truncate">{task.signature.substring(0, 50)}...</span>
                                </div>
                            )}
                            {/* AI Explanation section */}
                            {hasAgent && (
                                <div className="pt-2 mt-2 border-t border-border/50">
                                    {explanation ? (
                                        <div className="pl-3 border-l-2 border-primary/50 font-sans text-foreground overflow-hidden break-words"
                                            dangerouslySetInnerHTML={{ __html: renderMarkdown(explanation) }}
                                        />
                                    ) : isLoadingExplanation ? (
                                        <div className="flex items-center gap-2 text-muted-foreground">
                                            <Loader className="h-3 w-3" />
                                            <span className="font-sans">Thinking...</span>
                                        </div>
                                    ) : (
                                        <button
                                            onClick={onRequestExplain}
                                            className="flex items-center gap-1 text-muted-foreground hover:text-primary transition-colors font-sans"
                                        >
                                            <QuestionMark className="h-3 w-3" />
                                            <span>Explain this task</span>
                                        </button>
                                    )}
                                </div>
                            )}
                        </div>
                    );
                };

                // Task Item in Timeline
                const TaskItem = ({ task, showDetail = false, selectedAgent, hasAgent }) => {
                    const [expanded, setExpanded] = useState(false);
                    const [explanation, setExplanation] = useState(null);
                    const [isLoadingExplanation, setIsLoadingExplanation] = useState(false);
                    const [requestId, setRequestId] = useState(null);
                    const readableName = getReadableRuleName(task.ruleInfo, task.type);

                    // Cancel request when component unmounts or collapses
                    useEffect(() => {
                        return () => {
                            if (requestId && isLoadingExplanation) {
                                fetch('/api/explain/cancel', {
                                    method: 'POST',
                                    headers: { 'Content-Type': 'application/json' },
                                    body: JSON.stringify({ requestId })
                                }).catch(() => {});
                            }
                        };
                    }, [requestId, isLoadingExplanation]);

                    const handleRequestExplain = async () => {
                        if (!selectedAgent || isLoadingExplanation) return;

                        const newRequestId = Math.random().toString(36).substring(2, 15);
                        setRequestId(newRequestId);
                        setIsLoadingExplanation(true);

                        try {
                            // Extract file paths from ruleInfo for context
                            const ruleInfo = task.ruleInfo || '';
                            const pathMatches = ruleInfo.match(/\\/[^\\s]+/g) || [];
                            const filePaths = pathMatches.map(p => removeTrailingBS(p)).filter(p => p.length > 1);

                            const response = await fetch('/api/explain', {
                                method: 'POST',
                                headers: { 'Content-Type': 'application/json' },
                                body: JSON.stringify({
                                    agentId: selectedAgent,
                                    type: 'task',
                                    name: readableName,
                                    ruleInfo: ruleInfo,
                                    taskType: task.type || '',
                                    signature: task.signature || '',
                                    filePaths: filePaths.slice(0, 5), // Limit to 5 most relevant paths
                                    requestId: newRequestId
                                })
                            });
                            const data = await response.json();
                            if (data.requestId === newRequestId) {
                                setExplanation(data.explanation || 'No explanation available.');
                            }
                        } catch (e) {
                            if (e.name !== 'AbortError') {
                                setExplanation('Failed to get explanation.');
                            }
                        } finally {
                            setIsLoadingExplanation(false);
                        }
                    };

                    return (
                        <div className="group">
                            <button
                                onClick={() => setExpanded(!expanded)}
                                className="w-full flex items-center gap-2 py-1.5 px-2 rounded hover:bg-secondary transition-colors text-left"
                            >
                                <div className={`w-1.5 h-1.5 rounded-full shrink-0 ${
                                    task.status === 'succeeded' ? 'bg-emerald-500' :
                                    task.status === 'failed' ? 'bg-red-500' :
                                    task.status === 'running' ? 'bg-blue-500 animate-pulse' : 'bg-muted-foreground'
                                }`} />
                                <span className="text-xs text-muted-foreground truncate flex-1">{readableName}</span>
                                {task.durationSeconds != null && (
                                    <span className="text-[10px] text-muted-foreground tabular-nums">{formatDuration(task.durationSeconds)}</span>
                                )}
                                <ChevronRight className={`h-3 w-3 text-muted-foreground transition-transform ${expanded ? 'rotate-90' : ''}`} />
                            </button>
                            <TaskDetail
                                task={task}
                                isExpanded={expanded}
                                explanation={explanation}
                                isLoadingExplanation={isLoadingExplanation}
                                onRequestExplain={handleRequestExplain}
                                hasAgent={hasAgent}
                            />
                        </div>
                    );
                };

                // Timeline Target Item
                const TimelineTarget = ({ target, color, buildStatus, buildStartTime, buildDuration, isFirst, isLast, selectedAgent, hasAgent }) => {
                    const [expanded, setExpanded] = useState(false);
                    const [showAllTasks, setShowAllTasks] = useState(false);
                    const [explanation, setExplanation] = useState(null);
                    const [isLoadingExplanation, setIsLoadingExplanation] = useState(false);
                    const [requestId, setRequestId] = useState(null);

                    // Derive effective status: if build is complete but target shows running, use build status
                    const effectiveStatus = useMemo(() => {
                        if (target.status === 'running' && (buildStatus === 'succeeded' || buildStatus === 'failed')) {
                            return buildStatus;
                        }
                        return target.status;
                    }, [target.status, buildStatus]);

                    // Cancel request when component unmounts
                    useEffect(() => {
                        return () => {
                            if (requestId && isLoadingExplanation) {
                                fetch('/api/explain/cancel', {
                                    method: 'POST',
                                    headers: { 'Content-Type': 'application/json' },
                                    body: JSON.stringify({ requestId })
                                }).catch(() => {});
                            }
                        };
                    }, [requestId, isLoadingExplanation]);

                    const handleRequestExplain = async () => {
                        if (!selectedAgent || isLoadingExplanation) return;

                        const newRequestId = Math.random().toString(36).substring(2, 15);
                        setRequestId(newRequestId);
                        setIsLoadingExplanation(true);

                        try {
                            // Gather context from target's tasks
                            const tasks = target.tasks || [];
                            const taskTypes = [...new Set(tasks.map(t => t.type).filter(Boolean))];
                            const allPaths = tasks.flatMap(t => {
                                const matches = (t.ruleInfo || '').match(/\\/[^\\s]+/g) || [];
                                return matches.map(p => removeTrailingBS(p));
                            }).filter(p => p.length > 1);
                            // Get unique directories from paths
                            const directories = [...new Set(allPaths.map(p => p.split('/').slice(0, -1).join('/')))].slice(0, 3);
                            // Get some example files
                            const exampleFiles = [...new Set(allPaths)].slice(0, 5);

                            const response = await fetch('/api/explain', {
                                method: 'POST',
                                headers: { 'Content-Type': 'application/json' },
                                body: JSON.stringify({
                                    agentId: selectedAgent,
                                    type: 'target',
                                    name: target.name,
                                    taskCount: tasks.length,
                                    taskTypes: taskTypes.slice(0, 10),
                                    directories: directories,
                                    exampleFiles: exampleFiles,
                                    requestId: newRequestId
                                })
                            });
                            const data = await response.json();
                            if (data.requestId === newRequestId) {
                                setExplanation(data.explanation || 'No explanation available.');
                            }
                        } catch (e) {
                            if (e.name !== 'AbortError') {
                                setExplanation('Failed to get explanation.');
                            }
                        } finally {
                            setIsLoadingExplanation(false);
                        }
                    };

                    // Calculate timeline position
                    const startOffset = buildStartTime && target.startTime
                        ? (new Date(target.startTime) - new Date(buildStartTime)) / 1000
                        : 0;
                    const duration = target.durationSeconds || 0;
                    const leftPercent = buildDuration > 0 ? (startOffset / buildDuration) * 100 : 0;
                    const widthPercent = buildDuration > 0 ? (duration / buildDuration) * 100 : 0;

                    const completedTasks = target.tasks?.filter(t => t.status === 'succeeded').length || 0;
                    const failedTasks = target.tasks?.filter(t => t.status === 'failed').length || 0;
                    const runningTasks = target.tasks?.filter(t => t.status === 'running').length || 0;
                    const totalTasks = target.taskCount || target.tasks?.length || 0;

                    const visibleTasks = showAllTasks ? target.tasks : target.tasks?.slice(0, 5);
                    const hiddenCount = (target.tasks?.length || 0) - 5;

                    return (
                        <div className="relative">
                            {/* Timeline connector */}
                            {!isFirst && (
                                <div className="absolute left-[11px] -top-3 w-0.5 h-3 bg-border" />
                            )}

                            <div className="flex gap-3">
                                {/* Timeline dot with target color */}
                                <div className="relative flex flex-col items-center">
                                    <div
                                        className="w-6 h-6 rounded-full border-2 flex items-center justify-center shrink-0"
                                        style={{
                                            borderColor: color ? color.bg : 'hsl(240 5.9% 90%)',
                                            backgroundColor: color ? color.light : 'hsl(240 4.8% 95.9%)'
                                        }}
                                    >
                                        {effectiveStatus === 'succeeded' && <CheckCircle className="h-3 w-3" style={{ color: color ? color.bg : 'rgb(16, 185, 129)' }} />}
                                        {effectiveStatus === 'failed' && <XCircle className="h-3 w-3 text-red-600" />}
                                        {effectiveStatus === 'running' && <Loader className="h-3 w-3" style={{ color: color ? color.bg : 'rgb(59, 130, 246)' }} />}
                                    </div>
                                    {!isLast && (
                                        <div className="w-0.5 flex-1 bg-border mt-1" />
                                    )}
                                </div>

                                {/* Content */}
                                <div className="flex-1 pb-4">
                                    <Card className="overflow-hidden">
                                        {/* Header - always visible */}
                                        <button
                                            onClick={() => setExpanded(!expanded)}
                                            className="w-full text-left"
                                        >
                                            <CardHeader className="py-3 hover:bg-secondary/30 transition-colors">
                                                <div className="flex items-start justify-between gap-2">
                                                    <div className="flex items-center gap-2 min-w-0">
                                                        <Package className="h-4 w-4 text-muted-foreground shrink-0" />
                                                        <CardTitle className="text-sm truncate">{target.name}</CardTitle>
                                                    </div>
                                                    <div className="flex items-center gap-2 shrink-0">
                                                        <StatusBadge status={effectiveStatus} size="sm" />
                                                        <ChevronDown className={`h-4 w-4 text-muted-foreground transition-transform ${expanded ? 'rotate-180' : ''}`} />
                                                    </div>
                                                </div>

                                                {/* Mini stats row */}
                                                <div className="flex items-center gap-3 mt-2 text-xs text-muted-foreground">
                                                    <span className="flex items-center gap-1">
                                                        <Layers className="h-3 w-3" />
                                                        {completedTasks}/{totalTasks} tasks
                                                    </span>
                                                    {target.durationSeconds != null && (
                                                        <span className="flex items-center gap-1">
                                                            <Clock className="h-3 w-3" />
                                                            {formatDuration(target.durationSeconds)}
                                                        </span>
                                                    )}
                                                    {failedTasks > 0 && (
                                                        <span className="text-red-600">{failedTasks} failed</span>
                                                    )}
                                                    {runningTasks > 0 && (
                                                        <span className="text-blue-600">{runningTasks} running</span>
                                                    )}
                                                </div>

                                                {/* Progress bar with target color */}
                                                <div className="mt-2 h-1.5 bg-secondary rounded-full overflow-hidden">
                                                    <div
                                                        className={`h-full rounded-full transition-all duration-300 ${effectiveStatus === 'running' ? 'animate-pulse' : ''}`}
                                                        style={{
                                                            width: effectiveStatus === 'running' ? '100%' : (effectiveStatus === 'succeeded' || effectiveStatus === 'failed') ? '100%' : '0%',
                                                            backgroundColor: effectiveStatus === 'failed' ? 'rgb(239, 68, 68)' : (color ? color.bg : 'rgb(59, 130, 246)')
                                                        }}
                                                    />
                                                </div>
                                            </CardHeader>
                                        </button>

                                        {/* Expanded content */}
                                        {expanded && (
                                            <CardContent className="border-t border-border pt-3">
                                                {/* AI Explanation section for target */}
                                                {hasAgent && (
                                                    <div className="mb-3 pb-3 border-b border-border/50 text-xs">
                                                        {explanation ? (
                                                            <div className="pl-3 border-l-2 border-primary/50 text-foreground overflow-hidden break-words"
                                                                dangerouslySetInnerHTML={{ __html: renderMarkdown(explanation) }}
                                                            />
                                                        ) : isLoadingExplanation ? (
                                                            <div className="flex items-center gap-2 text-muted-foreground">
                                                                <Loader className="h-3 w-3" />
                                                                <span>Thinking...</span>
                                                            </div>
                                                        ) : (
                                                            <button
                                                                onClick={(e) => { e.stopPropagation(); handleRequestExplain(); }}
                                                                className="flex items-center gap-1 text-muted-foreground hover:text-primary transition-colors"
                                                            >
                                                                <QuestionMark className="h-3 w-3" />
                                                                <span>Explain this target</span>
                                                            </button>
                                                        )}
                                                    </div>
                                                )}
                                                {target.tasks && target.tasks.length > 0 && (
                                                    <>
                                                        <div className="space-y-1 max-h-80 overflow-y-auto scrollbar-thin">
                                                            {visibleTasks?.map((task, i) => (
                                                                <TaskItem key={task.signature || i} task={task} selectedAgent={selectedAgent} hasAgent={hasAgent} />
                                                            ))}
                                                        </div>
                                                        {!showAllTasks && hiddenCount > 0 && (
                                                            <button
                                                                onClick={(e) => { e.stopPropagation(); setShowAllTasks(true); }}
                                                                className="mt-2 text-xs text-muted-foreground hover:text-foreground transition-colors"
                                                            >
                                                                Show {hiddenCount} more tasks...
                                                            </button>
                                                        )}
                                                        {showAllTasks && hiddenCount > 0 && (
                                                            <button
                                                                onClick={(e) => { e.stopPropagation(); setShowAllTasks(false); }}
                                                                className="mt-2 text-xs text-muted-foreground hover:text-foreground transition-colors"
                                                            >
                                                                Show less
                                                            </button>
                                                        )}
                                                    </>
                                                )}
                                            </CardContent>
                                        )}
                                    </Card>
                                </div>
                            </div>
                        </div>
                    );
                };

                // Main Build View
                const BuildView = ({ build, selectedAgent, hasAgent }) => {
                    if (!build) {
                        return (
                            <Card className="p-8">
                                <div className="flex flex-col items-center justify-center text-center">
                                    <div className="w-16 h-16 rounded-full bg-secondary flex items-center justify-center mb-4">
                                        <Package className="h-8 w-8 text-muted-foreground" />
                                    </div>
                                    <h2 className="text-lg font-semibold">No Active Build</h2>
                                    <p className="text-sm text-muted-foreground mt-1">
                                        Start a build to see live progress here
                                    </p>
                                </div>
                            </Card>
                        );
                    }

                    const progress = build.totalTaskCount > 0
                        ? (build.completedTaskCount / build.totalTaskCount) * 100
                        : 0;

                    // Compute consistent colors for targets (shared between timeline and target list)
                    // Use target names as dependency key to avoid recomputing on every poll
                    const targetNames = useMemo(() => {
                        if (!build.targets) return '';
                        return build.targets.map(t => t.name).sort().join(',');
                    }, [build.targets]);

                    const targetColors = useMemo(() => {
                        var colors = {};
                        var ci = 0;
                        if (build.targets) {
                            for (var i = 0; i < build.targets.length; i++) {
                                var name = build.targets[i].name;
                                if (!colors[name]) {
                                    colors[name] = TARGET_COLORS[ci % TARGET_COLORS.length];
                                    ci++;
                                }
                            }
                        }
                        return colors;
                    }, [targetNames]);

                    // Sort targets: running first, then by start time
                    // Compute a stable key to avoid re-sorting on every poll
                    const targetsKey = useMemo(() => {
                        if (!build.targets) return '';
                        return build.targets.map(t => t.name + ':' + t.status + ':' + (t.startTime || '')).join('|');
                    }, [build.targets]);

                    const sortedTargets = useMemo(() => {
                        if (!build.targets) return [];
                        return [...build.targets].sort((a, b) => {
                            // Running targets first
                            if (a.status === 'running' && b.status !== 'running') return -1;
                            if (b.status === 'running' && a.status !== 'running') return 1;
                            // Then by start time
                            if (!a.startTime) return 1;
                            if (!b.startTime) return -1;
                            return new Date(a.startTime) - new Date(b.startTime);
                        });
                    }, [targetsKey]);

                    return (
                        <div className="space-y-4">
                            {/* Header Card */}
                            <Card>
                                <CardHeader>
                                    <div className="flex items-center justify-between">
                                        <div>
                                            <CardTitle className="text-xl">{build.configuration} Build</CardTitle>
                                            <CardDescription className="mt-1">
                                                {build.action} started at {formatTime(build.startTime)}
                                                {build.endTime && ` - completed at ${formatTime(build.endTime)}`}
                                            </CardDescription>
                                        </div>
                                        <StatusBadge status={build.status} />
                                    </div>
                                </CardHeader>
                                <CardContent>
                                    {/* Progress */}
                                    <div className="space-y-2">
                                        <div className="flex justify-between text-sm">
                                            <span className="text-muted-foreground">Progress</span>
                                            <span className="font-medium tabular-nums">
                                                {build.completedTaskCount} / {build.totalTaskCount} tasks
                                            </span>
                                        </div>
                                        <Progress value={progress} />
                                    </div>

                                    {/* Stats Grid */}
                                    <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 mt-4">
                                        <div className="p-3 rounded-lg bg-secondary/50 text-center">
                                            <div className="text-2xl font-bold tabular-nums">{build.completedTargetCount || 0}/{build.targetCount || 0}</div>
                                            <div className="text-xs text-muted-foreground">Targets</div>
                                        </div>
                                        <div className="p-3 rounded-lg bg-secondary/50 text-center">
                                            <div className="text-2xl font-bold tabular-nums">{build.runningTaskCount || 0}</div>
                                            <div className="text-xs text-muted-foreground">Running</div>
                                        </div>
                                        <div className="p-3 rounded-lg bg-secondary/50 text-center">
                                            <div className="text-2xl font-bold tabular-nums">{formatDuration(build.durationSeconds)}</div>
                                            <div className="text-xs text-muted-foreground">Duration</div>
                                        </div>
                                        <div className="p-3 rounded-lg bg-secondary/50 text-center">
                                            <div className={`text-2xl font-bold tabular-nums ${build.errorCount > 0 ? 'text-red-400' : ''}`}>
                                                {build.errorCount || 0}
                                            </div>
                                            <div className="text-xs text-muted-foreground">Errors</div>
                                        </div>
                                    </div>
                                </CardContent>
                            </Card>

                            {/* Parallelism Timeline */}
                            <ParallelismTimeline build={build} targetColors={targetColors} />

                            {/* Target List */}
                            {sortedTargets.length > 0 && (
                                <Card>
                                    <CardHeader>
                                        <CardTitle className="text-base">Build Targets</CardTitle>
                                        <CardDescription>
                                            {sortedTargets.length} targets in dependency order
                                        </CardDescription>
                                    </CardHeader>
                                    <CardContent>
                                        <div className="space-y-0">
                                            {sortedTargets.map((target, i) => (
                                                <TimelineTarget
                                                    key={target.id || target.name}
                                                    target={target}
                                                    color={targetColors[target.name]}
                                                    buildStatus={build.status}
                                                    buildStartTime={build.startTime}
                                                    buildDuration={build.durationSeconds}
                                                    isFirst={i === 0}
                                                    isLast={i === sortedTargets.length - 1}
                                                    selectedAgent={selectedAgent}
                                                    hasAgent={hasAgent}
                                                />
                                            ))}
                                        </div>
                                    </CardContent>
                                </Card>
                            )}
                        </div>
                    );
                };

                // App
                function App() {
                    const [currentBuild, setCurrentBuild] = useState(null);
                    const [builds, setBuilds] = useState([]);
                    const [selectedBuild, setSelectedBuild] = useState(null);
                    const [agents, setAgents] = useState([]);
                    const [selectedAgent, setSelectedAgent] = useState(null);

                    const fetchData = useCallback(async () => {
                        try {
                            const [currentRes, buildsRes] = await Promise.all([
                                fetch('/api/builds/current'),
                                fetch('/api/builds')
                            ]);
                            const current = await currentRes.json();
                            const all = await buildsRes.json();
                            // If there's a running build, show it; otherwise show the most recent
                            const activeBuild = current || (all && all[0]) || null;
                            setCurrentBuild(activeBuild);
                            // Show other builds in history (exclude the active one)
                            const activeSessionID = activeBuild?.sessionID;
                            setBuilds(all.filter(b => b.sessionID !== activeSessionID).slice(0, 10));
                        } catch (e) {
                            console.error('Failed to fetch:', e);
                        }
                    }, []);

                    // Fetch agents once on mount
                    useEffect(() => {
                        fetch('/api/agents')
                            .then(res => res.json())
                            .then(data => {
                                setAgents(data || []);
                                // Auto-select first agent if available
                                if (data && data.length > 0) {
                                    setSelectedAgent(data[0].id);
                                }
                            })
                            .catch(e => console.error('Failed to fetch agents:', e));
                    }, []);

                    useEffect(() => {
                        fetchData();
                        const interval = setInterval(fetchData, 1000);
                        return () => clearInterval(interval);
                    }, [fetchData]);

                    const displayBuild = selectedBuild || currentBuild;

                    return (
                        <div className="min-h-screen">
                            {/* Header */}
                            <header className="sticky top-0 z-50 border-b border-border bg-background/95 backdrop-blur supports-[backdrop-filter]:bg-background/60">
                                <div className="container flex h-14 max-w-screen-xl items-center px-4 mx-auto">
                                    <div className="flex items-center gap-2">
                                        <Package className="h-5 w-5 text-primary" />
                                        <span className="font-semibold">Swift Build Monitor</span>
                                    </div>
                                    <div className="flex-1" />
                                    <div className="flex items-center gap-3">
                                        {agents.length > 0 && (
                                            <div className="flex items-center gap-2">
                                                <span className="text-xs text-muted-foreground">AI Assistant:</span>
                                                <select
                                                    value={selectedAgent || ''}
                                                    onChange={(e) => setSelectedAgent(e.target.value)}
                                                    className="h-8 px-2 text-sm rounded-md border border-border bg-background text-foreground focus:outline-none focus:ring-2 focus:ring-ring"
                                                >
                                                    {agents.map(agent => (
                                                        <option key={agent.id} value={agent.id}>
                                                            {agent.name}
                                                        </option>
                                                    ))}
                                                </select>
                                            </div>
                                        )}
                                        {currentBuild && <StatusBadge status={currentBuild.status} />}
                                    </div>
                                </div>
                            </header>

                            {/* Main */}
                            <main className="container max-w-screen-xl mx-auto px-4 py-6">
                                <BuildView build={displayBuild} selectedAgent={selectedAgent} hasAgent={!!selectedAgent} />

                                {/* Build History */}
                                {builds.length > 0 && (
                                    <Card className="mt-6">
                                        <CardHeader>
                                            <CardTitle className="text-base">Recent Builds</CardTitle>
                                        </CardHeader>
                                        <CardContent>
                                            <div className="space-y-1">
                                                {builds.map((build, i) => (
                                                    <button
                                                        key={build.sessionID || i}
                                                        onClick={() => setSelectedBuild(build)}
                                                        className="w-full flex items-center justify-between py-2 px-3 hover:bg-secondary/50 transition-colors rounded-md"
                                                    >
                                                        <div className="flex items-center gap-3">
                                                            <StatusBadge status={build.status} size="sm" />
                                                            <span className="font-medium text-sm">{build.configuration}</span>
                                                        </div>
                                                        <div className="flex items-center gap-4 text-xs text-muted-foreground">
                                                            <span className="tabular-nums">{build.completedTaskCount} tasks</span>
                                                            <span className="tabular-nums">{formatDuration(build.durationSeconds)}</span>
                                                            <span>{formatTimeShort(build.startTime)}</span>
                                                        </div>
                                                    </button>
                                                ))}
                                            </div>
                                        </CardContent>
                                    </Card>
                                )}

                                {selectedBuild && (
                                    <div className="mt-4 flex justify-center">
                                        <button
                                            onClick={() => setSelectedBuild(null)}
                                            className="inline-flex items-center gap-2 text-sm text-muted-foreground hover:text-foreground transition-colors"
                                        >
                                            Back to current build
                                        </button>
                                    </div>
                                )}
                            </main>
                        </div>
                    );
                }

                const root = ReactDOM.createRoot(document.getElementById('root'));
                root.render(<App />);
            </script>
        </body>
        </html>
        """
    }
}

// MARK: - HTTP Response

struct HTTPResponse {
    let status: Int
    let contentType: String
    var headers: [String: String] = [:]
    let body: String

    func toString() -> String {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 404: statusText = "Not Found"
        case 405: statusText = "Method Not Allowed"
        case 500: statusText = "Internal Server Error"
        default: statusText = "Unknown"
        }

        var response = "HTTP/1.1 \(status) \(statusText)\r\n"
        response += "Content-Type: \(contentType)\r\n"
        response += "Content-Length: \(body.utf8.count)\r\n"
        response += "Access-Control-Allow-Origin: *\r\n"

        for (key, value) in headers {
            response += "\(key): \(value)\r\n"
        }

        response += "\r\n"
        response += body

        return response
    }
}

// MARK: - Errors

enum HTTPError: Error {
    case socketCreationFailed(errno: Int32)
    case bindFailed(errno: Int32)
    case listenFailed(errno: Int32)
}
