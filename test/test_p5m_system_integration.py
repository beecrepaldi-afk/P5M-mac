#!/usr/bin/env python3
"""Real SDK compilation and isolated C bridge/App Intents tests; no network or inference.
Run: python3 test/test_p5m_system_integration.py (macOS with Xcode 26+).
"""
import json
import pathlib
import platform
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / "gui/src/macSystemIntegration.swift"
FIXTURE = r'''
private final class CallbackProbe: @unchecked Sendable {
    static let shared = CallbackProbe()
    let lock = NSLock()
    var callbacks: [(Int32, String, Bool)] = []
    func append(_ status: Int32, _ text: String) {
        lock.withLock { callbacks.append((status, text, Thread.isMainThread)) }
    }
}

@main struct IntegrationTests {
    @MainActor static func main() async throws {
        precondition(sanitizedMetrics("{\"latency_ms\":12,\"hdr\":true}") != nil)
        for invalid in ["{}", "{\"token\":12}", "{\"fps\":\"hello\"}", "{\"fps\":-1}", "{\"fps\":true}", "{\"fps\":{}}", "{\"fps\":1e300}"] {
            precondition(sanitizedMetrics(invalid) == nil)
        }
        let consoles = "[{\"id\":\"console-1\",\"name\":\"PS5\"},{\"id\":\"console-1\",\"name\":\"Duplicate\"},{\"id\":\"secret/ip\",\"name\":\"Invalid ID\"}]"
        // A cold query starts first and waits for registration AND snapshot.
        let coldQuery = Task { try await P5MConsoleQuery().entities(for: ["console-1"]) }
        try await Task.sleep(nanoseconds: 100_000_000)
        registerActions({ action, id, _ in
            precondition(Thread.isMainThread)
            precondition(String(cString: action!) == "wake")
            precondition(String(cString: id!) == "console-1")
            return 0
        }, nil)
        consoles.withCString { setConsoles($0) }
        precondition(BridgeState.shared.snapshot().count == 1)
        let coldEntities = try await coldQuery.value
        precondition(coldEntities.count == 1)
        let candidates = try await P5MConsoleQuery().entities(matching: "ps5")
        precondition(candidates.count == 1)
        try await runAction("wake", console: candidates[0]) // Mock callback only.
        do { try await runAction("wake", console: P5MConsole(id: "stale", name: "Old")); fatalError("Stale entity accepted") } catch ActionError.consoleMissing { }
        let metrics = "{\"duration_seconds\":30,\"frames_lost\":2,\"bitrate_mbps\":21.4,\"packet_loss_percent\":0.2}"
        "diagnostics".withCString { kind in "last-session".withCString { id in metrics.withCString { setContext(kind, id, nil, $0) } } }
        try await Task.sleep(nanoseconds: 50_000_000)
        let diagnostics = try await P5MDiagnosticQuery().suggestedEntities()
        precondition(diagnostics.count == 1 && diagnostics[0].metrics.contains("frames_lost: 2"))
        clearContext()
        try await Task.sleep(nanoseconds: 50_000_000)
        let cleared = try await P5MDiagnosticQuery().suggestedEntities()
        precondition(cleared.isEmpty)
        let callback: TextCallback = { status, text, _ in CallbackProbe.shared.append(status, String(cString: text!)) }
        "{\"credential\":123}".withCString { explainSession($0, callback, nil) }
        modelStatus(callback, nil) // Availability only; never generates content.
        try await Task.sleep(nanoseconds: 100_000_000)
        let callbacks = CallbackProbe.shared.lock.withLock { CallbackProbe.shared.callbacks }
        precondition(callbacks.count == 2 && callbacks.allSatisfy { $0.2 })
        precondition(callbacks.filter { $0.0 == 2 }.count == 1)
        precondition(callbacks.filter { $0.0 == 0 || $0.0 == 1 }.count == 1)
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(CallbackProbe.shared.lock.withLock { CallbackProbe.shared.callbacks.count } == 2)
        print("PASS: sanitization, console filters, cold query, mock action, stale entity, Siri context, one main-thread callback, model availability (no inference)")
    }
}
'''


def main():
    if platform.system() != "Darwin":
        raise SystemExit("This test requires macOS and the Apple SDK.")
    with tempfile.TemporaryDirectory(prefix="p5m-system-tests-") as folder:
        directory = pathlib.Path(folder)
        source = directory / "macSystemIntegration.swift"
        source.write_text(SOURCE.read_text() + "\n" + FIXTURE)
        binary = directory / "integration-tests"
        subprocess.run([
            "xcrun", "swiftc", "-module-cache-path", str(directory / "module-cache"),
            "-swift-version", "5", "-parse-as-library", "-target",
            f"{platform.machine()}-apple-macos13.0", str(source), "-o", str(binary)
        ], check=True)
        subprocess.run([str(binary)], check=True)
        # Metadata must contain discoverable actions, rather than an empty extraction.
        protocols = directory / "protocols.json"
        protocols.write_text(json.dumps(["AppIntent", "AppEntity", "AppShortcutsProvider", "EntityQuery", "EntityStringQuery"]))
        subprocess.run([
            "xcrun", "swiftc", "-module-cache-path", str(directory / "module-cache"),
            "-swift-version", "5", "-parse-as-library", "-target",
            f"{platform.machine()}-apple-macos13.0", "-c", "-emit-const-values",
            "-const-gather-protocols-list", str(protocols), "-module-name", "P5MSystemIntegration",
            str(source), "-o", str(directory / "macSystemIntegration.o")
        ], check=True)
        constants = json.loads((directory / "macSystemIntegration.swiftconstvalues").read_text())
        assert constants, "App Intents extraction is empty"
        types = {item.get("typeName", "") for item in constants}
        for name in ["WakeP5MConsole", "ConnectP5MConsole", "OpenP5MDiagnostics", "MuteP5M", "P5MDiagnostic"]:
            assert any(name in value for value in types), f"Missing metadata: {name}"
        print("PASS: App Intents constants include four actions and diagnostic entity")


if __name__ == "__main__":
    main()
