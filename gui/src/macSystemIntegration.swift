import Foundation
import AppIntents
import FoundationModels
import CoreTransferable

// Ponte pequena: dados copiados, sem Qt nem credenciais atravessando o Swift.
public typealias ActionHandler = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Int32
public typealias TextCallback = @convention(c) (Int32, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void

private struct ConsoleRecord: Codable {
    let id: String
    let name: String
}

private final class BridgeState: @unchecked Sendable {
    static let shared = BridgeState()
    let lock = NSLock()
    var handler: ActionHandler?
    var context: UnsafeMutableRawPointer?
    var consoles: [ConsoleRecord] = []
    var consolesPublished = false
    var generating = false
    var diagnostic: P5MDiagnostic?
    var activity: NSUserActivity?

    func finishGeneration() {
        lock.lock(); defer { lock.unlock() }
        generating = false
    }

    func snapshot() -> [ConsoleRecord] {
        lock.lock(); defer { lock.unlock() }
        return consoles
    }
}

@_cdecl("p5m_mac_system_register_actions")
public func registerActions(_ handler: ActionHandler?, _ context: UnsafeMutableRawPointer?) {
    let state = BridgeState.shared
    state.lock.lock(); defer { state.lock.unlock() }
    state.handler = handler
    state.context = context
}

@_cdecl("p5m_mac_system_set_consoles")
public func setConsoles(_ json: UnsafePointer<CChar>?) {
    let records: [ConsoleRecord]
    if let json, let data = String(cString: json).data(using: .utf8), data.count <= 32768,
       let decoded = try? JSONDecoder().decode([ConsoleRecord].self, from: data), decoded.count <= 64 {
        var seen = Set<String>()
        records = decoded.filter {
            !$0.id.isEmpty && $0.id.utf8.count <= 128 && $0.name.utf8.count <= 128 &&
            !$0.name.isEmpty && $0.id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_".contains($0)) } &&
            !$0.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) && seen.insert($0.id).inserted
        }
    } else {
        records = []
    }
    let state = BridgeState.shared
    state.lock.lock(); defer { state.lock.unlock() }
    state.consoles = records
    state.consolesPublished = true
}

// A consulta pode chegar durante o cold launch, antes do primeiro snapshot Qt.
private func waitForBackend() async throws {
    for _ in 0..<100 {
        if BridgeState.shared.lock.withLock({ BridgeState.shared.handler != nil && BridgeState.shared.consolesPublished }) { return }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
}

@available(macOS 13.0, *)
struct P5MConsole: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Console"
    static let defaultQuery = P5MConsoleQuery()
    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

@available(macOS 13.0, *)
struct P5MConsoleQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [P5MConsole] {
        try await waitForBackend()
        return BridgeState.shared.snapshot().filter { identifiers.contains($0.id) }.map { P5MConsole(id: $0.id, name: $0.name) }
    }
    func suggestedEntities() async throws -> [P5MConsole] {
        try await waitForBackend()
        return BridgeState.shared.snapshot().map { P5MConsole(id: $0.id, name: $0.name) }
    }
    func entities(matching string: String) async throws -> [P5MConsole] {
        try await waitForBackend()
        return BridgeState.shared.snapshot().filter { $0.name.localizedCaseInsensitiveContains(string) }.map { P5MConsole(id: $0.id, name: $0.name) }
    }
}

private enum ActionError: LocalizedError {
    case unavailable, consoleMissing, rejected
    var errorDescription: String? {
        switch self {
        case .unavailable: return "P5M is still starting. Open the app and try again."
        case .consoleMissing: return "This console is no longer registered. Choose a console in P5M."
        case .rejected: return "P5M could not start this action. Check the app for details."
        }
    }
}

@MainActor
private func runAction(_ action: String, console: P5MConsole? = nil) async throws {
    try await waitForBackend()
    let state = BridgeState.shared
    let (handler, context, exists) = state.lock.withLock {
        (state.handler, state.context, console.map { candidate in state.consoles.contains { $0.id == candidate.id } } ?? true)
    }
    guard exists else { throw ActionError.consoleMissing }
    guard let handler else { throw ActionError.unavailable }
    let result = action.withCString { actionPointer in
        (console?.id ?? "").withCString { handler(actionPointer, $0, context) }
    }
    guard result == 0 else { throw ActionError.rejected }
}

@available(macOS 13.0, *)
struct WakeP5MConsole: AppIntent {
    static let title: LocalizedStringResource = "Wake Console"
    static let description = IntentDescription("Wake a registered console using P5M.")
    static let openAppWhenRun = true
    @Parameter(title: "Console") var console: P5MConsole
    @MainActor func perform() async throws -> some IntentResult {
        try await runAction("wake", console: console)
        return .result()
    }
}

@available(macOS 13.0, *)
struct ConnectP5MConsole: AppIntent {
    static let title: LocalizedStringResource = "Connect to Console"
    static let description = IntentDescription("Start Remote Play with a registered console in P5M.")
    static let openAppWhenRun = true
    @Parameter(title: "Console") var console: P5MConsole
    @MainActor func perform() async throws -> some IntentResult {
        try await runAction("connect", console: console)
        return .result()
    }
}

@available(macOS 13.0, *)
struct OpenP5MDiagnostics: AppIntent {
    static let title: LocalizedStringResource = "Open Session Diagnostics"
    static let description = IntentDescription("Show P5M session diagnostics.")
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        try await runAction("diagnostics")
        return .result()
    }
}

@available(macOS 13.0, *)
struct MuteP5M: AppIntent {
    static let title: LocalizedStringResource = "Mute Microphone"
    static let description = IntentDescription("Mute the microphone sent to the console by P5M.")
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        try await runAction("mute")
        return .result()
    }
}

@available(macOS 13.0, *)
struct P5MShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: WakeP5MConsole(), phrases: ["Wake my console with \(.applicationName)"], shortTitle: "Wake Console", systemImageName: "power")
        AppShortcut(intent: ConnectP5MConsole(), phrases: ["Connect to my console with \(.applicationName)"], shortTitle: "Connect", systemImageName: "gamecontroller")
        AppShortcut(intent: OpenP5MDiagnostics(), phrases: ["Open diagnostics in \(.applicationName)"], shortTitle: "Diagnostics", systemImageName: "waveform.path.ecg")
        AppShortcut(intent: MuteP5M(), phrases: ["Mute the microphone in \(.applicationName)"], shortTitle: "Mute Microphone", systemImageName: "speaker.slash")
    }
}

@_cdecl("p5m_mac_system_refresh_shortcuts")
public func refreshShortcuts() {
    if #available(macOS 13.0, *) { P5MShortcuts.updateAppShortcutParameters() }
}

private func deliver(_ callback: TextCallback?, _ context: UnsafeMutableRawPointer?, _ status: Int32, _ text: String) {
    DispatchQueue.main.async { text.withCString { callback?(status, $0, context) } }
}

private func modelAvailability() -> (Int32, String) {
    guard #available(macOS 26.0, *) else { return (1, "Local session explanation requires macOS 26 or later.") }
    switch SystemLanguageModel.default.availability {
    case .available: return (0, "Apple Intelligence is ready. Session metrics are processed on this Mac.")
    case .unavailable(.deviceNotEligible): return (1, "This Mac does not support Apple Intelligence. Session metrics remain available.")
    case .unavailable(.appleIntelligenceNotEnabled): return (1, "Turn on Apple Intelligence in System Settings to use local session explanations.")
    case .unavailable(.modelNotReady): return (1, "The local model is not ready. Check Apple Intelligence in System Settings and try again later.")
    case .unavailable: return (1, "Apple Intelligence is unavailable on this Mac. Session metrics remain available.")
    }
}

@_cdecl("p5m_mac_system_model_status")
public func modelStatus(_ callback: TextCallback?, _ context: UnsafeMutableRawPointer?) {
    let availability = modelAvailability()
    deliver(callback, context, availability.0, availability.1)
}

// Só números medidos: não aceitamos diário, identificadores nem instruções livres.
private func sanitizedMetrics(_ input: String) -> String? {
    let allowed: Set<String> = ["duration_seconds", "frames_received", "frames_lost", "packet_loss_percent", "latency_ms", "bitrate_mbps", "fps", "audio_underruns", "audio_latency_ms", "decode_ms", "network_ms", "dropped_frames", "hdr", "width", "height"]
    guard input.utf8.count <= 8192, let data = input.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], !object.isEmpty,
          object.keys.allSatisfy({ allowed.contains($0) }) else { return nil }
    var lines: [String] = []
    for key in object.keys.sorted() {
        guard let value = object[key] as? NSNumber, value.doubleValue.isFinite,
              value.doubleValue >= 0, value.doubleValue <= 1_000_000_000,
              (CFGetTypeID(value) != CFBooleanGetTypeID() || key == "hdr") else { return nil }
        lines.append("\(key): \(value.stringValue)")
    }
    return lines.joined(separator: "\n")
}

@_cdecl("p5m_mac_system_explain_session")
public func explainSession(_ json: UnsafePointer<CChar>?, _ callback: TextCallback?, _ context: UnsafeMutableRawPointer?) {
    guard let json, let metrics = sanitizedMetrics(String(cString: json)) else {
        deliver(callback, context, 2, "The session metrics are missing or invalid."); return
    }
    let availability = modelAvailability()
    guard availability.0 == 0 else { deliver(callback, context, 1, availability.1); return }
    let state = BridgeState.shared
    state.lock.lock()
    if state.generating {
        state.lock.unlock()
        deliver(callback, context, 4, "A local session explanation is already running."); return
    }
    state.generating = true
    state.lock.unlock()
    Task {
        defer { state.finishGeneration() }
        guard #available(macOS 26.0, *) else { return }
        do {
            let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: """
                Explain measured Remote Play session metrics in plain English, in at most three short paragraphs.
                Use only the supplied measurements. Never invent measurements, causes, benchmarks or certainty.
                frames_lost is cumulative for the session. bitrate_mbps and packet_loss_percent are final samples, not whole-session averages; never describe them as averages or infer earlier behavior.
                Distinguish observed symptoms from possible causes. If evidence is insufficient, say so.
                Suggest at most two practical checks. Do not suggest sharing credentials, disabling security, or uploading logs.
                This is a post-session explanation; do not call tools or change any settings.
                """)
            let response = try await session.respond(to: "Explain these measured metrics:\n\(metrics)", options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 450))
            deliver(callback, context, 0, response.content)
        } catch {
            // Não devolvemos texto do erro: ele pode repetir conteúdo da sessão.
            deliver(callback, context, 3, "Apple Intelligence could not explain this session. The measured metrics are still available; try again later.")
        }
    }
}


// O contexto descreve apenas o relatório numérico que o usuário está vendo.
@available(macOS 13.0, *)
struct P5MDiagnostic: AppEntity, Transferable {
    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.metrics)
    }
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Session Diagnostics"
    static let defaultQuery = P5MDiagnosticQuery()
    let id: String
    @Property(title: "Measured metrics") var metrics: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "P5M Session Diagnostics", subtitle: "\(metrics)") }
    init(id: String, metrics: String) { self.id = id; self.metrics = metrics }
}

@available(macOS 13.0, *)
struct P5MDiagnosticQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [P5MDiagnostic] {
        let state = BridgeState.shared
        return state.lock.withLock { state.diagnostic.map { identifiers.contains($0.id) ? [$0] : [] } ?? [] }
    }
    func suggestedEntities() async throws -> [P5MDiagnostic] {
        let state = BridgeState.shared
        return state.lock.withLock { state.diagnostic.map { [$0] } ?? [] }
    }
}

@_cdecl("p5m_mac_system_set_context")
public func setContext(_ kind: UnsafePointer<CChar>?, _ identifier: UnsafePointer<CChar>?, _ title: UnsafePointer<CChar>?, _ metricsJSON: UnsafePointer<CChar>?) {
    guard let kind, String(cString: kind) == "diagnostics", let identifier,
          let metricsJSON, let metrics = sanitizedMetrics(String(cString: metricsJSON)) else {
        clearContext(); return
    }
    let id = String(cString: identifier)
    guard !id.isEmpty, id.utf8.count <= 128,
          id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_".contains($0)) }) else {
        clearContext(); return
    }
    DispatchQueue.main.async {
        let state = BridgeState.shared
        state.activity?.invalidate()
        let diagnostic = P5MDiagnostic(id: id, metrics: metrics)
        state.lock.withLock { state.diagnostic = diagnostic }
        let activity = NSUserActivity(activityType: "io.github.beecrepaldi-afk.p5m.mac.session-diagnostics")
        // O título é fixo: texto arbitrário vindo do diário não entra no contexto.
        activity.title = "P5M Session Diagnostics"
        activity.userInfo = ["metrics": metrics]
        activity.isEligibleForHandoff = false
        activity.isEligibleForSearch = false
        if #available(macOS 15.2, *) { activity.appEntityIdentifier = EntityIdentifier(for: diagnostic) }
        state.activity = activity
        activity.becomeCurrent()
    }
}

@_cdecl("p5m_mac_system_clear_context")
public func clearContext() {
    DispatchQueue.main.async {
        let state = BridgeState.shared
        state.activity?.invalidate()
        state.activity = nil
        state.lock.withLock { state.diagnostic = nil }
    }
}
