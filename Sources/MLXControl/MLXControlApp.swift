import SwiftUI
import ServiceManagement

// ─────────────────────────── 설정 ───────────────────────────
enum Config {
    static let host = "127.0.0.1"
    static let port = 8080
    static var baseURL: String { "http://\(host):\(port)/v1" }

    static let hubPath = ("~/.cache/huggingface/hub" as NSString).expandingTildeInPath
    static let logPath: String = {
        let dir = ("~/Library/Logs/MLXControl" as NSString).expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "/mlx_server.log"
    }()

    /// PATH를 탐색해 mlx_lm.server 바이너리를 찾는다.
    static let serverBin: String? = findBin("mlx_lm.server")
    /// PATH를 탐색해 hf(huggingface_hub CLI) 바이너리를 찾는다.
    static let hfBin: String? = findBin("hf")

    static let fallbackModels = ["mlx-community/Qwen3-32B-4bit"]
    static let ramWarnGB = 36.0
    static let freeWarnGB = 6.0
    static let alertCooldown = 120.0
    static let historyLen = 40

    private static func findBin(_ name: String) -> String? {
        // 공통 설치 위치를 우선 탐색한 뒤 PATH 순회
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

enum ServerStatus { case stopped, starting, up, warming, ready }

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

// ─────────────────────────── 셸 헬퍼 ───────────────────────────
// 항상 Process 인자 배열로 실행 — 셸 인터폴레이션 없음.
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

func firstMatch(_ pattern: String, in text: String) -> String? {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
    let r = NSRange(text.startIndex..., in: text)
    guard let m = re.firstMatch(in: text, range: r), m.numberOfRanges > 1,
          let g = Range(m.range(at: 1), in: text) else { return nil }
    return String(text[g])
}

func allMatches(_ pattern: String, _ text: String) -> [String] {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
    let r = NSRange(text.startIndex..., in: text)
    return re.matches(in: text, range: r).compactMap {
        Range($0.range(at: 1), in: text).map { String(text[$0]) }
    }
}

// UserNotifications 대신 AppleScript — 단, 모든 인자를 리스트로 분리해 주입 차단
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

// ─────────────── /Applications 설치 유도 (첫 실행) ───────────────
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
        alert.messageText = "응용 프로그램 폴더로 설치할까요?"
        alert.informativeText = "MLX Control을 /Applications 로 옮기면 로그인 시 자동 실행이 안정적으로 동작합니다."
        alert.addButton(withTitle: "설치하고 재실행")
        alert.addButton(withTitle: "나중에")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "다시 묻지 않기"
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
            // 권한 부족 시 NSWorkspace AuthorizationAPI로 올려서 복사
            // (AppleScript 문자열 주입 없이 인자 배열로만 처리)
            let rm = Process(); rm.executableURL = URL(fileURLWithPath: "/bin/rm")
            rm.arguments = ["-rf", dest]
            try? rm.run(); rm.waitUntilExit()
            let cp = Process(); cp.executableURL = URL(fileURLWithPath: "/bin/cp")
            cp.arguments = ["-R", src, dest]
            try? cp.run(); cp.waitUntilExit()
            guard fm.fileExists(atPath: dest) else {
                notify("⚡ MLX Control", "설치 실패", error.localizedDescription)
                return
            }
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        // Process 인자 배열 — 셸 문자열 인터폴레이션 없음
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

// ─────────────────────────── 컨트롤러 ───────────────────────────
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
    var toolsWarning: String? = nil    // mlx-lm 미설치 안내

    @ObservationIgnored private var warmedUp = false
    @ObservationIgnored private var alertedRAM = false
    @ObservationIgnored private var alertedFree = false
    @ObservationIgnored private var lastRAMAlert = Date.distantPast
    @ObservationIgnored private var lastFreeAlert = Date.distantPast

    var isRunning: Bool { status != .stopped }

    init() {
        sysTotalGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        checkTools()
        models = detectModels()
        selectedModel = models.first ?? Config.fallbackModels[0]
        loginEnabled = SMAppService.mainApp.status == .enabled
        refresh()
        Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(3))
                guard let self else { break }
                self.refresh()
            }
        }
    }

    private func checkTools() {
        if Config.serverBin == nil {
            toolsWarning = "mlx_lm.server 를 찾을 수 없습니다.\n설치: pip install mlx-lm"
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
        case .warming: return "Warming up…"
        case .ready: return "Ready"
        }
    }

    var statusColor: Color {
        if isWarming { return .orange }
        switch status {
        case .stopped: return .gray
        case .starting, .warming: return .orange
        case .up: return .yellow
        case .ready: return .green
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

    func refresh() {
        let pidStr = sh("/usr/bin/pgrep", ["-f", "mlx_lm.server"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let foundPid = pidStr.split(separator: "\n").first.flatMap { Int($0) }
        pid = foundPid

        if let pid = foundPid {
            let cmd = sh("/bin/ps", ["-o", "command=", "-p", "\(pid)"])
            if let m = firstMatch("--model\\s+(\\S+)", in: cmd) { model = m }
            let stat = sh("/bin/ps", ["-o", "rss=,%cpu=", "-p", "\(pid)"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = stat.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if parts.count >= 2 {
                ramGB = (Double(parts[0]) ?? 0) / 1_048_576
                cpu = Double(parts[1]) ?? 0
            }
            uptime = sh("/bin/ps", ["-o", "etime=", "-p", "\(pid)"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let httpUp = pingHTTP()
            status = httpUp ? (warmedUp ? .ready : .up) : .starting
            readTPS()
        } else {
            status = .stopped; model = ""; ramGB = 0; cpu = 0; uptime = ""
            warmedUp = false; tps = nil
        }
        readGPU()
        readSystemMemory()
        checkAlerts()
    }

    private func pingHTTP() -> Bool {
        let code = sh("/usr/bin/curl",
            ["-s", "-m", "1", "-o", "/dev/null", "-w", "%{http_code}",
             "http://\(Config.host):\(Config.port)/v1/models"])
        return code.trimmingCharacters(in: .whitespacesAndNewlines) == "200"
    }

    private func readGPU() {
        let io = sh("/usr/sbin/ioreg", ["-r", "-d", "1", "-w", "0", "-c", "IOAccelerator"])
        let utils = allMatches("\"Device Utilization %\"=(\\d+)", io).compactMap { Int($0) }
        let mems = allMatches("\"In use system memory\"=(\\d+)", io).compactMap { Double($0) }
        gpuUtil = utils.max()
        gpuMemGB = mems.max().map { $0 / 1_073_741_824 }
        gpuHistory.append(Double(gpuUtil ?? 0))
        if gpuHistory.count > Config.historyLen { gpuHistory.removeFirst() }
    }

    private func readSystemMemory() {
        let v = sh("/usr/bin/vm_stat", [])
        let pageSize = Double(firstMatch("page size of (\\d+) bytes", in: v) ?? "16384") ?? 16384
        func pages(_ key: String) -> Double {
            Double(firstMatch("\(key):\\s+(\\d+)", in: v) ?? "0") ?? 0
        }
        let used = (pages("Pages active") + pages("Pages wired down")
                    + pages("Pages occupied by compressor")) * pageSize
        sysUsedGB = used / 1_073_741_824
    }

    private func readTPS() {
        let tail = sh("/usr/bin/tail", ["-n", "60", Config.logPath])
        if let s = firstMatch("Generation:.*?([0-9.]+) tokens-per-sec", in: tail)
            ?? firstMatch("([0-9.]+) tokens-per-sec", in: tail)
            ?? firstMatch("([0-9.]+) tok/sec", in: tail) {
            tps = Double(s)
        }
    }

    private func checkAlerts() {
        let now = Date()
        if isRunning && ramGB >= Config.ramWarnGB {
            if !alertedRAM && now.timeIntervalSince(lastRAMAlert) > Config.alertCooldown {
                notify("⚡ MLX 리소스 경고",
                       String(format: "MLX RAM %.1f GB", ramGB),
                       "임계치 \(Int(Config.ramWarnGB)) GB 초과")
                lastRAMAlert = now; alertedRAM = true
            }
        } else if ramGB < Config.ramWarnGB * 0.9 { alertedRAM = false }

        let free = sysTotalGB - sysUsedGB
        if free <= Config.freeWarnGB {
            if !alertedFree && now.timeIntervalSince(lastFreeAlert) > Config.alertCooldown {
                notify("⚡ 메모리 부족 경고",
                       String(format: "여유 RAM %.1f GB", free),
                       "임계치 \(Int(Config.freeWarnGB)) GB 밑 — 스왑 위험")
                lastFreeAlert = now; alertedFree = true
            }
        } else if free > Config.freeWarnGB * 1.2 { alertedFree = false }
    }

    // ── 서버 제어 ──
    private func launchServer() {
        guard let bin = Config.serverBin else {
            notify("⚡ MLX Control", "실행 실패", "mlx_lm.server 를 찾을 수 없음. pip install mlx-lm")
            return
        }
        // Process 인자 배열 직접 실행 — zsh -lc 문자열 인터폴레이션 없음
        let log = Config.logPath
        guard let logHandle = FileHandle(forWritingAtPath: log) ??
              ({ FileManager.default.createFile(atPath: log, contents: nil); return FileHandle(forWritingAtPath: log) }())
        else { return }
        logHandle.seekToEndOfFile()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["--model", selectedModel, "--host", Config.host, "--port", "\(Config.port)"]
        p.standardOutput = logHandle
        p.standardError = logHandle
        p.qualityOfService = .userInitiated
        try? p.run()
    }

    func start() {
        guard !isRunning, !busy else { return }
        guard Config.serverBin != nil else {
            notify("⚡ MLX Control", "실행 실패", "mlx_lm.server 를 찾을 수 없음. pip install mlx-lm")
            return
        }
        busy = true; warmedUp = false
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

    // ── 모델 추가 / 삭제 ──
    func downloadModel(_ repo: String) {
        let r = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty, downloading == nil else { return }
        guard Config.hfBin != nil else {
            notify("⚡ MLX Control", "다운로드 실패", "hf CLI 를 찾을 수 없음. pip install huggingface_hub")
            return
        }
        downloading = r
        Task { @MainActor in
            let ok = await Self.runDownload(r)
            self.downloading = nil
            self.models = self.detectModels()
            notify("⚡ MLX Control", ok ? "다운로드 완료" : "다운로드 실패", r)
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
            notify("⚡ MLX Control", "삭제 불가", "실행 중인 모델 — 먼저 Stop 하세요")
            return
        }
        // 경로 검증: repo가 HF id 형식(영숫자/하이픈/언더스코어/점/슬래시)인지 확인
        let validID = repo.range(of: #"^[A-Za-z0-9._\-]+(\/[A-Za-z0-9._\-]+)?$"#,
                                  options: .regularExpression) != nil
        guard validID else {
            notify("⚡ MLX Control", "삭제 실패", "잘못된 모델 ID")
            return
        }
        let dirName = "models--" + repo.replacingOccurrences(of: "/", with: "--")
        let dir = (Config.hubPath as NSString).appendingPathComponent(dirName)
        // hub 디렉토리 안에만 삭제 허용 (경로 탈출 방지)
        guard dir.hasPrefix(Config.hubPath + "/") else { return }

        let alert = NSAlert()
        alert.messageText = "모델 삭제"
        alert.informativeText = "\(repo)\n\n확보될 용량: 약 \(folderSize(dir))\n디스크 캐시에서 완전히 제거됩니다."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "삭제")
        alert.addButton(withTitle: "취소")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if FileManager.default.fileExists(atPath: dir) {
            // Process 인자 배열 — 셸 문자열 인터폴레이션 없음
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

    // ── 모델 검색 (HuggingFace) ──
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

    // ── 기타 ──
    func copyEndpoint() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Config.baseURL, forType: .string)
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
            notify("⚡ MLX Control", "로그인 항목 실패", error.localizedDescription)
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
            }.foregroundStyle(.secondary)
            if let m = hit.descr { Text(m).font(.caption).foregroundStyle(.tertiary) }
            Divider()
            ScrollView {
                Text(hit.prose ?? "설명이 없습니다.")
                    .font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 150)
            Divider()
            HStack {
                if c.models.contains(hit.id) {
                    Label("설치됨", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.caption)
                } else {
                    Button { c.downloadModel(hit.id); detail = nil } label: {
                        Label("다운로드", systemImage: "arrow.down.circle")
                    }.disabled(c.downloading != nil)
                }
                Spacer()
                Button { c.openModelPage(hit.id) } label: {
                    Label("HF에서 열기", systemImage: "safari")
                }.font(.caption)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    var mainView: some View {
        VStack(alignment: .leading, spacing: 9) {
            // 도구 미설치 경고
            if let w = c.toolsWarning {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(w).font(.caption2).foregroundStyle(.secondary)
                }
                .padding(8).background(.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack(spacing: 8) {
                Circle().fill(c.statusColor).frame(width: 9, height: 9)
                Text("MLX Server").font(.headline)
                Spacer()
                Text(c.statusText).font(.caption).foregroundStyle(.secondary)
            }
            if c.isRunning {
                HStack {
                    Text(c.model.replacingOccurrences(of: "mlx-community/", with: ""))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if !c.uptime.isEmpty {
                        Text("up \(c.uptime)").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }

            Divider()

            Text("MLX 프로세스").font(.caption2).foregroundStyle(.secondary)
            StatRow("RAM", c.isRunning ? String(format: "%.1f GB", c.ramGB) : "—",
                    warn: c.ramGB >= Config.ramWarnGB)
            StatRow("CPU", c.isRunning ? String(format: "%.0f %%", c.cpu) : "—")
            StatRow("Speed", c.tps.map { String(format: "%.1f tok/s", $0) } ?? "—")

            Text("시스템 GPU (전체 합산)").font(.caption2).foregroundStyle(.secondary).padding(.top, 2)
            StatRow("GPU", c.gpuUtil.map { "\($0) %" } ?? "—", warn: (c.gpuUtil ?? 0) >= 90)
            Sparkline(data: c.gpuHistory)
            StatRow("GPU mem", c.gpuMemGB.map { String(format: "%.1f GB", $0) } ?? "—")
            StatRow("System RAM",
                    String(format: "%.0f / %.0f GB", c.sysUsedGB, c.sysTotalGB),
                    warn: c.sysTotalGB > 0 && c.sysUsedGB / c.sysTotalGB > 0.9)

            Divider()

            HStack {
                Picker("Model", selection: Binding(
                    get: { c.selectedModel },
                    set: { c.switchModel($0) }
                )) {
                    ForEach(c.models, id: \.self) { m in
                        Text(m.replacingOccurrences(of: "mlx-community/", with: "")).tag(m)
                    }
                }.pickerStyle(.menu).labelsHidden()
                Button { c.deleteModel(c.selectedModel) } label: { Image(systemName: "trash") }
                    .disabled(c.models.count <= 1 || c.downloading != nil)
                    .help("선택한 모델 삭제")
            }

            HStack(spacing: 6) {
                TextField("모델 검색 (예: llama 3b, qwen coder)", text: $query)
                    .textFieldStyle(.roundedBorder).font(.caption)
                    .onSubmit { c.searchModels(query) }
                Button { c.searchModels(query) } label: { Image(systemName: "magnifyingglass") }
                    .disabled(c.searching || query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if c.searching {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("검색 중…").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if !c.searchResults.isEmpty {
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(c.searchResults) { hit in
                            HStack {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(hit.id.replacingOccurrences(of: "mlx-community/", with: ""))
                                        .font(.caption).lineLimit(1)
                                    Text("↓ \(hit.downloads)  ·  \(humanSize(hit.sizeBytes))")
                                        .font(.caption2).foregroundStyle(.secondary)
                                    if let d = hit.descr {
                                        Text(d).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                                    }
                                    if let p = hit.prose {
                                        Text(p).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                                .contentShape(Rectangle())
                                .onTapGesture { detail = hit }
                                Spacer()
                                if c.models.contains(hit.id) {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                } else {
                                    Button { c.downloadModel(hit.id) } label: {
                                        Image(systemName: "arrow.down.circle")
                                    }.buttonStyle(.borderless).disabled(c.downloading != nil)
                                }
                            }
                            .padding(.vertical, 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.frame(maxWidth: .infinity)
                }
                .frame(height: 220)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            if let dl = c.downloading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("downloading \(dl.replacingOccurrences(of: "mlx-community/", with: ""))…")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            HStack {
                if c.isRunning {
                    Button { c.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    Button { c.restart() } label: { Label("Restart", systemImage: "arrow.clockwise") }
                    Button { c.warmUp() } label: { Label("Warm", systemImage: "flame.fill") }
                        .disabled((c.status != .up && c.status != .ready) || c.isWarming)
                } else {
                    Button { c.start() } label: { Label("Start", systemImage: "play.fill") }
                }
                Spacer()
                if c.busy || c.isWarming { ProgressView().controlSize(.small) }
            }

            Divider()

            HStack {
                Button { c.copyEndpoint() } label: { Label("Copy endpoint", systemImage: "doc.on.doc") }
                Spacer()
                Button { c.openLog() } label: { Image(systemName: "doc.text") }
            }.font(.caption)

            Toggle(isOn: Binding(get: { c.loginEnabled }, set: { _ in c.toggleLogin() })) {
                Text("로그인 시 자동 실행").font(.caption)
            }.toggleStyle(.switch).controlSize(.mini)

            HStack {
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }.font(.caption)
            }
        }
        .padding(14)
        .frame(width: 290)
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
            HStack(spacing: 3) {
                Image(systemName: ctrl.isRunning ? "bolt.fill" : "bolt.slash")
                Text(ctrl.barTitle)
            }
        }
        .menuBarExtraStyle(.window)
    }
}
