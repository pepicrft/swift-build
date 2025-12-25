#!/bin/bash
#===----------------------------------------------------------------------===#
#
# This source file is part of the Swift open source project
#
# Copyright (c) 2025 Apple Inc. and the Swift project authors
# Licensed under Apache License v2.0 with Runtime Library Exception
#
# See http://swift.org/LICENSE.txt for license information
# See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
#
#===----------------------------------------------------------------------===#
#
# Wrapper script to run xcodebuild with the custom Swift Build service.
# Launches a telemetry collector and opens the web UI at http://localhost:8384
#
# Usage:
#   ./xcodebuild.sh -project MyProject.xcodeproj -scheme MyScheme build
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/.build/debug"
SOCKET_PATH="/tmp/swiftbuild-telemetry.sock"
PORT=8384

# Build the required products
echo "Building Swift Build service and collector..."
swift build --package-path "$SCRIPT_DIR" --product SWBBuildServiceBundle --product swbuild-collector -q

# Get paths
BUILD_SERVICE_PATH="$BUILD_DIR/SWBBuildServiceBundle"
COLLECTOR_PATH="$BUILD_DIR/swbuild-collector"

if [ ! -f "$BUILD_SERVICE_PATH" ]; then
    echo "Error: SWBBuildServiceBundle not found at $BUILD_SERVICE_PATH"
    exit 1
fi

# Kill any existing collector to ensure we use the latest build
pkill -f swbuild-collector 2>/dev/null || true
sleep 0.2

# Start the collector
echo "Starting telemetry collector on port $PORT..."
"$COLLECTOR_PATH" --socket "$SOCKET_PATH" --port "$PORT" &
sleep 0.5  # Give it time to start

# Open the web UI in the browser
open "http://localhost:$PORT"

# Trap to handle interruption
cleanup() {
    echo ""
    echo "Build interrupted."
}
trap cleanup INT TERM

# Check if caching is enabled via environment variable
if [ "${SWIFTBUILD_ENABLE_CACHING:-0}" = "1" ]; then
    echo "Running xcodebuild with Swift Build (compilation caching enabled)..."
    echo ""
    CACHE_SETTINGS=(
        COMPILATION_CACHE_ENABLE_CACHING=YES
        COMPILATION_CACHE_ENABLE_PLUGIN=YES
        SWIFT_ENABLE_COMPILE_CACHE=YES
        SWIFT_ENABLE_EXPLICIT_MODULES=YES
        CLANG_ENABLE_COMPILE_CACHE=YES
        CLANG_ENABLE_MODULES=YES
    )
else
    echo "Running xcodebuild with Swift Build..."
    echo "(Set SWIFTBUILD_ENABLE_CACHING=1 to enable compilation caching)"
    echo ""
    CACHE_SETTINGS=()
fi

env XCBBUILDSERVICE_PATH="$BUILD_SERVICE_PATH" \
    SWIFTBUILD_TELEMETRY_SOCKET="$SOCKET_PATH" \
    /usr/bin/xcrun xcodebuild \
        "${CACHE_SETTINGS[@]}" \
        "$@"
