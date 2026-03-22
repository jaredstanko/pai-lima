import Cocoa

// MARK: - VM State

enum VMState: String {
    case running = "Running"
    case stopped = "Stopped"
    case starting = "Starting…"
    case stopping = "Stopping…"
    case unknown = "Unknown"
}

// MARK: - Status Dot View (bypasses menubar vibrancy)

class StatusDotView: NSView {
    var dotColor: NSColor = .systemGray {
        didSet { needsDisplay = true }
    }

    override var allowsVibrancy: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        dotColor.setFill()
        let dotSize: CGFloat = 8
        let dotRect = NSRect(
            x: (bounds.width - dotSize) / 2,
            y: (bounds.height - dotSize) / 2,
            width: dotSize,
            height: dotSize
        )
        NSBezierPath(ovalIn: dotRect).fill()
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var startMenuItem: NSMenuItem!
    private var stopMenuItem: NSMenuItem!
    private var restartMenuItem: NSMenuItem!
    private var sessionsSubmenu: NSMenu!
    private var newSessionMenuItem: NSMenuItem!
    private var timer: Timer?
    private var vmState: VMState = .unknown
    private var lastSessionsOutput: String = ""

    // Constants
    private let vmName = "pai"
    private let portalURL = "http://localhost:8080"
    private let openWorkspacesTag = 99
    private let portalMenuTag = 100
    private let terminalMenuTag = 101

    // Paths — limactl and cmux are in /opt/homebrew/bin on Apple Silicon
    private let env: [String: String] = {
        var e = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let extra = [
            "/opt/homebrew/bin",
            "\(home)/.bun/bin",
            "/usr/local/bin"
        ]
        e["PATH"] = extra.joined(separator: ":") + ":" + (e["PATH"] ?? "/usr/bin:/bin")
        e["HOME"] = home
        return e
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()
        setupMenu()

        // Initial status check + periodic polling
        checkVMStatus()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.checkVMStatus()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }

    // MARK: - Menu Setup

    private func setupMenu() {
        let menu = NSMenu()

        // Status line
        statusMenuItem = NSMenuItem(title: "VM: Checking…", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())

        // VM Control — separate Start, Stop, Restart
        startMenuItem = NSMenuItem(title: "Start VM", action: #selector(startVM), keyEquivalent: "s")
        startMenuItem.target = self
        menu.addItem(startMenuItem)

        stopMenuItem = NSMenuItem(title: "Stop VM", action: #selector(stopVM), keyEquivalent: "")
        stopMenuItem.target = self
        menu.addItem(stopMenuItem)

        restartMenuItem = NSMenuItem(title: "Restart VM", action: #selector(restartVM), keyEquivalent: "r")
        restartMenuItem.target = self
        menu.addItem(restartMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Open Workspaces — primary action: opens cmux with all active sessions
        let openWorkspacesItem = NSMenuItem(title: "Open Workspaces", action: #selector(openWorkspaces), keyEquivalent: "o")
        openWorkspacesItem.target = self
        openWorkspacesItem.tag = openWorkspacesTag
        menu.addItem(openWorkspacesItem)

        // New Claude Session
        newSessionMenuItem = NSMenuItem(title: "New Claude Session…", action: #selector(newSession), keyEquivalent: "n")
        newSessionMenuItem.target = self
        menu.addItem(newSessionMenuItem)

        // Active Sessions submenu
        let sessionsItem = NSMenuItem(title: "Active Sessions", action: nil, keyEquivalent: "")
        sessionsSubmenu = NSMenu()
        sessionsItem.submenu = sessionsSubmenu
        menu.addItem(sessionsItem)

        menu.addItem(NSMenuItem.separator())

        // Open PAI Web
        let webItem = NSMenuItem(title: "Open PAI Web", action: #selector(openPortal), keyEquivalent: "w")
        webItem.target = self
        webItem.tag = portalMenuTag
        menu.addItem(webItem)

        // Open in Terminal (plain shell)
        let terminalItem = NSMenuItem(title: "Open in Terminal", action: #selector(openTerminal), keyEquivalent: "t")
        terminalItem.target = self
        terminalItem.tag = terminalMenuTag
        menu.addItem(terminalItem)

        menu.addItem(NSMenuItem.separator())

        // Launch at Login
        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = isLaunchAtLoginEnabled() ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit PAI-Status", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Icon Updates

    private var dotView: StatusDotView?
    private var lastRenderedState: VMState?
    private var cachedSymbols: [String: NSImage] = [:]

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        guard vmState != lastRenderedState else { return }
        lastRenderedState = vmState

        // SF Symbol (cached) adapts to menubar appearance
        let symbolName = vmState == .unknown
            ? "desktopcomputer.trianglebadge.exclamationmark"
            : "desktopcomputer"

        let symbol: NSImage
        if let cached = cachedSymbols[symbolName] {
            symbol = cached
        } else if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: "PAI VM") {
            img.isTemplate = true
            cachedSymbols[symbolName] = img
            symbol = img
        } else {
            return
        }

        button.image = symbol
        button.imagePosition = .imageLeft
        button.title = "  "

        // Colored dot via custom NSView with allowsVibrancy=false
        let color: NSColor
        switch vmState {
        case .running:             color = .systemGreen
        case .stopped:             color = .systemRed
        case .starting, .stopping: color = .systemYellow
        case .unknown:             color = .systemGray
        }

        if dotView == nil {
            let dv = StatusDotView(frame: NSRect(x: 0, y: 0, width: 12, height: 22))
            button.addSubview(dv)
            dotView = dv
        }
        dotView?.dotColor = color
        // Defer positioning to after layout pass (bounds may be zero on first call)
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let button = self.statusItem?.button, let dv = self.dotView else { return }
            let x = button.bounds.width - 14
            let y = (button.bounds.height - 22) / 2
            dv.frame = NSRect(x: x, y: y, width: 12, height: 22)
        }
    }

    // MARK: - VM Status Polling

    private func checkVMStatus() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let state = self.queryVMState()

            DispatchQueue.main.async {
                // Don't override transient states with polled results
                // During restart, ignore all polling until restart completes
                if self.isRestarting {
                    // Keep current state — restart manages its own transitions
                } else if self.vmState == .starting && state == .running {
                    self.vmState = .running
                } else if self.vmState == .stopping && state == .stopped {
                    self.vmState = .stopped
                } else if self.vmState != .starting && self.vmState != .stopping {
                    self.vmState = state
                }

                self.statusMenuItem.title = "VM: \(self.vmState.rawValue)"
                let running = (self.vmState == .running)
                let transitioning = (self.vmState == .starting || self.vmState == .stopping)
                self.startMenuItem.isEnabled = !running && !transitioning
                self.stopMenuItem.isEnabled = running && !transitioning
                self.restartMenuItem.isEnabled = running && !transitioning
                self.newSessionMenuItem.isEnabled = running
                if let menu = self.statusItem.menu {
                    menu.item(withTag: self.openWorkspacesTag)?.isEnabled = running
                    menu.item(withTag: self.portalMenuTag)?.isEnabled = running
                    menu.item(withTag: self.terminalMenuTag)?.isEnabled = running
                }
                self.updateIcon()
                self.refreshSessions()
            }
        }
    }

    private func queryVMState() -> VMState {
        let (exitCode, output) = runProcess("/usr/bin/env", args: ["limactl", "list", "--json"], timeout: 10)
        guard exitCode == 0, let output = output else { return .unknown }

        // limactl list --json outputs one JSON object per line
        for line in output.components(separatedBy: "\n") {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = json["name"] as? String,
                  name == vmName,
                  let status = json["status"] as? String else { continue }

            return status == "Running" ? .running : .stopped
        }

        return .stopped // VM not found = not created
    }

    // MARK: - VM Control

    private var isRestarting = false

    private func disableVMControls() {
        startMenuItem.isEnabled = false
        stopMenuItem.isEnabled = false
        restartMenuItem.isEnabled = false
    }

    @objc private func restartVM() {
        isRestarting = true
        vmState = .stopping
        statusMenuItem.title = "VM: Restarting…"
        disableVMControls()
        updateIcon()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let (_, _) = self.runProcess("/usr/bin/env", args: ["limactl", "stop", self.vmName], timeout: 60)
            let (_, _) = self.runProcess("/usr/bin/env", args: ["limactl", "start", self.vmName], timeout: 120)

            DispatchQueue.main.async {
                self.isRestarting = false
                self.checkVMStatus()
            }
        }
    }

    @objc private func startVM() {
        vmState = .starting
        statusMenuItem.title = "VM: \(vmState.rawValue)"
        disableVMControls()
        updateIcon()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let (_, _) = self.runProcess("/usr/bin/env", args: ["limactl", "start", self.vmName], timeout: 120)

            DispatchQueue.main.async {
                self.checkVMStatus()
            }
        }
    }

    @objc private func stopVM() {
        vmState = .stopping
        statusMenuItem.title = "VM: \(vmState.rawValue)"
        disableVMControls()
        updateIcon()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let (_, _) = self.runProcess("/usr/bin/env", args: ["limactl", "stop", self.vmName], timeout: 60)

            DispatchQueue.main.async {
                self.checkVMStatus()
            }
        }
    }

    // MARK: - Open Workspaces

    @objc private func openWorkspaces() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // Query VM for all active tmux sessions
            let (exitCode, output) = self.runProcess(
                "/usr/bin/env",
                args: ["limactl", "shell", self.vmName, "--", "tmux", "list-sessions", "-F", "#{session_name}"],
                timeout: 10
            )

            let sessions: [String]
            if exitCode == 0, let output = output, !output.isEmpty {
                sessions = output.components(separatedBy: "\n").filter { !$0.isEmpty }
            } else {
                sessions = []
            }

            let wasRunning = self.isCmuxRunning()
            self.ensureCmuxRunning()

            if sessions.isEmpty {
                // No active sessions — create default "pai" workspace with Claude Code
                // The command shells into the VM, starts tmux, then launches PAI
                let paiCmd = "limactl shell \(self.vmName) -- tmux new-session -As pai \\; send-keys 'bun /home/claude/.claude/PAI/Tools/pai.ts' Enter"
                if wasRunning {
                    self.openCmuxWorkspace(command: paiCmd, name: "pai")
                } else {
                    // cmux just launched — replace its default workspace instead of creating a second one
                    self.replaceDefaultWorkspace(command: paiCmd, name: "pai")
                }
            } else {
                // Restore one cmux tab per active session
                var isFirst = !wasRunning
                for name in sessions {
                    let command = "limactl shell \(self.vmName) -- tmux new-session -As \(name)"
                    if isFirst {
                        // Replace cmux's default workspace with the first session
                        self.replaceDefaultWorkspace(command: command, name: name)
                        isFirst = false
                    } else {
                        self.openCmuxWorkspace(command: command, name: name)
                    }
                    Thread.sleep(forTimeInterval: 0.3)
                }
            }
        }
    }

    // MARK: - Portal & Terminal

    @objc private func openPortal() {
        if let url = URL(string: portalURL) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openTerminal() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            self.ensureCmuxRunning()
            self.openCmuxWorkspace(command: "limactl shell \(self.vmName)", name: "shell")
        }
    }

    // MARK: - Session Management

    @objc private func newSession() {
        let alert = NSAlert()
        alert.messageText = "New Claude Session"
        alert.informativeText = "Enter a name for the tmux session:"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        let timestamp = Int(Date().timeIntervalSince1970) % 10000
        input.stringValue = "claude-\(timestamp)"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            self.ensureCmuxRunning()
            // Shell into VM, start tmux session, and launch PAI
            let paiCmd = "limactl shell \(self.vmName) -- tmux new-session -As \(name) \\; send-keys 'bun /home/claude/.claude/PAI/Tools/pai.ts' Enter"
            self.openCmuxWorkspace(command: paiCmd, name: name)
        }
    }

    @objc private func attachToSession(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            self.ensureCmuxRunning()
            self.openCmuxWorkspace(command: "limactl shell \(self.vmName) -- tmux new-session -As \(name)", name: name)
        }
    }

    // MARK: - cmux Helpers

    private func isCmuxRunning() -> Bool {
        let (exitCode, _) = runProcess("/usr/bin/pgrep", args: ["-x", "cmux"], timeout: 5)
        return exitCode == 0
    }

    private func ensureCmuxRunning() {
        let openTask = Process()
        openTask.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        openTask.arguments = ["-a", "cmux"]
        try? openTask.run()
        openTask.waitUntilExit()
        Thread.sleep(forTimeInterval: 1.0)
    }

    private func openCmuxWorkspace(command: String, name: String) {
        let (_, _) = runProcess("/usr/bin/env", args: ["cmux", "new-workspace", "--command", command], timeout: 10)
        Thread.sleep(forTimeInterval: 0.3)
        let (_, _) = runProcess("/usr/bin/env", args: ["cmux", "rename-workspace", name], timeout: 5)
    }

    /// Replace cmux's default workspace (created on fresh launch) with our command
    private func replaceDefaultWorkspace(command: String, name: String) {
        // Send the command to the default workspace's terminal, then rename it
        let (_, _) = runProcess("/usr/bin/env", args: ["cmux", "send", "--workspace", "workspace:1", command + "\n"], timeout: 10)
        Thread.sleep(forTimeInterval: 0.3)
        let (_, _) = runProcess("/usr/bin/env", args: ["cmux", "rename-workspace", "--workspace", "workspace:1", name], timeout: 5)
    }

    private func refreshSessions() {
        guard vmState == .running else {
            sessionsSubmenu.removeAllItems()
            let item = NSMenuItem(title: "(VM not running)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            sessionsSubmenu.addItem(item)
            lastSessionsOutput = ""
            return
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let (exitCode, output) = self.runProcess(
                "/usr/bin/env",
                args: ["limactl", "shell", self.vmName, "--", "tmux", "list-sessions", "-F", "#{session_name}: #{session_windows} windows (#{session_attached} attached)"],
                timeout: 5
            )

            let currentOutput = (exitCode == 0 ? output : nil) ?? ""

            DispatchQueue.main.async {
                // Skip rebuild if output unchanged
                guard currentOutput != self.lastSessionsOutput else { return }
                self.lastSessionsOutput = currentOutput

                self.sessionsSubmenu.removeAllItems()

                guard !currentOutput.isEmpty else {
                    let item = NSMenuItem(title: "(no active sessions)", action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    self.sessionsSubmenu.addItem(item)
                    return
                }

                for line in currentOutput.components(separatedBy: "\n") where !line.isEmpty {
                    let sessionName = line.components(separatedBy: ":").first ?? line
                    let item = NSMenuItem(title: line, action: #selector(self.attachToSession(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = sessionName
                    self.sessionsSubmenu.addItem(item)
                }
            }
        }
    }

    // MARK: - Launch at Login

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let enable = sender.state == .off
        setLaunchAtLogin(enabled: enable)
        sender.state = enable ? .on : .off
    }

    private let launchAgentLabel = "com.pai.status"

    private var launchAgentPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/\(launchAgentLabel).plist"
    }

    private func isLaunchAtLoginEnabled() -> Bool {
        FileManager.default.fileExists(atPath: launchAgentPath)
    }

    private func setLaunchAtLogin(enabled: Bool) {
        if enabled {
            let appPath = Bundle.main.bundlePath
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>\(launchAgentLabel)</string>
                <key>ProgramArguments</key>
                <array>
                    <string>/usr/bin/open</string>
                    <string>-a</string>
                    <string>\(appPath)</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <false/>
            </dict>
            </plist>
            """

            do {
                let dir = NSHomeDirectory() + "/Library/LaunchAgents"
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try plist.write(toFile: launchAgentPath, atomically: true, encoding: .utf8)

                let task = Process()
                task.launchPath = "/bin/launchctl"
                task.arguments = ["load", launchAgentPath]
                try task.run()
                task.waitUntilExit()
            } catch { }
        } else {
            do {
                let task = Process()
                task.launchPath = "/bin/launchctl"
                task.arguments = ["unload", launchAgentPath]
                try task.run()
                task.waitUntilExit()
                try FileManager.default.removeItem(atPath: launchAgentPath)
            } catch { }
        }
    }

    // MARK: - Quit

    @objc private func quitApp() {
        NSApplication.shared.terminate(self)
    }

    // MARK: - Process Helper

    private func runProcess(_ executable: String, args: [String], timeout: TimeInterval) -> (Int32, String?) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = args
        task.environment = env

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            return (-1, nil)
        }

        // Timeout handling
        let deadline = DispatchTime.now() + timeout
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline) {
            if task.isRunning { task.terminate() }
        }

        // Read pipe before waiting — prevents deadlock if output exceeds pipe buffer
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)

        return (task.terminationStatus, output)
    }
}

// MARK: - Main Entry Point

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // No dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
