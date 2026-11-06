import AppKit
import SwiftUI

@main
enum MacProMonitorApp {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        if let i = arguments.firstIndex(of: "--render-icon"), i + 1 < arguments.count {
            renderStaticIcon(to: arguments[i + 1])
            return
        }
        if arguments.contains("--dump") {
            dump()
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.mainMenu = makeMenu()
        app.run()
    }

    /// Prints the second update (the first has no CPU-time deltas yet) and exits; for checking without the GUI.
    @MainActor
    private static func dump() {
        let monitor = Monitor()
        var updates = 0
        monitor.onChange = {
            if !monitor.online {
                print("offline: \(monitor.problem ?? "")")
                exit(1)
            }
            updates += 1
            guard updates == 2 else { return }
            let cpu = monitor.history.last.map { "user \(Int($0.user * 100))% sys \(Int($0.system * 100))%" } ?? "no CPU sample"
            print("\(monitor.host): \(cpu), load \(monitor.load), \(monitor.history.count) samples")
            for item in monitor.instances {
                print("\(item.busy ? "BUSY" : "idle") \(item.headless ? "headless" : "editor  ") \(item.project) | \(item.doing) | " +
                      "cpu \(Int(item.cpu))% mem \(Int(item.memoryMB)) MB up \(item.uptime) workers \(item.workers) pid \(item.pid)")
            }
            exit(0)
        }
        monitor.start()
        RunLoop.main.run()
    }

    /// The bundle's static icon, for Finder and the Dock while the app isn't running.
    @MainActor
    private static func renderStaticIcon(to path: String) {
        let history = (0..<Monitor.historyLength).map { i -> CPUSample in
            let t = Double(i) / Double(Monitor.historyLength)
            return CPUSample(user: 0.25 + 0.35 * (0.5 + 0.5 * sin(t * 9)) * t, system: 0.06 + 0.06 * (0.5 + 0.5 * cos(t * 13)))
        }
        let image = CPUHistoryIcon.render(history: history, online: true)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        bitmap.size = NSSize(width: 256, height: 256)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: 256, height: 256))
        NSGraphicsContext.restoreGraphicsState()
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    @MainActor
    private static func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Show Unity Instances", action: #selector(AppDelegate.showWindow), keyEquivalent: "0")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Mac Pro Monitor", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Mac Pro Monitor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let windowItem = NSMenuItem()
        menu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        return menu
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = Monitor()
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        monitor.onChange = { [weak self] in self?.updateIcon() }
        updateIcon()
        monitor.start()
    }

    // Clicking the Dock icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc func showWindow() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 340),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Unity on \(monitor.host)"
            window.isReleasedWhenClosed = false
            let content = NSHostingController(rootView: InstancesView(monitor: monitor))
            content.sizingOptions = [.minSize]
            window.contentViewController = content
            window.setContentSize(NSSize(width: 1000, height: 340))
            window.center()
            window.setFrameAutosaveName("UnityInstances")
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateIcon() {
        NSApp.applicationIconImage = CPUHistoryIcon.render(history: monitor.history, online: monitor.online)
    }
}

/// Activity Monitor's "CPU History" Dock icon: system time in red under user time in green, newest on the right.
enum CPUHistoryIcon {
    static func render(history: [CPUSample], online: Bool) -> NSImage {
        NSImage(size: NSSize(width: 256, height: 256), flipped: false) { rect in
            let tile = rect.insetBy(dx: 20, dy: 20)
            let shape = NSBezierPath(roundedRect: tile, xRadius: 46, yRadius: 46)
            NSGradient(starting: NSColor(white: 0.17, alpha: 1), ending: NSColor(white: 0.03, alpha: 1))?
                .draw(in: shape, angle: -90)
            NSColor(white: 0.4, alpha: 1).setStroke()
            shape.lineWidth = 3
            shape.stroke()

            let label: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
                .foregroundColor: NSColor(white: 0.75, alpha: 1)]
            NSString(string: "Mac Pro").draw(at: NSPoint(x: tile.minX + 22, y: tile.maxY - 44), withAttributes: label)

            let graph = NSRect(x: tile.minX + 18, y: tile.minY + 18, width: tile.width - 36, height: tile.height - 76)
            NSColor.black.setFill()
            graph.fill()
            NSColor(srgbRed: 0.1, green: 0.3, blue: 0.1, alpha: 1).setStroke()
            for step in 1...3 {
                let y = graph.minY + graph.height * CGFloat(step) / 4
                let line = NSBezierPath()
                line.move(to: NSPoint(x: graph.minX, y: y))
                line.line(to: NSPoint(x: graph.maxX, y: y))
                line.lineWidth = 1
                line.stroke()
            }

            let width = graph.width / CGFloat(Monitor.historyLength)
            let red = NSColor(srgbRed: 0.95, green: 0.18, blue: 0.14, alpha: 1)
            let green = NSColor(srgbRed: 0.22, green: 0.92, blue: 0.22, alpha: 1)
            for (i, sample) in history.reversed().enumerated() {
                let x = graph.maxX - CGFloat(i + 1) * width
                let system = graph.height * CGFloat(min(1, sample.system))
                let user = graph.height * CGFloat(min(1, sample.user + sample.system)) - system
                red.setFill()
                NSRect(x: x, y: graph.minY, width: width - 0.5, height: system).fill()
                green.setFill()
                NSRect(x: x, y: graph.minY + system, width: width - 0.5, height: user).fill()
            }

            if !online {
                NSColor(white: 0, alpha: 0.6).setFill()
                graph.fill()
                let text: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 30, weight: .bold),
                    .foregroundColor: NSColor(white: 0.85, alpha: 1)]
                let word = NSString(string: "offline")
                let size = word.size(withAttributes: text)
                word.draw(at: NSPoint(x: graph.midX - size.width / 2, y: graph.midY - size.height / 2), withAttributes: text)
            }
            return true
        }
    }
}

struct InstancesView: View {
    @ObservedObject var monitor: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Table(monitor.instances) {
                TableColumn("Status") { item in
                    Label(item.busy ? "Busy" : "Idle", systemImage: item.busy ? "circle.fill" : "circle")
                        .foregroundStyle(item.busy ? Color.orange : Color.secondary)
                }
                .width(min: 60, ideal: 70, max: 90)
                TableColumn("Kind") { item in Text(item.headless ? "Headless" : "Editor") }
                    .width(min: 60, ideal: 70, max: 90)
                TableColumn("Project") { item in Text(item.project).help(item.projectPath) }
                    .width(min: 120, ideal: 170)
                TableColumn("Doing") { item in
                    Text(item.workers > 0 ? "\(item.doing) · \(item.workers) import worker\(item.workers == 1 ? "" : "s")" : item.doing)
                        .help(item.doing)
                }
                .width(min: 160, ideal: 310)
                TableColumn("CPU") { item in Text("\(Int(item.cpu.rounded()))%").monospacedDigit() }
                    .width(min: 44, ideal: 54, max: 70)
                TableColumn("Memory") { item in Text(Self.memory(item.memoryMB)).monospacedDigit() }
                    .width(min: 56, ideal: 66, max: 80)
                TableColumn("Up") { item in Text(item.uptime).monospacedDigit() }
                    .width(min: 44, ideal: 60, max: 80)
                TableColumn("PID") { item in Text(String(item.pid)).monospacedDigit() }
                    .width(min: 44, ideal: 56, max: 70)
            }
            .overlay {
                if monitor.online && monitor.instances.isEmpty {
                    Text("No Unity running on \(monitor.host)").foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(minWidth: 720, idealWidth: 1000, minHeight: 200, idealHeight: 340)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(monitor.online ? Color.green : Color.red).frame(width: 8, height: 8)
            if monitor.online {
                let busy = monitor.instances.filter(\.busy).count
                let cpu = monitor.history.last.map { Int((($0.user + $0.system) * 100).rounded()) } ?? 0
                Text("\(monitor.host) · CPU \(cpu)% · load \(monitor.load) · \(monitor.instances.count) Unity, \(busy) busy")
            } else {
                Text("\(monitor.host): \(monitor.problem ?? "connecting…")").foregroundStyle(.secondary)
            }
            Spacer()
            if let updated = monitor.updated {
                Text("updated \(updated.formatted(date: .omitted, time: .standard))")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .font(.callout)
    }

    private static func memory(_ mb: Double) -> String {
        mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : "\(Int(mb)) MB"
    }
}
