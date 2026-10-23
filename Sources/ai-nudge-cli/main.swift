import Foundation

// MARK: - Files

let home = FileManager.default.homeDirectoryForCurrentUser
let configDir = home.appendingPathComponent(".config/ai-nudge-cli")
let configURL = configDir.appendingPathComponent("nudges.json")
let stateURL = configDir.appendingPathComponent("state.json")
let workDir = configDir.appendingPathComponent("workdir")
let logURL = home.appendingPathComponent("Library/Logs/ai-nudge-cli.log")
let agentLabel = "local.ai-nudge-cli"
let agentURL = home.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")

// MARK: - Model

struct Nudge: Codable {
    var name: String
    var time: String
    var days: [Int]
    var via: String              // "claude" or "codex"
    var message: String
    var model: String?
    var resume: String?          // continue this session instead of a fresh, unsaved one
    var enabled: Bool?

    var isEnabled: Bool { enabled ?? true }
}

struct Config: Codable {
    var catchUpMinutes: Int?     // how late a missed nudge may still be sent (default 180)
    var claudePath: String?      // override auto-detection
    var codexPath: String?
    var nudges: [Nudge] = []
}

func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    do { return try JSONDecoder.iso.decode(T.self, from: data) } catch {
        fail("Can't read \(url.path): \(error.localizedDescription)")
    }
}

func save<T: Encodable>(_ value: T, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let enc = JSONEncoder.iso
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try! enc.encode(value).write(to: url, options: .atomic)
}

extension JSONDecoder { static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d } }
extension JSONEncoder { static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e } }

/// sent: when each nudge last went out. armed: when it was added, edited or enabled; times before
/// that aren't caught up on.
struct State: Codable {
    var sent: [String: Date] = [:]
    var armed: [String: Date] = [:]

    mutating func arm(_ name: String) { armed[name] = Date(); save(self, to: stateURL) }
    func handled(_ name: String) -> Date { max(sent[name] ?? .distantPast, armed[name] ?? .distantPast) }
}

var config = load(Config.self, from: configURL) ?? Config()
var state = load(State.self, from: stateURL) ?? State()

// MARK: - Output

func log(_ line: String) {
    let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
    let text = "\(stamp) \(line)\n"
    if isatty(STDOUT_FILENO) == 1 { print(line) }
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
    } else {
        try? Data(text.utf8).write(to: logURL)
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("ai-nudge-cli: \(message)\n".utf8))
    exit(1)
}

// MARK: - Finding the CLIs

func executable(_ path: String) -> String? {
    let p = (path as NSString).expandingTildeInPath
    return FileManager.default.isExecutableFile(atPath: p) ? p : nil
}

func onPath(_ name: String) -> String? {
    let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        + ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
    return dirs.lazy.compactMap { executable("\($0)/\(name)") }.first
}

/// Claude Code: on PATH, or the copy the Claude desktop app keeps (newest version first).
func findClaude() -> String? {
    if let p = config.claudePath { return executable(p) }
    if let p = onPath("claude") ?? executable("~/.claude/local/claude") { return p }
    let fm = FileManager.default
    let base = home.appendingPathComponent("Library/Application Support/Claude/claude-code")
    let versions = ((try? fm.contentsOfDirectory(atPath: base.path)) ?? [])
        .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
    for v in versions {
        for build in (try? fm.contentsOfDirectory(atPath: base.appendingPathComponent(v).path)) ?? [] {
            if let p = executable(base.path + "/\(v)/\(build)/claude.app/Contents/MacOS/claude") { return p }
        }
    }
    return nil
}

/// Codex: on PATH, or the copy inside the ChatGPT desktop app.
func findCodex() -> String? {
    if let p = config.codexPath { return executable(p) }
    return onPath("codex")
        ?? executable("/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex")
        ?? executable("~/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex")
}

// MARK: - Sending

func command(for n: Nudge) -> (exe: String, args: [String])? {
    switch n.via {
    case "claude":
        guard let exe = findClaude() else { return nil }
        // No tools or MCP servers: a plain reply is all that's wanted.
        var args = ["-p", n.message, "--tools", "", "--strict-mcp-config"]
        if let m = n.model { args += ["--model", m] }
        if let r = n.resume { args += ["--resume", r] } else { args.append("--no-session-persistence") }
        return (exe, args)
    case "codex":
        guard let exe = findCodex() else { return nil }
        var args = ["exec", "--skip-git-repo-check", "--sandbox", "read-only", "--cd", workDir.path]
        if let m = n.model { args += ["--model", m] }
        if let r = n.resume { args += ["resume", r] } else { args.append("--ephemeral") }
        return (exe, args + ["--", n.message])
    default:
        return nil
    }
}

func run(_ exe: String, _ args: [String], timeout: TimeInterval = 300) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    p.currentDirectoryURL = workDir      // an empty folder, so no project files get picked up
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    p.standardInput = FileHandle.nullDevice
    try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    do { try p.run() } catch { return (-1, error.localizedDescription) }
    var data = Data()
    let reader = DispatchGroup()
    reader.enter()
    DispatchQueue.global().async { data = pipe.fileHandleForReading.readDataToEndOfFile(); reader.leave() }
    let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
    p.waitUntilExit()
    killer.cancel()
    reader.wait()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

@discardableResult
func send(_ n: Nudge, dryRun: Bool = false) -> Bool {
    guard let (exe, args) = command(for: n) else {
        log("\(n.name): \(n.via) CLI not found (see `ai-nudge-cli doctor`)")
        return false
    }
    if dryRun {
        print(([exe] + args).map { $0.isEmpty || $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " "))
        return true
    }
    let (status, output) = run(exe, args)
    let reply = output.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
    log("\(n.name): sent via \(n.via) -> \(status == 0 ? "ok" : "exit \(status)"): \(reply.prefix(200))")
    return status == 0
}

/// Sends every enabled nudge whose latest scheduled time has passed and hasn't been sent yet,
/// as long as it's within the catch-up window.
func tick(now: Date = Date()) {
    let window = TimeInterval((config.catchUpMinutes ?? 180) * 60)
    for n in config.nudges where n.isEnabled {
        guard let due = Schedule.lastOccurrence(time: n.time, days: n.days, before: now),
              now.timeIntervalSince(due) <= window,
              state.handled(n.name) < due else { continue }
        state.sent[n.name] = now      // recorded first: a failed send isn't retried in a loop
        save(state, to: stateURL)
        send(n)
    }
}

// MARK: - launchd

func selfPath() -> String {
    let p = Bundle.main.executablePath ?? CommandLine.arguments[0]
    return URL(fileURLWithPath: p).resolvingSymlinksInPath().path
}

/// One agent: wakes at every nudge time (launchd runs a missed time once after sleep) and at login.
func writeAgent() {
    let times = Set(config.nudges.filter(\.isEnabled).compactMap { Schedule.parseTime($0.time) }.map { "\($0.hour):\($0.minute)" })
    let intervals = times.sorted().map { t -> [String: Int] in
        let hm = t.split(separator: ":").map { Int($0)! }
        return ["Hour": hm[0], "Minute": hm[1]]
    }
    let plist: [String: Any] = [
        "Label": agentLabel,
        "ProgramArguments": [selfPath(), "tick"],
        "StartCalendarInterval": intervals,
        "RunAtLoad": true,
        "StandardOutPath": logURL.path,
        "StandardErrorPath": logURL.path,
        "ProcessType": "Background",
    ]
    let data = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try? FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! data.write(to: agentURL, options: .atomic)
}

func launchctl(_ args: String...) -> Int32 {
    run("/bin/launchctl", args, timeout: 20).status
}

func reloadAgent() {
    let domain = "gui/\(getuid())"
    _ = launchctl("bootout", "\(domain)/\(agentLabel)")
    for _ in 0..<5 {    // bootout finishes asynchronously
        if launchctl("bootstrap", domain, agentURL.path) == 0 { return }
        Thread.sleep(forTimeInterval: 0.5)
    }
    fail("launchctl couldn't load \(agentURL.path)")
}

var agentInstalled: Bool { FileManager.default.fileExists(atPath: agentURL.path) }

/// After any change: save, and keep the agent's wake-up times in step.
func commit() {
    save(config, to: configURL)
    if agentInstalled { writeAgent(); reloadAgent() }
}

// MARK: - Commands

let usage = """
ai-nudge-cli: send a message to Claude Code or Codex at set times, to start your usage window early.

  ai-nudge-cli add NAME --at HH:MM [--days daily|weekdays|weekends|mon,wed,...]
                        [--via claude|codex] [--message TEXT] [--model MODEL] [--resume SESSION_ID]
  ai-nudge-cli edit NAME [same options] [--no-resume]
  ai-nudge-cli remove NAME | enable NAME | disable NAME
  ai-nudge-cli list
  ai-nudge-cli send NAME [--dry-run]      send it now
  ai-nudge-cli install | uninstall        start or stop sending on schedule (a launchd agent)
  ai-nudge-cli doctor                     show which CLIs were found and whether they're logged in
  ai-nudge-cli log                        recent activity
  ai-nudge-cli version

Defaults: --days daily, --via claude, --message "hi". Settings live in \(configURL.path)
"""

var args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { print(usage); exit(0) }
args.removeFirst()

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name) else { return nil }
    guard i + 1 < args.count else { fail("\(name) needs a value") }
    return args[i + 1]
}
func flag(_ name: String) -> Bool { args.contains(name) }

func nameArg() -> String {
    guard let n = args.first, !n.hasPrefix("--") else { fail("give the nudge a name, e.g. `ai-nudge-cli \(cmd) morning`") }
    return n
}

func index(of name: String) -> Int {
    guard let i = config.nudges.firstIndex(where: { $0.name == name }) else { fail("no nudge called \"\(name)\"") }
    return i
}

/// Applies --at/--days/--via/... to a nudge, validating as it goes.
func apply(to n: inout Nudge) {
    if let t = option("--at") {
        guard let hm = Schedule.parseTime(t) else { fail("--at wants HH:MM (24-hour), got \"\(t)\"") }
        n.time = String(format: "%02d:%02d", hm.hour, hm.minute)
    }
    if let d = option("--days") {
        guard let days = Schedule.parseDays(d) else { fail("--days wants daily, weekdays, weekends or e.g. mon,wed,fri") }
        n.days = days
    }
    if let v = option("--via") {
        guard ["claude", "codex"].contains(v) else { fail("--via is claude or codex") }
        n.via = v
    }
    if let m = option("--message") ?? option("-m") { n.message = m }
    if let m = option("--model") { n.model = m.isEmpty ? nil : m }
    if let r = option("--resume") { n.resume = r }
    if flag("--no-resume") { n.resume = nil }
}

func describe(_ n: Nudge) -> String {
    let next = Schedule.nextOccurrence(time: n.time, days: n.days, after: Date())
        .map { $0.formatted(.dateTime.weekday(.abbreviated).hour().minute()) } ?? "-"
    let last = state.sent[n.name].map { $0.formatted(.dateTime.day().month(.abbreviated).hour().minute()) } ?? "never"
    var target = n.via + (n.model.map { " (\($0))" } ?? "")
    if let r = n.resume { target += ", session \(r.prefix(8))" }
    return "\(n.isEnabled ? "●" : "○") \(n.name)  \(n.time) \(Schedule.describeDays(n.days))  -> \(target)\n"
        + "    \"\(n.message)\"  next: \(n.isEnabled ? next : "off")  last sent: \(last)"
}

switch cmd {
case "add":
    let name = nameArg()
    if config.nudges.contains(where: { $0.name == name }) { fail("\"\(name)\" exists; use `edit`") }
    guard option("--at") != nil else { fail("add needs --at HH:MM") }
    var n = Nudge(name: name, time: "", days: Array(1...7), via: "claude", message: "hi")
    apply(to: &n)
    config.nudges.append(n)
    state.arm(name)     // don't "catch up" a time that already passed today
    commit()
    print(describe(n))
    if !agentInstalled { print("\nRun `ai-nudge-cli install` to start sending on schedule.") }

case "edit":
    let i = index(of: nameArg())
    apply(to: &config.nudges[i])
    state.arm(config.nudges[i].name)
    commit()
    print(describe(config.nudges[i]))

case "remove", "rm":
    let i = index(of: nameArg())
    let gone = config.nudges.remove(at: i).name
    state.sent[gone] = nil
    state.armed[gone] = nil
    save(state, to: stateURL)
    commit()

case "enable", "disable":
    let i = index(of: nameArg())
    config.nudges[i].enabled = cmd == "enable"
    if cmd == "enable" { state.arm(config.nudges[i].name) }
    commit()
    print(describe(config.nudges[i]))

case "list", "ls":
    if config.nudges.isEmpty { print("No nudges yet. Try: ai-nudge-cli add morning --at 06:00 --message \"hi\"") }
    config.nudges.forEach { print(describe($0)) }
    print(agentInstalled ? "\nScheduled (launchd agent installed)." : "\nNot scheduled: run `ai-nudge-cli install`.")

case "send":
    let n = config.nudges[index(of: nameArg())]
    if send(n, dryRun: flag("--dry-run")), !flag("--dry-run") { state.sent[n.name] = Date(); save(state, to: stateURL) }

case "tick":
    tick()

case "install":
    if selfPath().contains("/.build/") {
        print("Note: scheduling \(selfPath()); `make install` puts a stable copy in ~/.local/bin first.")
    }
    writeAgent()
    reloadAgent()
    print("Installed. Nudges will be sent on schedule while you're logged in (missed ones within \(config.catchUpMinutes ?? 180) min are sent on wake).")

case "uninstall":
    _ = launchctl("bootout", "gui/\(getuid())/\(agentLabel)")
    try? FileManager.default.removeItem(at: agentURL)
    print("Uninstalled. Your nudges are kept in \(configURL.path).")

case "doctor":
    for (name, path, status) in [("claude", findClaude(), ["auth", "status"]), ("codex", findCodex(), ["login", "status"])] {
        guard let path else { print("✗ \(name): not found"); continue }
        let out = run(path, status, timeout: 20).output
        let ok = out.contains("\"loggedIn\": true") || out.localizedCaseInsensitiveContains("logged in using")
        print("\(ok ? "✓" : "✗") \(name): \(path)\n    \(ok ? "logged in" : "not logged in: run `\(path) \(name == "claude" ? "auth login" : "login")`")")
    }
    print(agentInstalled ? "✓ launchd agent installed" : "✗ launchd agent not installed (`ai-nudge-cli install`)")

case "log":
    let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
    print(text.split(separator: "\n").suffix(30).joined(separator: "\n"))

case "version", "--version":
    print("ai-nudge-cli 0.1.1")

case "help", "-h", "--help":
    print(usage)

default:
    fail("unknown command \"\(cmd)\"\n\n\(usage)")
}
