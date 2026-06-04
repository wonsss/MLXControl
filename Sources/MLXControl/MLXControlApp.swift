import SwiftUI
import ServiceManagement

// ─────────────────────────── Config ───────────────────────────
enum Config {
    static let host = "127.0.0.1"
    static var port: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: "serverPort")
            return v > 0 ? v : 8080
        }
        set { UserDefaults.standard.set(newValue, forKey: "serverPort") }
    }
    static var baseURL: String { "http://\(host):\(port)/v1" }

    static let hubPath = ("~/.cache/huggingface/hub" as NSString).expandingTildeInPath
    static let logPath: String = {
        let dir = ("~/Library/Logs/MLXControl" as NSString).expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "/mlx_server.log"
    }()

    /// Locate the mlx_lm.server binary by searching PATH.
    static let serverBin: String? = findBin("mlx_lm.server")
    /// Locate the hf (huggingface_hub CLI) binary by searching PATH.
    static let hfBin: String? = findBin("hf")

    static let fallbackModels = ["mlx-community/Qwen3-32B-4bit"]
    static let ramWarnGB = 36.0
    static let freeWarnGB = 6.0
    static let alertCooldown = 120.0
    static let historyLen = 40

    // Per-model TTL: auto-stop after this many seconds of idle (no inference activity).
    static let idleTTLDefault = 1800  // 30 min

    // Memory guard: refuse to start if model needs more RAM than this fraction of free RAM.
    static let memGuardHardFraction = 0.95  // block if model > 95 % of free
    static let memGuardSoftFraction = 0.80  // warn if model > 80 % of free

    private static func findBin(_ name: String) -> String? {
        // Check common install locations first, then walk PATH
        let candidates = [
            ("~/.local/bin/" + name as NSString).expandingTildeInPath,
            ("~/.local/share/uv/tools/mlx-lm/bin/" + name as NSString).expandingTildeInPath,
            "/opt/homebrew/bin/" + name,
            "/usr/local/bin/" + name,
        ]
        for c in candidates { if FileManager.default.isExecutableFile(atPath: c) { return c } }
        let paths = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":").map(String.init) ?? []
        return paths.map { $0 + "/" + name }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

enum ServerStatus { case stopped, starting, up, ready }

struct ModelHit: Identifiable, Sendable {
    let id: String
    let downloads: Int
    var sizeBytes: Int? = nil
    var descr: String? = nil
    var prose: String? = nil
}

func humanSize(_ bytes: Int?) -> String {
    guard let b = bytes else { return "…" }
    let gb = Double(b) / 1_073_741_824
    return gb >= 1 ? String(format: "%.1f GB", gb) : String(format: "%.0f MB", Double(b) / 1_048_576)
}

enum RAMFeasibility {
    case ok, warn, insufficient
    var label: String {
        switch self { case .ok: return "✅"; case .warn: return "⚠️"; case .insufficient: return "❌" }
    }
    var color: Color {
        switch self { case .ok: return .green; case .warn: return .orange; case .insufficient: return .red }
    }
}

/// Compare model size against free RAM.
/// - ok: modelGB < freeGB * 0.8
/// - warn: modelGB < freeGB (tight but may work)
/// - insufficient: modelGB >= freeGB
func ramFeasibility(modelBytes: Int?, freeGB: Double) -> RAMFeasibility? {
    guard let b = modelBytes, freeGB > 0 else { return nil }
    let modelGB = Double(b) / 1_073_741_824
    if modelGB < freeGB * 0.8 { return .ok }
    if modelGB < freeGB       { return .warn }
    return .insufficient
}

// ─────────────────────────── Shell helper ───────────────────────────
// Always run via Process argument arrays — no shell interpolation.
@discardableResult
func sh(_ launch: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launch)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do { try p.run() } catch { return "" }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

// Compiled-regex cache (NSCache is thread-safe; helpers run from background gather()).
nonisolated(unsafe) private let regexCache = NSCache<NSString, NSRegularExpression>()
private func compiledRegex(_ pattern: String) -> NSRegularExpression? {
    if let cached = regexCache.object(forKey: pattern as NSString) { return cached }
    guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
    regexCache.setObject(re, forKey: pattern as NSString)
    return re
}

func firstMatch(_ pattern: String, in text: String) -> String? {
    guard let re = compiledRegex(pattern) else { return nil }
    let r = NSRange(text.startIndex..., in: text)
    guard let m = re.firstMatch(in: text, range: r), m.numberOfRanges > 1,
          let g = Range(m.range(at: 1), in: text) else { return nil }
    return String(text[g])
}

func allMatches(_ pattern: String, _ text: String) -> [String] {
    guard let re = compiledRegex(pattern) else { return [] }
    let r = NSRange(text.startIndex..., in: text)
    return re.matches(in: text, range: r).compactMap {
        Range($0.range(at: 1), in: text).map { String(text[$0]) }
    }
}

// AppleScript notification — all args fully escaped to block injection
func notify(_ title: String, _ subtitle: String, _ message: String) {
    func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
    sh("/usr/bin/osascript", [
        "-e",
        "display notification \"\(esc(message))\" with title \"\(esc(title))\" subtitle \"\(esc(subtitle))\""
    ])
}

// ─────────────── Move to /Applications (first launch) ───────────────
enum MoveToApplications {
    @MainActor
    static func promptIfNeeded() {
        let path = Bundle.main.bundlePath
        if path.hasPrefix("/Applications/") { return }
        if UserDefaults.standard.bool(forKey: "skipMoveToApplications") { return }
        let destDir = "/Applications"
        let appName = URL(fileURLWithPath: path).lastPathComponent
        let dest = destDir + "/" + appName

        let alert = NSAlert()
        alert.messageText = "Move to Applications folder?"
        alert.informativeText = "Moving MLX Control to /Applications makes Launch at Login work reliably."
        alert.addButton(withTitle: "Move & Relaunch")
        alert.addButton(withTitle: "Later")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        NSApp.activate(ignoringOtherApps: true)
        let resp = alert.runModal()
        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: "skipMoveToApplications")
        }
        guard resp == .alertFirstButtonReturn else { return }
        install(from: path, to: dest)
    }

    @MainActor
    private static func install(from src: String, to dest: String) {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: dest) { try fm.removeItem(atPath: dest) }
            try fm.copyItem(atPath: src, toPath: dest)
        } catch {
            // On copy failure, retry via Process (no AppleScript string injection)
            
            let rm = Process(); rm.executableURL = URL(fileURLWithPath: "/bin/rm")
            rm.arguments = ["-rf", dest]
            try? rm.run(); rm.waitUntilExit()
            let cp = Process(); cp.executableURL = URL(fileURLWithPath: "/bin/cp")
            cp.arguments = ["-R", src, dest]
            try? cp.run(); cp.waitUntilExit()
            guard fm.fileExists(atPath: dest) else {
                notify("⚡ MLX Control", "Install failed", error.localizedDescription)
                return
            }
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        // Process argument array — no shell string interpolation
        let wait = Process()
        wait.executableURL = URL(fileURLWithPath: "/bin/sh")
        wait.arguments = ["-c",
            "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; open \(dest.shellQuoted)"]
        try? wait.run()
        NSApp.terminate(nil)
    }
}

private extension String {
    var shellQuoted: String { "'" + replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            MoveToApplications.promptIfNeeded()
        }
    }
}

// ─────────────────────────── Controller ───────────────────────────
@Observable @MainActor
final class ServerController {
    var status: ServerStatus = .stopped
    var model = ""
    var pid: Int?
    var ramGB = 0.0
    var cpu = 0.0
    var gpuUtil: Int?
    var gpuMemGB: Double?
    var sysUsedGB = 0.0
    var sysTotalGB = 0.0
    var uptime = ""
    var tps: Double?
    var busy = false
    var models: [String] = Config.fallbackModels
    var selectedModel = Config.fallbackModels[0]
    var gpuHistory: [Double] = []
    var loginEnabled = false
    var isWarming = false
    var downloading: String?
    var searchResults: [ModelHit] = []
    var searching = false
    var toolsWarning: String? = nil    // shown when mlx-lm is not installed
    var blinkOn = true
    var modelSizes: [String: Int] = [:]  // repo id → bytes on disk
    var idleTTLEnabled = true
    var idleTTLSeconds = Config.idleTTLDefault
    var idleSeconds: Int = 0   // seconds since last inference activity (for UI)
    var serverPort: Int = Config.port  // editable port (persisted in UserDefaults)

    @ObservationIgnored private var warmedUp = false
    @ObservationIgnored private var alertedRAM = false
    @ObservationIgnored private var alertedFree = false
    @ObservationIgnored private var lastRAMAlert = Date.distantPast
    @ObservationIgnored private var lastFreeAlert = Date.distantPast
    @ObservationIgnored private var lastActivity = Date.distantPast

    var isRunning: Bool { status != .stopped }

    init() {
        sysTotalGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        checkTools()
        models = detectModels()
        selectedModel = models.first ?? Config.fallbackModels[0]
        refreshModelSizes()
        loginEnabled = SMAppService.mainApp.status == .enabled
        Task { @MainActor [weak self] in
            var halfSeconds = 0
            while true {
                guard let self else { break }
                halfSeconds += 1
                // gather every 3s (6 half-second ticks); blink every 1s (2 ticks)
                if halfSeconds % 6 == 0 { await self.tick() }
                if halfSeconds % 2 == 0 { self.blinkOn.toggle() }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func checkTools() {
        if Config.serverBin == nil {
            toolsWarning = "mlx_lm.server not found.\nInstall: pip install mlx-lm"
        }
    }

    var barTitle: String {
        switch status {
        case .stopped: return "off"
        case .starting: return "…"
        default: return String(format: "%.0fGB", ramGB)
        }
    }

    var statusText: String {
        if isWarming { return "Warming up…" }
        switch status {
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .up: return "Up (model not loaded)"
        case .ready: return "Ready"
        }
    }

    var statusColor: Color {
        if isWarming { return .orange }
        switch status {
        case .stopped: return .gray
        case .starting: return .orange
        case .up: return .yellow
        case .ready: return .green
        }
    }

    func refreshModelSizes() {
        let ids = models
        let hub = Config.hubPath
        Task.detached(priority: .utility) {
            var sizes: [String: Int] = [:]
            for id in ids {
                let dir = hub + "/models--" + id.replacingOccurrences(of: "/", with: "--")
                let out = sh("/usr/bin/du", ["-sk", dir])
                let kb = Int(out.split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "0") ?? 0
                sizes[id] = kb * 1024
            }
            await MainActor.run { self.modelSizes = sizes }
        }
    }

    func detectModels() -> [String] {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: Config.hubPath)
        else { return Config.fallbackModels }
        let found = items
            .filter { $0.hasPrefix("models--") }
            .map { $0.replacingOccurrences(of: "models--", with: "")
                     .replacingOccurrences(of: "--", with: "/") }
            .filter { $0.lowercased().contains("mlx") }
            .sorted()
        return found.isEmpty ? Config.fallbackModels : found
    }

    /// One poll: gather in background, apply UI state on main.
    func refresh() { Task { await tick() } }

    func tick() async {
        let snap = await Task.detached(priority: .utility) { Self.gather() }.value
        apply(snap)
    }

    private struct Snapshot: Sendable {
        var pid: Int?
        var model = ""
        var ramGB = 0.0
        var cpu = 0.0
        var uptime = ""
        var httpUp = false
        var tps: Double?
        var gpuUtil: Int?
        var gpuMemGB: Double?
        var sysUsedGB = 0.0
    }

    private func apply(_ s: Snapshot) {
        pid = s.pid
        if s.pid != nil {
            model = s.model; ramGB = s.ramGB; cpu = s.cpu; uptime = s.uptime
            if let t = s.tps { tps = t; lastActivity = Date() }
            status = s.httpUp ? (warmedUp ? .ready : .up) : .starting
            // If activity has never been recorded, treat server start as first activity.
            if lastActivity == Date.distantPast { lastActivity = Date() }
            checkIdleTTL()
        } else {
            status = .stopped; model = ""; ramGB = 0; cpu = 0; uptime = ""
            warmedUp = false; tps = nil; lastActivity = Date.distantPast
        }
        gpuUtil = s.gpuUtil
        gpuMemGB = s.gpuMemGB
        gpuHistory.append(Double(s.gpuUtil ?? 0))
        if gpuHistory.count > Config.historyLen { gpuHistory.removeFirst() }
        sysUsedGB = s.sysUsedGB
        checkAlerts()
    }

    private func checkIdleTTL() {
        guard isRunning else { idleSeconds = 0; return }
        guard lastActivity != Date.distantPast else { return }
        let idle = Date().timeIntervalSince(lastActivity)
        idleSeconds = Int(idle)
        guard idleTTLEnabled, !busy, !isWarming else { return }
        guard idle >= Double(idleTTLSeconds) else { return }
        notify("⚡ MLX Control", "Idle auto-stop",
               "No activity for \(idleTTLSeconds / 60) min — stopping server to free RAM")
        stop()
    }

    var idleLabel: String {
        guard isRunning, idleTTLEnabled, lastActivity != Date.distantPast else { return "" }
        let idle = idleSeconds
        let remaining = idleTTLSeconds - idle
        if remaining <= 0 { return "" }
        let idleMin = idle / 60
        let remMin  = remaining / 60
        return idleMin < 1
            ? "active · auto-stop in \(remMin)m"
            : "idle \(idleMin)m · auto-stop in \(remMin)m"
    }

    /// All subprocess calls — must run off the main thread (avoid UI hitches).
    private nonisolated static func gather() -> Snapshot {
        var s = Snapshot()
        let pidStr = sh("/usr/bin/pgrep", ["-f", "mlx_lm.server"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        s.pid = pidStr.split(separator: "\n").first.flatMap { Int($0) }
        if let pid = s.pid {
            // Single ps call: numeric cols first, command last (it contains spaces).
            let line = sh("/bin/ps", ["-o", "rss=,%cpu=,etime=,command=", "-p", "\(pid)"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            if parts.count >= 4 {
                s.ramGB = (Double(parts[0]) ?? 0) / 1_048_576
                s.cpu = Double(parts[1]) ?? 0
                s.uptime = String(parts[2])
                if let m = firstMatch("--model\\s+(\\S+)", in: String(parts[3])) { s.model = m }
            }
            s.httpUp = pingHTTP()
            s.tps = readTPS()
        }
        let gpu = readGPU(); s.gpuUtil = gpu.0; s.gpuMemGB = gpu.1
        s.sysUsedGB = readSystemMemory()
        return s
    }

    private nonisolated static func pingHTTP() -> Bool {
        let code = sh("/usr/bin/curl",
            ["-s", "-m", "1", "-o", "/dev/null", "-w", "%{http_code}",
             "http://\(Config.host):\(Config.port)/v1/models"])
        return code.trimmingCharacters(in: .whitespacesAndNewlines) == "200"
    }

    private nonisolated static func readGPU() -> (Int?, Double?) {
        let io = sh("/usr/sbin/ioreg", ["-r", "-d", "1", "-w", "0", "-c", "IOAccelerator"])
        let utils = allMatches("\"Device Utilization %\"=(\\d+)", io).compactMap { Int($0) }
        let mems = allMatches("\"In use system memory\"=(\\d+)", io).compactMap { Double($0) }
        return (utils.max(), mems.max().map { $0 / 1_073_741_824 })
    }

    private nonisolated static func readSystemMemory() -> Double {
        let v = sh("/usr/bin/vm_stat", [])
        let pageSize = Double(firstMatch("page size of (\\d+) bytes", in: v) ?? "16384") ?? 16384
        func pages(_ key: String) -> Double {
            Double(firstMatch("\(key):\\s+(\\d+)", in: v) ?? "0") ?? 0
        }
        let used = (pages("Pages active") + pages("Pages wired down")
                    + pages("Pages occupied by compressor")) * pageSize
        return used / 1_073_741_824
    }

    private nonisolated static func readTPS() -> Double? {
        let tail = sh("/usr/bin/tail", ["-n", "60", Config.logPath])
        if let s = firstMatch("Generation:.*?([0-9.]+) tokens-per-sec", in: tail)
            ?? firstMatch("([0-9.]+) tokens-per-sec", in: tail)
            ?? firstMatch("([0-9.]+) tok/sec", in: tail) {
            return Double(s)
        }
        return nil
    }

    private func checkAlerts() {
        let now = Date()
        if isRunning && ramGB >= Config.ramWarnGB {
            if !alertedRAM && now.timeIntervalSince(lastRAMAlert) > Config.alertCooldown {
                notify("⚡ MLX Resource Warning",
                       String(format: "MLX RAM %.1f GB", ramGB),
                       "Exceeds \(Int(Config.ramWarnGB)) GB threshold")
                lastRAMAlert = now; alertedRAM = true
            }
        } else if ramGB < Config.ramWarnGB * 0.9 { alertedRAM = false }

        let free = sysTotalGB - sysUsedGB
        if free <= Config.freeWarnGB {
            if !alertedFree && now.timeIntervalSince(lastFreeAlert) > Config.alertCooldown {
                notify("⚡ Low Memory Warning",
                       String(format: "Free RAM %.1f GB", free),
                       "Below \(Int(Config.freeWarnGB)) GB free — swap risk")
                lastFreeAlert = now; alertedFree = true
            }
        } else if free > Config.freeWarnGB * 1.2 { alertedFree = false }
    }

    // ── Server control ──
    @ObservationIgnored private var serverProcess: Process?

    private static func isPortInUse(_ port: Int) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private func launchServer() {
        guard let bin = Config.serverBin else {
            notify("⚡ MLX Control", "Start failed", "mlx_lm.server not found. pip install mlx-lm")
            return
        }
        // Append to log file via FileHandle kept alive in serverProcess termination handler.
        let logPath = Config.logPath
        FileManager.default.createFile(atPath: logPath, contents: nil)
        guard let logHandle = FileHandle(forWritingAtPath: logPath) else { return }
        logHandle.seekToEndOfFile()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["--model", selectedModel, "--host", Config.host, "--port", "\(Config.port)"]
        p.standardOutput = logHandle
        p.standardError = logHandle
        p.qualityOfService = .userInitiated
        // Close logHandle only after the process exits — prevents early interpreter shutdown.
        p.terminationHandler = { _ in try? logHandle.close() }
        serverProcess = p
        try? p.run()
    }

    func start() {
        guard !isRunning, !busy else { return }
        guard Config.serverBin != nil else {
            notify("⚡ MLX Control", "Start failed", "mlx_lm.server not found. pip install mlx-lm")
            return
        }
        if Self.isPortInUse(Config.port) {
            notify("⚡ MLX Control", "Port \(Config.port) in use",
                   "Another app (e.g. oMLX) is already on this port. Stop it first.")
            return
        }
        // Memory guard: compare model disk size against available system RAM.
        let freeGB = sysTotalGB - sysUsedGB
        if let modelBytes = modelSizes[selectedModel] {
            let modelGB = Double(modelBytes) / 1_073_741_824
            if modelGB > freeGB * Config.memGuardHardFraction {
                notify("⚡ MLX Control", "Insufficient RAM",
                       String(format: "%.1f GB model needs ~%.1f GB free (have %.1f GB)",
                              modelGB, modelGB / 0.95, freeGB))
                return  // Block start
            }
            if modelGB > freeGB * Config.memGuardSoftFraction {
                notify("⚡ MLX Control", "Low RAM warning",
                       String(format: "%.1f GB model may cause swapping (%.1f GB free)",
                              modelGB, freeGB))
                // Allow start but warn
            }
        }
        busy = true; warmedUp = false; lastActivity = Date()
        launchServer()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2)); self.busy = false; self.refresh()
        }
    }

    func stop() {
        guard !busy else { return }
        busy = true
        _ = sh("/usr/bin/pkill", ["-f", "mlx_lm.server"])
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5)); self.busy = false; self.refresh()
        }
    }

    func restart() {
        guard !busy else { return }
        busy = true; warmedUp = false
        _ = sh("/usr/bin/pkill", ["-f", "mlx_lm.server"])
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            self.launchServer()
            try? await Task.sleep(for: .seconds(2))
            self.busy = false; self.refresh()
        }
    }

    func switchModel(_ m: String) {
        selectedModel = m
        if isRunning { restart() }
    }

    // ── Warm-up ──
    func warmUp() {
        guard status == .up || status == .ready, !isWarming, !busy else { return }
        isWarming = true
        Task { @MainActor in
            let t0 = Date()
            let (tokens, ok) = await self.postWarmup()
            let dt = Date().timeIntervalSince(t0)
            if ok { self.warmedUp = true; if tokens > 0 { self.tps = Double(tokens) / dt } }
            self.isWarming = false; self.refresh()
        }
    }

    private func postWarmup() async -> (Int, Bool) {
        guard let url = URL(string: "\(Config.baseURL)/chat/completions") else { return (0, false) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 180
        let body: [String: Any] = [
            "model": model.isEmpty ? selectedModel : model,
            "messages": [["role": "user", "content": "hi"]],
            "max_tokens": 16, "temperature": 0,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let j = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return ((j?["usage"] as? [String: Any])?["completion_tokens"] as? Int ?? 0, true)
        } catch { return (0, false) }
    }

    // ── Model add / delete ──
    func downloadModel(_ repo: String) {
        let r = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty, downloading == nil else { return }
        guard Config.hfBin != nil else {
            notify("⚡ MLX Control", "Download failed", "hf CLI not found. pip install huggingface_hub")
            return
        }
        downloading = r
        Task { @MainActor in
            let ok = await Self.runDownload(r)
            self.downloading = nil
            self.models = self.detectModels()
            self.refreshModelSizes()
            notify("⚡ MLX Control", ok ? "Download complete" : "Download failed", r)
        }
    }

    private static func runDownload(_ repo: String) async -> Bool {
        guard let bin = Config.hfBin else { return false }
        return await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = ["download", repo]
            p.standardOutput = Pipe(); p.standardError = Pipe()
            do { try p.run() } catch { return false }
            p.waitUntilExit()
            return p.terminationStatus == 0
        }.value
    }

    func deleteModel(_ repo: String) {
        guard !repo.isEmpty else { return }
        if isRunning && model == repo {
            notify("⚡ MLX Control", "Cannot delete", "Model is running — Stop it first")
            return
        }
        // Validate repo is an HF id (alphanumeric / - / _ / . / slash)
        let validID = repo.range(of: #"^[A-Za-z0-9._\-]+(\/[A-Za-z0-9._\-]+)?$"#,
                                  options: .regularExpression) != nil
        guard validID else {
            notify("⚡ MLX Control", "Delete failed", "Invalid model ID")
            return
        }
        let dirName = "models--" + repo.replacingOccurrences(of: "/", with: "--")
        let dir = (Config.hubPath as NSString).appendingPathComponent(dirName)
        // Only allow deletion inside the hub dir (prevent path traversal)
        guard dir.hasPrefix(Config.hubPath + "/") else { return }

        let alert = NSAlert()
        alert.messageText = "Delete model"
        alert.informativeText = "\(repo)\n\nReclaims about \(folderSize(dir))\nPermanently removes it from the disk cache."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if FileManager.default.fileExists(atPath: dir) {
            // Process argument array — no shell string interpolation
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/rm")
            p.arguments = ["-rf", dir]
            try? p.run(); p.waitUntilExit()
        }
        models = detectModels()
        if !models.contains(selectedModel) { selectedModel = models.first ?? "" }
    }

    private func folderSize(_ path: String) -> String {
        guard FileManager.default.fileExists(atPath: path) else { return "0 MB" }
        let out = sh("/usr/bin/du", ["-sk", path])
        let kb = Double(out.split(whereSeparator: { $0 == " " || $0 == "\t" }).first
            .map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "0") ?? 0
        return kb >= 1_048_576 ? String(format: "%.1f GB", kb / 1_048_576)
                               : String(format: "%.0f MB", kb / 1024)
    }

    // ── Model search (HuggingFace) ──
    func searchModels(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !searching else { return }
        searching = true
        Task { @MainActor in
            self.searchResults = await Self.runSearch(q)
            self.searching = false
            await self.fillSizes()
        }
    }

    private func fillSizes() async {
        let ids = searchResults.map(\.id)
        await withTaskGroup(of: (String, Int?, String?, String?).self) { group in
            for id in ids {
                group.addTask {
                    async let d = Self.fetchDetail(id)
                    async let p = Self.fetchReadme(id)
                    let (det, prose) = await (d, p)
                    return (id, det.0, det.1, prose)
                }
            }
            for await (id, size, descr, prose) in group {
                if let idx = self.searchResults.firstIndex(where: { $0.id == id }) {
                    self.searchResults[idx].sizeBytes = size
                    self.searchResults[idx].descr = descr
                    self.searchResults[idx].prose = prose
                }
            }
        }
    }

    private static func fetchReadme(_ id: String) async -> String? {
        guard let url = URL(string: "https://huggingface.co/\(id)/raw/main/README.md")
        else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard var text = String(data: data, encoding: .utf8) else { return nil }
            if text.hasPrefix("---") {
                let after = text.index(text.startIndex, offsetBy: 3)
                if let r = text.range(of: "\n---", range: after..<text.endIndex) {
                    text = String(text[r.upperBound...])
                }
            }
            var para: [String] = []
            for raw in text.components(separatedBy: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty { if para.isEmpty { continue } else { break } }
                if line.hasPrefix("#") || line.hasPrefix("---") {
                    if para.isEmpty { continue } else { break }
                }
                para.append(line)
            }
            var s = para.joined(separator: " ")
            s = s.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]+\\)",
                                        with: "$1", options: .regularExpression)
                 .replacingOccurrences(of: "**", with: "")
                 .trimmingCharacters(in: .whitespacesAndNewlines)
            if s.count > 1000 { s = String(s.prefix(1000)) + "…" }
            return s.isEmpty ? nil : s
        } catch { return nil }
    }

    private static func fetchDetail(_ id: String) async -> (Int?, String?) {
        guard let url = URL(string:
            "https://huggingface.co/api/models/\(id)?expand[]=usedStorage&expand[]=cardData")
        else { return (nil, nil) }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let j = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let size = j?["usedStorage"] as? Int
            let card = j?["cardData"] as? [String: Any]
            var parts: [String] = []
            if let p = card?["pipeline_tag"] as? String { parts.append(p) }
            if let lic = card?["license"] as? String { parts.append(lic) }
            if let langs = card?["language"] as? [String], !langs.isEmpty {
                parts.append(langs.prefix(3).joined(separator: ","))
            }
            return (size, parts.isEmpty ? nil : parts.joined(separator: " · "))
        } catch { return (nil, nil) }
    }

    private static func runSearch(_ q: String) async -> [ModelHit] {
        var comps = URLComponents(string: "https://huggingface.co/api/models")!
        comps.queryItems = [
            .init(name: "author", value: "mlx-community"),
            .init(name: "search", value: q),
            .init(name: "limit", value: "20"),
            .init(name: "sort", value: "downloads"),
            .init(name: "direction", value: "-1"),
        ]
        guard let url = comps.url else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let arr = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
            return arr.compactMap { d in
                guard let id = d["id"] as? String else { return nil }
                return ModelHit(id: id, downloads: (d["downloads"] as? Int) ?? 0)
            }
        } catch { return [] }
    }

    // ── Misc ──
    var endpointURL: String { "http://\(Config.host):\(serverPort)/v1" }

    func copyEndpoint() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(endpointURL, forType: .string)
    }

    func applyPort(_ port: Int) {
        let p = max(1024, min(65535, port))
        serverPort = p
        Config.port = p
        // Restart if running so the new port takes effect
        if isRunning { restart() }
    }

    func openLog() { sh("/usr/bin/open", ["-a", "Console", Config.logPath]) }

    func openModelPage(_ id: String) { sh("/usr/bin/open", ["https://huggingface.co/\(id)"]) }

    func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            notify("⚡ MLX Control", "Login item failed", error.localizedDescription)
        }
        loginEnabled = SMAppService.mainApp.status == .enabled
    }
}

// ─────────────────────────── UI ───────────────────────────
struct StatRow: View {
    let label: String, value: String, warn: Bool
    init(_ label: String, _ value: String, warn: Bool = false) {
        self.label = label; self.value = value; self.warn = warn
    }
    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(warn ? .orange : .primary)
        }.font(.callout)
    }
}

struct Sparkline: View {
    let data: [Double]
    var maxVal: Double = 100
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            if data.count > 1 {
                let step = w / CGFloat(data.count - 1)
                let pts = data.enumerated().map { i, v in
                    CGPoint(x: CGFloat(i) * step,
                            y: h - CGFloat(min(v, maxVal) / maxVal) * h)
                }
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h))
                    pts.forEach { p.addLine(to: $0) }
                    p.addLine(to: CGPoint(x: pts.last!.x, y: h)); p.closeSubpath()
                }.fill(.green.opacity(0.15))
                Path { p in
                    p.move(to: pts[0]); pts.dropFirst().forEach { p.addLine(to: $0) }
                }.stroke(.green, lineWidth: 1.5)
            }
        }
        .frame(height: 30)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

struct ContentView: View {
    @Bindable var c: ServerController
    @State private var query = ""
    @State private var detail: ModelHit?
    @State private var editingPort = false
    @State private var portInput = ""

    var body: some View {
        if let d = detail { detailView(d) } else { mainView }
    }

    func detailView(_ hit: ModelHit) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button { detail = nil } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                Text(hit.id.replacingOccurrences(of: "mlx-community/", with: ""))
                    .font(.headline).lineLimit(1)
                Spacer()
            }
            Text(hit.id).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            HStack(spacing: 10) {
                Label("\(hit.downloads)", systemImage: "arrow.down").font(.caption)
                Label(humanSize(hit.sizeBytes), systemImage: "internaldrive").font(.caption)
                if let f = ramFeasibility(modelBytes: hit.sizeBytes,
                                          freeGB: c.sysTotalGB - c.sysUsedGB) {
                    HStack(spacing: 3) {
                        Text(f.label)
                        Text(f == .ok ? "fits in RAM"
                             : f == .warn ? "tight — may swap"
                             : "insufficient RAM")
                            .foregroundStyle(f.color)
                    }.font(.caption)
                }
            }.foregroundStyle(.secondary)
            if let m = hit.descr { Text(m).font(.caption).foregroundStyle(.tertiary) }
            Divider()
            ScrollView {
                Text(hit.prose ?? "No description available.")
                    .font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 150)
            Divider()
            HStack {
                if c.models.contains(hit.id) {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.caption)
                } else {
                    Button { c.downloadModel(hit.id); detail = nil } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }.disabled(c.downloading != nil)
                }
                Spacer()
                Button { c.openModelPage(hit.id) } label: {
                    Label("Open in HF", systemImage: "safari")
                }.font(.caption)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    var mainView: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── 1. Status header ──────────────────────────────────────
            VStack(alignment: .leading, spacing: 4) {
                if let w = c.toolsWarning {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(w).font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(7).background(.orange.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                HStack(spacing: 8) {
                    Text("MLX Control").font(.headline)
                    Spacer()
                    Text(c.statusText)
                        .font(.caption).foregroundStyle(c.statusColor).fontWeight(.medium)
                }
                if c.isRunning {
                    HStack {
                        Text(c.model.replacingOccurrences(of: "mlx-community/", with: ""))
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        if !c.uptime.isEmpty {
                            Text("up \(c.uptime)").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)

            Divider()

            // ── 2. Metrics ────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 3) {
                // Process metrics
                HStack(spacing: 0) {
                    Label("", systemImage: "memorychip")
                        .labelStyle(.iconOnly).foregroundStyle(.secondary).frame(width: 20)
                    Text("Process").font(.caption2).foregroundStyle(.secondary)
                }
                StatRow("RAM",
                        c.isRunning ? String(format: "%.1f GB", c.ramGB) : "—",
                        warn: c.ramGB >= Config.ramWarnGB)
                StatRow("CPU",
                        c.isRunning ? String(format: "%.0f%%", c.cpu) : "—")
                StatRow("Speed",
                        c.tps.map { String(format: "%.1f tok/s", $0) } ?? "—")

                Spacer().frame(height: 4)

                // GPU metrics
                HStack(spacing: 0) {
                    Label("", systemImage: "cpu")
                        .labelStyle(.iconOnly).foregroundStyle(.secondary).frame(width: 20)
                    Text("System GPU").font(.caption2).foregroundStyle(.secondary)
                }
                StatRow("Utilization",
                        c.gpuUtil.map { "\($0)%" } ?? "—",
                        warn: (c.gpuUtil ?? 0) >= 90)
                Sparkline(data: c.gpuHistory)
                    .padding(.vertical, 2)
                StatRow("GPU mem",
                        c.gpuMemGB.map { String(format: "%.1f GB", $0) } ?? "—")
                StatRow("RAM free",
                        c.sysTotalGB > 0 ? String(format: "%.0f / %.0f GB",
                                                   c.sysTotalGB - c.sysUsedGB, c.sysTotalGB) : "—",
                        warn: c.sysTotalGB > 0 && c.sysUsedGB / c.sysTotalGB > 0.9)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            Divider()

            // ── 3. Model picker ───────────────────────────────────────
            VStack(alignment: .leading, spacing: 6) {
                // Model picker — full width
                HStack(spacing: 6) {
                    Picker("", selection: Binding(
                        get: { c.selectedModel },
                        set: { c.switchModel($0) }
                    )) {
                        ForEach(c.models, id: \.self) { m in
                            let freeGB = c.sysTotalGB - c.sysUsedGB
                            let sizeB  = c.modelSizes[m]
                            let feas   = ramFeasibility(modelBytes: sizeB, freeGB: freeGB)
                            let name   = m.replacingOccurrences(of: "mlx-community/", with: "")
                            let size   = sizeB != nil ? humanSize(sizeB) : ""
                            let dot    = feas.map { $0.label } ?? ""
                            Text("\(dot) \(name)\(size.isEmpty ? "" : "  \(size)")").tag(m)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)

                    Button { c.deleteModel(c.selectedModel) } label: {
                        Image(systemName: "trash")
                    }
                    .foregroundStyle(.red.opacity(0.7))
                    .disabled(c.models.count <= 1 || c.downloading != nil)
                    .help("Delete model")
                }

                // Server control buttons — labeled
                HStack(spacing: 8) {
                    if c.isRunning {
                        Button { c.stop() } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }.buttonStyle(.bordered).controlSize(.small)

                        Button { c.restart() } label: {
                            Label("Restart", systemImage: "arrow.clockwise")
                        }.buttonStyle(.bordered).controlSize(.small)

                        Button { c.warmUp() } label: {
                            Label("Warm up", systemImage: "flame")
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled((c.status != .up && c.status != .ready) || c.isWarming)
                    } else {
                        Button { c.start() } label: {
                            Label("Start", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    }

                    Spacer()

                    if c.busy || c.isWarming {
                        ProgressView().controlSize(.small)
                    }
                }

                // Search
                HStack(spacing: 6) {
                    TextField("Search mlx-community…", text: $query)
                        .textFieldStyle(.roundedBorder).font(.caption)
                        .onSubmit { c.searchModels(query) }
                    if c.searching {
                        ProgressView().controlSize(.small)
                    } else {
                        Button { c.searchModels(query) } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                if !c.searchResults.isEmpty {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(c.searchResults) { hit in
                                HStack(alignment: .top, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(hit.id.replacingOccurrences(of: "mlx-community/", with: ""))
                                            .font(.caption).lineLimit(1)
                                        HStack(spacing: 3) {
                                            Text(humanSize(hit.sizeBytes))
                                            if let f = ramFeasibility(
                                                modelBytes: hit.sizeBytes,
                                                freeGB: c.sysTotalGB - c.sysUsedGB) {
                                                Text(f.label)
                                                Text(f == .ok ? "fits"
                                                     : f == .warn ? "tight" : "too large")
                                                    .foregroundStyle(f.color)
                                            }
                                            Text("·  ↓\(hit.downloads)")
                                        }
                                        .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    .contentShape(Rectangle())
                                    .onTapGesture { detail = hit }
                                    Spacer()
                                    if c.models.contains(hit.id) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    } else {
                                        Button { c.downloadModel(hit.id) } label: {
                                            Image(systemName: "arrow.down.circle")
                                        }.buttonStyle(.borderless).disabled(c.downloading != nil)
                                    }
                                }
                                .padding(.vertical, 3).padding(.horizontal, 6)
                                if hit.id != c.searchResults.last?.id { Divider() }
                            }
                        }
                    }
                    .frame(height: 180)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                if let dl = c.downloading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Downloading \(dl.replacingOccurrences(of: "mlx-community/", with: ""))…")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            Divider()

            // ── 4. Settings + utilities ───────────────────────────────
            VStack(alignment: .leading, spacing: 5) {
                // Idle auto-stop
                HStack(spacing: 6) {
                    Toggle(isOn: $c.idleTTLEnabled) {
                        Text("Auto-stop when idle").font(.caption)
                    }.toggleStyle(.switch).controlSize(.mini)
                    if c.idleTTLEnabled {
                        Stepper(value: $c.idleTTLSeconds, in: 300...7200, step: 300) {
                            Text("\(c.idleTTLSeconds / 60) min")
                                .font(.caption2).foregroundStyle(.secondary)
                        }.controlSize(.mini)
                    }
                }
                if !c.idleLabel.isEmpty {
                    Text(c.idleLabel).font(.caption2).foregroundStyle(.tertiary)
                }

                // Launch at login
                Toggle(isOn: Binding(
                    get: { c.loginEnabled }, set: { _ in c.toggleLogin() })) {
                    Text("Launch at login").font(.caption)
                }.toggleStyle(.switch).controlSize(.mini)

                // Endpoint row
                HStack(spacing: 6) {
                    if editingPort {
                        Text("http://127.0.0.1:")
                            .font(.caption2).foregroundStyle(.secondary).fixedSize()
                        TextField("8080", text: $portInput)
                            .textFieldStyle(.roundedBorder).font(.caption2)
                            .frame(width: 52)
                            .onSubmit {
                                if let p = Int(portInput) { c.applyPort(p) }
                                editingPort = false
                            }
                        Text("/v1").font(.caption2).foregroundStyle(.secondary)
                        Button("Done") {
                            if let p = Int(portInput) { c.applyPort(p) }
                            editingPort = false
                        }.font(.caption2)
                    } else {
                        Text(c.endpointURL)
                            .font(.caption2).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Spacer()
                        Button {
                            c.copyEndpoint()
                        } label: { Image(systemName: "doc.on.doc") }
                            .help("Copy endpoint")
                        Button {
                            portInput = "\(c.serverPort)"
                            editingPort = true
                        } label: { Image(systemName: "pencil") }
                            .help("Edit port")
                            .disabled(c.isRunning)  // warn if running
                        if c.isRunning {
                            Text("stop first").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }.font(.caption)

                // Bottom row: log + quit
                HStack(spacing: 12) {
                    Button { c.openLog() } label: {
                        Label("Open Log", systemImage: "doc.text")
                    }
                    .help("Open server log")
                    Spacer()
                    Button { NSApplication.shared.terminate(nil) } label: {
                        Label("Quit", systemImage: "power")
                    }
                }.font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 12)
        }
        .frame(width: 300)
    }
}

// ─────────────────────────── Menu bar icon ───────────────────────────
/// "MLX" text with a colored status dot above it — same style as HermesControl.
///
/// MenuBarExtra re-tints its label as a monochrome template, stripping colors.
/// We rasterize with ImageRenderer + .renderingMode(.original) to preserve dot color.
///
/// Dot colors:
///   gray   — stopped
///   yellow — starting / up (model not loaded)
///   green  — ready (warmed up)
///   orange blink — warming up
struct MenuBarIcon: View {
    let status: ServerStatus
    let isWarming: Bool
    let blinkOn: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let image = rendered() {
            Image(nsImage: image).renderingMode(.original)
        } else {
            Text("MLX").font(.system(size: 11, weight: .bold))
        }
    }

    @MainActor private func rendered() -> NSImage? {
        let glyphColor: Color = colorScheme == .dark ? .white : .black
        let content = VStack(spacing: -2) {
            badge.frame(height: 9)
            Text("MLX")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(glyphColor)
        }
        .frame(width: 30, alignment: .center)

        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = false
        return image
    }

    @ViewBuilder private var badge: some View {
        let color: Color = {
            if isWarming { return blinkOn ? .orange : .clear }
            switch status {
            case .stopped:  return .gray
            case .starting: return .yellow
            case .up:       return .yellow
            case .ready:    return .green
            }
        }()
        Circle()
            .fill(color)
            .overlay(Circle().strokeBorder(Color.white.opacity(0.8), lineWidth: 1))
            .frame(width: 9, height: 9)
    }
}

@main
struct MLXControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var ctrl = ServerController()
    var body: some Scene {
        MenuBarExtra {
            ContentView(c: ctrl)
        } label: {
            MenuBarIcon(status: ctrl.status, isWarming: ctrl.isWarming, blinkOn: ctrl.blinkOn)
        }
        .menuBarExtraStyle(.window)
    }
}
