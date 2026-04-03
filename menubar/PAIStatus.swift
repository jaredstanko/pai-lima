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
    private var sessionsSubmenu: NSMenu!
    private var newSessionMenuItem: NSMenuItem!
    private var timer: Timer?
    private var vmState: VMState = .unknown
    private var cachedUserShell: String?

    // Constants
    private let vmName = "pai"
    private let portalURL = "http://localhost:8080"
    private let portalMenuTag = 100
    private let terminalMenuTag = 101

    // Paths — limactl and kitty are in /opt/homebrew/bin on Apple Silicon
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

        menu.addItem(NSMenuItem.separator())

        // New PAI Session
        newSessionMenuItem = NSMenuItem(title: "New PAI Session…", action: #selector(newSession), keyEquivalent: "n")
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

        // Open a Terminal (plain shell)
        let terminalItem = NSMenuItem(title: "Open a Terminal", action: #selector(openTerminal), keyEquivalent: "t")
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
                if self.vmState == .starting && state == .running {
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
                self.newSessionMenuItem.isEnabled = running
                if let menu = self.statusItem.menu {
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


    private func disableVMControls() {
        startMenuItem.isEnabled = false
        stopMenuItem.isEnabled = false
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

    // MARK: - Portal & Terminal

    @objc private func openPortal() {
        if let url = URL(string: portalURL) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openTerminal() {
        let shell = getUserShell()
        openKittyTab(title: "PAI Shell", args: [
            "limactl", "shell", vmName, "--", shell, "-l"
        ])
    }

    // MARK: - Session Management

    @objc private func newSession() {
        let shell = getUserShell()
        openKittyTab(title: "PAI", args: [
            "limactl", "shell", vmName, "--", shell, "-lc", "bun ~/.claude/PAI/Tools/pai.ts"
        ])
    }

    @objc private func resumeSession() {
        let shell = getUserShell()
        openKittyTab(title: "Resume Session", args: [
            "limactl", "shell", vmName, "--", shell, "-lc", "claude -r"
        ])
    }

    // MARK: - User Shell Detection

    /// Query the VM user's default shell, cached after first call.
    private func getUserShell() -> String {
        if let cached = cachedUserShell { return cached }
        let (exitCode, output) = runProcess("/usr/bin/env", args: [
            "limactl", "shell", vmName, "--", "getent", "passwd", "claude"
        ], timeout: 10)
        // getent passwd claude returns: claude:x:1000:1000::/home/claude:/bin/bash
        if exitCode == 0, let output = output {
            let shell = output.components(separatedBy: ":").last ?? "/bin/bash"
            cachedUserShell = shell
            return shell
        }
        return "/bin/bash"
    }

    // MARK: - kitty Helpers

    /// Find the kitty remote control socket.
    /// kitty appends -<PID> to listen_on paths, so we glob /tmp/kitty-*.
    private func findKittySocket() -> String? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: "/tmp") else { return nil }
        // Find socket files matching kitty-<PID> pattern
        for entry in entries where entry.hasPrefix("kitty-") {
            let path = "/tmp/\(entry)"
            var statBuf = stat()
            guard stat(path, &statBuf) == 0, (statBuf.st_mode & S_IFMT) == S_IFSOCK else { continue }
            return "unix:\(path)"
        }
        return nil
    }

    private func openKittyTab(title: String, args: [String]) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // Try existing Kitty instance via remote control socket
            if let socketAddr = self.findKittySocket() {
                var remoteArgs = ["kitty", "@", "--to", socketAddr, "launch", "--type=tab", "--title", title, "--"]
                remoteArgs.append(contentsOf: args)

                let remoteTask = Process()
                remoteTask.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                remoteTask.arguments = remoteArgs
                remoteTask.environment = self.env
                remoteTask.standardOutput = FileHandle.nullDevice
                remoteTask.standardError = FileHandle.nullDevice

                do {
                    try remoteTask.run()
                    // Timeout: kill after 5s to handle stale sockets
                    let deadline = DispatchTime.now() + 5
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline) {
                        if remoteTask.isRunning { remoteTask.terminate() }
                    }
                    remoteTask.waitUntilExit()
                    if remoteTask.terminationStatus == 0 {
                        // Bring Kitty to the front so user sees the new tab
                        DispatchQueue.main.async {
                            NSWorkspace.shared.runningApplications
                                .first { $0.bundleIdentifier == "net.kovidgoyal.kitty" }?
                                .activate()
                        }
                        return
                    }
                } catch { }
            }

            // No existing Kitty instance — open a new window
            var kittyArgs = ["--title", title]
            kittyArgs.append(contentsOf: args)

            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            task.arguments = ["kitty"] + kittyArgs
            task.environment = self.env
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try? task.run()
            // Don't wait — kitty is a long-running GUI process
        }
    }

    private func refreshSessions() {
        guard vmState == .running else {
            sessionsSubmenu.removeAllItems()
            let item = NSMenuItem(title: "(VM not running)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            sessionsSubmenu.addItem(item)
            return
        }

        sessionsSubmenu.removeAllItems()
        let resumeItem = NSMenuItem(title: "Resume Session…", action: #selector(resumeSession), keyEquivalent: "")
        resumeItem.target = self
        sessionsSubmenu.addItem(resumeItem)
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
