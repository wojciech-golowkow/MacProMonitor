import Foundation

struct CPUSample {
    var user: Double
    var system: Double
}

struct UnityInstance: Identifiable {
    let pid: Int
    var id: Int { pid }
    let headless: Bool
    let projectPath: String
    let doing: String
    /// Percent of one core across its whole process tree (import workers, compilers).
    let cpu: Double
    let memoryMB: Double
    let uptime: String
    let workers: Int

    var project: String { projectPath.isEmpty ? "—" : (projectPath as NSString).lastPathComponent }
    var busy: Bool { cpu >= Monitor.busyThreshold }
}

/// Streams the remote machine's CPU split and its Unity processes over one long-lived ssh connection.
@MainActor
final class Monitor: ObservableObject {
    nonisolated static let busyThreshold = 15.0
    nonisolated static let historyLength = 60

    @Published private(set) var history: [CPUSample] = []
    @Published private(set) var instances: [UnityInstance] = []
    @Published private(set) var online = false
    @Published private(set) var load = ""
    @Published private(set) var updated: Date?
    @Published private(set) var problem: String?

    var onChange: (() -> Void)?

    let host: String
    private let identityFile: String
    /// Environment variables of headless runs shown in the Doing column, with their display labels.
    private let environmentKeys: [String]
    private let environmentLabels: [String: String]
    private var buffer = Data()
    private var block: [String] = []
    private var cpuTimes: [Int: (seconds: Double, at: Date)] = [:]

    /// Settings come from the bundle's Info.plist, which build.sh fills in from .env; `defaults write` overrides them.
    init() {
        let defaults = UserDefaults.standard
        let info = Bundle.main.infoDictionary ?? [:]
        func setting(_ key: String, _ plistKey: String) -> String {
            (defaults.string(forKey: key) ?? info[plistKey] as? String ?? "").trimmingCharacters(in: .whitespaces)
        }
        host = setting("host", "MPMRemoteHost")
        let identity = setting("identityFile", "MPMIdentityFile")
        identityFile = identity.isEmpty ? "" : NSString(string: identity).expandingTildeInPath
        var keys: [String] = []
        for key in setting("unityEnvKeys", "MPMUnityEnvKeys").split(separator: " ").map(String.init)
        where key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil && !keys.contains(key) {
            keys.append(key)
        }
        environmentKeys = keys
        environmentLabels = Self.labels(for: keys)
    }

    // Parsed in full before it runs, so commands reading stdin can't eat the rest of the script.
    private var remoteScript: String {
        var script = #"""
        while :; do
          print -r -- "CPU $(top -l 2 -s 1 -n 0 | grep 'CPU usage' | tail -1)"
          print -r -- "LOAD $(sysctl -n vm.loadavg)"
          ps -Aww -o pid=,ppid=,%cpu=,time=,rss=,etime=,command= | grep '[U]nity.app/Contents/MacOS/Unity' | sed 's/^ */P /'
          ps -A -o pid=,ppid=,%cpu=,time= | sed 's/^ */A /'

        """#
        if !environmentKeys.isEmpty {
            script += #"""
              for pid in $(ps -Aww -o pid=,command= | grep '[U]nity.app/Contents/MacOS/Unity .*-batchmode' | awk '{print $1}'); do
                print -r -- "ENV $pid $(ps -Eww -p $pid -o command= | grep -o -E '(^| )(\#(environmentKeys.joined(separator: "|")))=[^ ]*' | tr '\n' ' ')"
              done

            """#
        }
        return script + "  print END\n  sleep 1\ndone\n"
    }

    func start() {
        guard !host.isEmpty else {
            problem = "no host set: fill in REMOTE_HOST in .env and rebuild"
            onChange?()
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = (identityFile.isEmpty ? [] : ["-i", identityFile])
            + ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3",
               host, "/bin/zsh -s"]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            DispatchQueue.main.async { self?.receive(data) }
        }
        process.terminationHandler = { [weak self] _ in
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            DispatchQueue.main.async { self?.stopped(message) }
        }

        do {
            try process.run()
        } catch {
            stopped(error.localizedDescription)
            return
        }
        input.fileHandleForWriting.write(Data(remoteScript.utf8))
        try? input.fileHandleForWriting.close()
    }

    private func stopped(_ message: String) {
        online = false
        let lastLine = message.split(separator: "\n").last.map(String.init) ?? ""
        problem = lastLine.isEmpty ? "ssh to \(host) ended" : lastLine
        buffer.removeAll()
        block.removeAll()
        onChange?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.start() }
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...newline)
            if line == "END" {
                apply(block)
                block.removeAll()
            } else {
                block.append(line)
            }
        }
    }

    private struct Row {
        let pid: Int, ppid: Int, pcpu: Double, cpuSeconds: Double, rssKB: Double, etime: String, command: String
    }

    private func apply(_ lines: [String]) {
        let now = Date()
        var rows: [Row] = []
        var all: [(pid: Int, ppid: Int, pcpu: Double, cpuSeconds: Double)] = []
        var environment: [Int: String] = [:]

        for line in lines {
            if line.hasPrefix("CPU ") {
                if let sample = Self.parseCPU(line) {
                    history.append(sample)
                    if history.count > Self.historyLength {
                        history.removeFirst(history.count - Self.historyLength)
                    }
                }
            } else if line.hasPrefix("LOAD ") {
                load = line.dropFirst(5).split(separator: " ").filter { $0 != "{" && $0 != "}" }.prefix(3).joined(separator: " ")
            } else if line.hasPrefix("ENV ") {
                let parts = line.dropFirst(4).split(separator: " ", maxSplits: 1)
                if let pid = parts.first.flatMap({ Int($0) }) {
                    environment[pid] = parts.count > 1 ? String(parts[1]) : ""
                }
            } else if line.hasPrefix("P ") {
                let f = line.dropFirst(2).split(separator: " ", maxSplits: 6, omittingEmptySubsequences: true)
                guard f.count == 7, let pid = Int(f[0]), let ppid = Int(f[1]) else { continue }
                rows.append(Row(pid: pid, ppid: ppid, pcpu: Double(f[2]) ?? 0, cpuSeconds: Self.seconds(f[3]),
                                rssKB: Double(f[4]) ?? 0, etime: String(f[5]), command: String(f[6])))
            } else if line.hasPrefix("A ") {
                let f = line.dropFirst(2).split(separator: " ", omittingEmptySubsequences: true)
                guard f.count == 4, let pid = Int(f[0]), let ppid = Int(f[1]) else { continue }
                all.append((pid, ppid, Double(f[2]) ?? 0, Self.seconds(f[3])))
            }
        }

        // ps %cpu is a decaying average, so a process's own CPU-time delta is used once there are two samples.
        var cpuNow: [Int: Double] = [:]
        var seen: [Int: (seconds: Double, at: Date)] = [:]
        var children: [Int: [Int]] = [:]
        for process in all {
            if let last = cpuTimes[process.pid], now.timeIntervalSince(last.at) > 0.5 {
                cpuNow[process.pid] = max(0, (process.cpuSeconds - last.seconds) / now.timeIntervalSince(last.at) * 100)
            } else {
                cpuNow[process.pid] = process.pcpu
            }
            seen[process.pid] = (process.cpuSeconds, now)
            children[process.ppid, default: []].append(process.pid)
        }
        cpuTimes = seen

        // Compiles, imports and shader builds run in child processes, so an editor's load is its whole process tree.
        func treeCPU(_ pid: Int) -> Double {
            (cpuNow[pid] ?? 0) + (children[pid] ?? []).reduce(0) { $0 + treeCPU($1) }
        }

        let isWorker = { (row: Row) in row.command.contains("AssetImportWorker") }
        let workers = Dictionary(grouping: rows.filter(isWorker), by: \.ppid)
        instances = rows.filter { !isWorker($0) }.map { row in
            let own = workers[row.pid] ?? []
            let lower = row.command.lowercased()
            return UnityInstance(
                pid: row.pid,
                headless: lower.contains("-batchmode") || lower.contains("-nographics"),
                projectPath: Self.argument(after: "-projectpath", in: row.command) ?? "",
                doing: describe(row.command, environment: environment[row.pid]),
                cpu: treeCPU(row.pid),
                memoryMB: (row.rssKB + own.reduce(0) { $0 + $1.rssKB }) / 1024,
                uptime: Self.uptime(row.etime),
                workers: own.count)
        }.sorted { ($0.busy ? 1 : 0, $0.cpu) > ($1.busy ? 1 : 0, $1.cpu) }

        online = true
        problem = nil
        updated = now
        onChange?()
    }

    // "CPU CPU usage: 12.34% user, 5.67% sys, 81.99% idle"
    private static func parseCPU(_ line: String) -> CPUSample? {
        func percent(_ label: String) -> Double? {
            guard let range = line.range(of: "% \(label)") else { return nil }
            let number = line[..<range.lowerBound].split(separator: " ").last ?? ""
            return Double(number).map { $0 / 100 }
        }
        guard let user = percent("user"), let system = percent("sys") else { return nil }
        return CPUSample(user: user, system: system)
    }

    // ps cputime: [[dd-]hh:]mm:ss.cc
    private static func seconds(_ text: Substring) -> Double {
        var days = 0.0
        var rest = text
        if let dash = text.firstIndex(of: "-") {
            days = Double(text[..<dash]) ?? 0
            rest = text[text.index(after: dash)...]
        }
        let total = rest.split(separator: ":").reduce(0.0) { $0 * 60 + (Double($1) ?? 0) }
        return days * 86_400 + total
    }

    private static func uptime(_ etime: String) -> String {
        let seconds = Int(Self.seconds(Substring(etime)))
        let (d, h, m) = (seconds / 86_400, seconds % 86_400 / 3600, seconds % 3600 / 60)
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return m > 0 ? "\(m)m" : "\(seconds)s"
    }

    private static func argument(after flag: String, in command: String) -> String? {
        let tokens = command.split(separator: " ")
        guard let i = tokens.firstIndex(where: { $0.lowercased() == flag }), i + 1 < tokens.count else { return nil }
        return String(tokens[i + 1])
    }

    private func describe(_ command: String, environment: String?) -> String {
        var text: String
        if command.contains("-runTests") {
            text = Self.argument(after: "-testfilter", in: command)
                .map { $0.split(separator: ".").suffix(2).joined(separator: ".") }
                ?? "\(Self.argument(after: "-testplatform", in: command) ?? "") tests"
        } else if let method = Self.argument(after: "-executemethod", in: command) {
            text = "Method \(method)"
        } else if command.lowercased().contains("-quit") {
            text = "Batch run (import, then quit)"
        } else {
            text = command.lowercased().contains("-batchmode") ? "Batch mode" : "Editor"
        }

        // The configured variables in their configured order; a path shows as its file name.
        let values = Dictionary((environment ?? "").split(separator: " ").compactMap { pair -> (String, String)? in
            let kv = pair.split(separator: "=", maxSplits: 1)
            return kv.count == 2 ? (String(kv[0]), String(kv[1])) : nil
        }, uniquingKeysWith: { first, _ in first })
        let parts = environmentKeys.compactMap { key -> String? in
            guard let value = values[key] else { return nil }
            let shown = value.contains("/") ? ((value as NSString).lastPathComponent as NSString).deletingPathExtension : value
            return "\(environmentLabels[key] ?? key) \(shown)"
        }
        if !parts.isEmpty { text += " · " + parts.joined(separator: " · ") }
        return text
    }

    /// Lower-cased names without the prefix they all share, so CI_RUN_LEVEL and CI_RUN_MODE read "level" and "mode".
    private static func labels(for keys: [String]) -> [String: String] {
        var prefix = keys.count > 1 ? keys[0] : ""
        for key in keys.dropFirst() {
            while !key.hasPrefix(prefix) { prefix.removeLast() }
        }
        prefix = prefix.lastIndex(of: "_").map { String(prefix[...$0]) } ?? ""
        return Dictionary(keys.map { ($0, String($0.dropFirst(prefix.count)).lowercased()) }, uniquingKeysWith: { first, _ in first })
    }
}
