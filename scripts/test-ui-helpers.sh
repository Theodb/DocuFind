#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${DOCUFIND_TEST_BUILD_DIR:-$(cd "$PROJECT_ROOT/../.." && pwd)/work/docufind-ui-tests}"
mkdir -p "$BUILD_ROOT/module-cache"
xcrun swiftc -swift-version 5 -module-cache-path "$BUILD_ROOT/module-cache" \
    "$PROJECT_ROOT/Sources/DocuFind/BackendClient.swift" \
    "$PROJECT_ROOT/Sources/DocuFind/IndexingProgress.swift" \
    "$PROJECT_ROOT/Sources/DocuFind/ModelDownload.swift" \
    "$PROJECT_ROOT/Tests/ProgressTests.swift" \
    -o "$BUILD_ROOT/progress-tests"
"$BUILD_ROOT/progress-tests"

xcrun swiftc -swift-version 5 -module-cache-path "$BUILD_ROOT/module-cache" \
    "$PROJECT_ROOT/Sources/DocuFind/MarkdownLines.swift" \
    "$PROJECT_ROOT/Tests/DocumentTests.swift" \
    -o "$BUILD_ROOT/document-tests"
"$BUILD_ROOT/document-tests"

# The docufind tool against the app's command server, with a stand-in app model.
xcrun swiftc -swift-version 5 -module-cache-path "$BUILD_ROOT/module-cache" \
    "$PROJECT_ROOT/Sources/docufind-cli/main.swift" -o "$BUILD_ROOT/docufind"
xcrun swiftc -parse-as-library -swift-version 5 -module-cache-path "$BUILD_ROOT/module-cache" \
    "$PROJECT_ROOT/Sources/DocuFind/CommandServer.swift" \
    "$PROJECT_ROOT/Tests/CommandLineTests.swift" \
    -o "$BUILD_ROOT/command-line-tests"
"$BUILD_ROOT/command-line-tests" "$BUILD_ROOT/docufind"
