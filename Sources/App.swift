import AppKit
import ServiceManagement
import SystemConfiguration

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let demo: Bool
    private let worker: MonitorWorker
    private let preferences: PairPreferences
    private var pair: InputPair?
    private var pendingInputPair = false
    private var identifier: String?
    private var state: MonitorState?
    private var connectedInput: InputSource?
    private var names: [String: String] = [:]
    private var computerName: String { SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "This Mac" }
    private var busy = false
    private var status = "Connecting…"
    private var lastError: String?
    private var timer: Timer?
    private var refreshScheduled: DispatchWorkItem?
    private var lastRefresh = Date.distantPast
    private var displayObserver: DisplayChangeObserver?
    private var dellDisplayIDs: Set<CGDirectDisplayID> = []
    private var passiveWakeGuard: DisplayWakeGuard?
    private var lastPassiveWake = Date.distantPast
    private var updater: AppUpdater?
    private var changingLayout = false {
        didSet { updater?.monitorChangeInProgress = changingLayout }
    }

    init(demo: Bool) {
        self.demo = demo
        worker = MonitorWorker(demo: demo)
        preferences = PairPreferences(demo: demo)
        identifier = preferences.lastIdentifier
        pair = preferences.load(identifier)
        names = preferences.names(for: identifier)
        super.init()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.splitIcon(0.5, menuBar: true)
        statusItem.button?.setAccessibilityLabel("Dell PBP monitor layouts")
        statusItem.button?.toolTip = "Dell PBP — click to choose a layout"
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        if !demo { updater = AppUpdater() }
        rebuildMenu()
        refresh()
        if !demo {
            displayObserver = DisplayChangeObserver { [weak self] display in self?.monitorWillReconfigure(display) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displaysChanged), name: NSWorkspace.didWakeNotification, object: nil)
        if CommandLine.arguments.contains("--show-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.statusItem.button?.performClick(nil) }
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        refreshScheduled?.cancel()
        displayObserver?.stop()
        passiveWakeGuard?.cancel()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
    func menuWillOpen(_ menu: NSMenu) {
        if !busy && Date().timeIntervalSince(lastRefresh) > 20 { refresh() }
    }
    @objc private func displaysChanged() {
        refreshScheduled?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshScheduled = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: item)
    }
    private func monitorWillReconfigure(_ display: CGDirectDisplayID) {
        guard preferences.wakeOnMonitorChanges, !changingLayout, dellDisplayIDs.contains(display),
              state?.isLocalInputVisible == true, Date().timeIntervalSince(lastPassiveWake) >= 20 else { return }
        lastPassiveWake = Date()
        passiveWakeGuard?.cancel()
        // Read the new routing before the first wake request whenever possible. If this
        // computer has been intentionally hidden, refresh cancels the guard immediately.
        passiveWakeGuard = DisplayWakeGuard(wakeDelay: 2, maximumDuration: 20)
        refresh()
    }
    @objc private func refresh() {
        guard !busy else { return }
        busy = true
        status = "Reading monitor…"
        rebuildMenu()
        worker.refresh { [weak self] result in
            guard let self else { return }
            self.busy = false
            self.lastRefresh = Date()
            switch result {
            case .success(let (state, identifier)):
                if identifier != self.identifier {
                    self.identifier = identifier
                    self.pair = self.preferences.load(identifier)
                    self.names = self.preferences.names(for: identifier)
                    self.pendingInputPair = false
                }
                self.state = state
                self.connectedInput = state.connectedInput
                self.dellDisplayIDs = Set(NSScreen.screens.compactMap { screen in
                    guard screen.localizedName.localizedCaseInsensitiveContains("U4025QW") else { return nil }
                    return (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                })
                if !state.isLocalInputVisible {
                    self.passiveWakeGuard?.cancel()
                    self.passiveWakeGuard = nil
                }
                // Follow swaps made by the other Mac, while preserving an unapplied user choice.
                // Solo mode must not overwrite the saved pair.
                if !self.pendingInputPair, let detected = state.pair {
                    self.pair = detected
                    self.preferences.save(detected, for: identifier)
                }
                self.lastError = nil
                self.status = self.describe(state)
            case .failure(let error):
                self.state = nil
                self.status = "Monitor unavailable"
                self.lastError = error.localizedDescription
            }
            self.rebuildMenu()
        }
    }
    private func describe(_ state: MonitorState) -> String {
        if let selected = state.layout(for: pair) { return "Current: " + selected.title }
        if state.mode == 0 { return "Single input: " + state.primary.title }
        return pair == nil ? "Choose left and right inputs" : "Current layout not in this list"
    }
    private func inputName(_ source: InputSource) -> String {
        let custom = names[String(source.rawValue)]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !custom.isEmpty { return custom }
        return source == connectedInput ? computerName : source.title
    }
    private func rebuildMenu() {
        menu.removeAllItems()
        let header = NSMenuItem(title: demo ? "Dell PBP · Demo" : "Dell U4025QW", action: nil, keyEquivalent: "")
        header.attributedTitle = NSAttributedString(string: header.title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor])
        header.isEnabled = false
        menu.addItem(header)
        let stateItem = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        if let pair {
            for (side, source) in [("Left", pair.left), ("Right", pair.right)] {
                let item = NSMenuItem(title: "\(side): \(inputName(source))", action: nil, keyEquivalent: "")
                item.isEnabled = false
                item.toolTip = source.title + (source == connectedInput ? " · This Mac" : "")
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        for (index, layout) in Layout.all.enumerated() {
            if index == Split.allCases.count { menu.addItem(.separator()) }
            let item = NSMenuItem(title: layout.title, action: #selector(chooseLayout(_:)), keyEquivalent: String(index + 1))
            item.keyEquivalentModifierMask = [.option, .command]
            item.tag = index
            item.target = self
            item.image = Self.splitIcon(layout.leftFraction)
            item.isEnabled = !busy && pair != nil
            item.state = state?.layout(for: pair) == layout ? .on : .off
            if let pair {
                switch layout {
                case .split(let split): item.toolTip = "Left: \(pair.left.title), \(Int(split.leftFraction * 5120)) × 2160. Right: \(pair.right.title)."
                case .leftOnly: item.toolTip = "Show \(inputName(pair.left)) (\(pair.left.title)) across the full monitor."
                case .rightOnly: item.toolTip = "Show \(inputName(pair.right)) (\(pair.right.title)) across the full monitor."
                }
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let swap = NSMenuItem(title: "Switch Displays", action: #selector(switchDisplays), keyEquivalent: "s")
        swap.keyEquivalentModifierMask = [.option, .command]
        swap.target = self
        swap.image = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: "Swap inputs")
        swap.isEnabled = !busy && state?.pair != nil
        swap.toolTip = "Swap the left and right inputs while keeping the current split."
        menu.addItem(swap)
        menu.addItem(.separator())
        let inputItem = NSMenuItem(title: "Inputs", action: nil, keyEquivalent: "")
        let inputs = NSMenu()
        inputs.autoenablesItems = false
        for side in 0...1 {
            let current = side == 0 ? pair?.left : pair?.right
            let label = side == 0 ? "Left" : "Right"
            let sideItem = NSMenuItem(title: "\(label): \(current.map(inputName) ?? "Choose…")", action: nil, keyEquivalent: "")
            let choices = NSMenu()
            choices.autoenablesItems = false
            for source in InputSource.allCases {
                let name = inputName(source)
                let choice = NSMenuItem(title: name == source.title ? source.title : "\(source.title) — \(name)", action: #selector(chooseInput(_:)), keyEquivalent: "")
                choice.target = self
                choice.tag = side * 256 + Int(source.rawValue)
                choice.state = current == source ? .on : .off
                choice.isEnabled = !busy && identifier != nil
                choices.addItem(choice)
            }
            sideItem.submenu = choices
            inputs.addItem(sideItem)
        }
        inputs.addItem(.separator())
        let rename = NSMenuItem(title: "Name inputs…", action: #selector(nameInputs), keyEquivalent: "")
        rename.target = self
        rename.isEnabled = !busy && identifier != nil
        inputs.addItem(rename)
        inputItem.submenu = inputs
        menu.addItem(inputItem)
        let refreshItem = NSMenuItem(title: "Refresh monitor", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        refreshItem.isEnabled = !busy
        menu.addItem(refreshItem)
        let wake = NSMenuItem(title: "Wake on monitor changes", action: #selector(toggleAutomaticWake), keyEquivalent: "")
        wake.target = self
        wake.state = preferences.wakeOnMonitorChanges ? .on : .off
        wake.isEnabled = !demo
        wake.toolTip = "Run Dell PBP on both Macs so each responds when the monitor reconnects."
        menu.addItem(wake)
        if lastError != nil {
            let errorItem = NSMenuItem(title: "Connection details…", action: #selector(showError), keyEquivalent: "")
            errorItem.target = self
            menu.addItem(errorItem)
        }
        let login = NSMenuItem(title: "Launch at login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.isEnabled = !demo
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        if let updater {
            menu.addItem(updater.checkItem)
            menu.addItem(updater.automaticItem)
            menu.addItem(.separator())
        }
        let quit = NSMenuItem(title: "Quit Dell PBP", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        let selected = state?.layout(for: pair)
        statusItem.button?.image = Self.splitIcon(selected?.leftFraction ?? 0.5, menuBar: true)
        statusItem.button?.toolTip = "Dell PBP — \(status)"
    }
    @objc private func chooseLayout(_ sender: NSMenuItem) {
        guard !busy, let pair, Layout.all.indices.contains(sender.tag) else { return }
        let layout = Layout.all[sender.tag]
        passiveWakeGuard?.cancel()
        passiveWakeGuard = nil
        changingLayout = true
        busy = true
        state = nil
        lastError = nil
        status = "Switching to \(layout.title)…"
        rebuildMenu()
        worker.apply(layout, pair: pair) { [weak self] result in
            guard let self else { return }
            self.busy = false
            self.changingLayout = false
            self.lastRefresh = Date()
            switch result {
            case .success(let actual):
                self.pendingInputPair = false
                self.state = actual
                self.connectedInput = actual.connectedInput
                self.status = self.describe(actual)
            case .failure(let error):
                self.state = nil
                self.status = "Change not confirmed"
                self.lastError = error.localizedDescription + "\n\nIf this Mac's input is inactive, use Dell PBP on the other Mac or the monitor joystick to return to PBP."
            }
            self.rebuildMenu()
        }
    }
    @objc private func switchDisplays() {
        guard !busy, state?.pair != nil, let identifier else { return }
        passiveWakeGuard?.cancel()
        passiveWakeGuard = nil
        changingLayout = true
        busy = true
        state = nil
        lastError = nil
        status = "Switching displays…"
        rebuildMenu()
        worker.switchDisplays { [weak self] result in
            guard let self else { return }
            self.busy = false
            self.changingLayout = false
            self.lastRefresh = Date()
            switch result {
            case .success(let (actual, flipped)):
                self.pendingInputPair = false
                self.pair = flipped
                self.preferences.save(flipped, for: identifier)
                self.state = actual
                self.connectedInput = actual.connectedInput
                self.status = self.describe(actual)
            case .failure(let error):
                self.state = nil
                self.status = "Switch not confirmed"
                self.lastError = error.localizedDescription
            }
            self.rebuildMenu()
        }
    }
    @objc private func nameInputs() {
        guard !busy, let identifier else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Name your inputs"
        alert.informativeText = "This Mac is named automatically. Give the other computer a name below. Names stay with their input ports when you switch displays. Leave a field blank to use its automatic name."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let form = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 174))
        var fields: [(InputSource, NSTextField)] = []
        for (index, source) in InputSource.allCases.enumerated() {
            let y = CGFloat(2 - index) * 58
            let label = NSTextField(labelWithString: source.title + (source == connectedInput ? " · This Mac" : ""))
            label.frame = NSRect(x: 0, y: y + 31, width: 380, height: 18)
            label.font = .systemFont(ofSize: 12, weight: .medium)
            let field = NSTextField(frame: NSRect(x: 0, y: y + 3, width: 380, height: 24))
            field.stringValue = names[String(source.rawValue)] ?? ""
            field.placeholderString = source == connectedInput ? computerName : source.title
            field.setAccessibilityLabel("Name for " + source.title)
            form.addSubview(label)
            form.addSubview(field)
            fields.append((source, field))
        }
        alert.accessoryView = form
        alert.window.initialFirstResponder = fields.first(where: { $0.0 != connectedInput })?.1
        if alert.runModal() == .alertFirstButtonReturn {
            names = Dictionary(uniqueKeysWithValues: fields.map { source, field in
                (String(source.rawValue), String(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)))
            })
            preferences.saveNames(names, for: identifier)
            rebuildMenu()
        }
    }
    @objc private func chooseInput(_ sender: NSMenuItem) {
        guard !busy, let identifier, let source = InputSource(rawValue: UInt16(sender.tag % 256)) else { return }
        // Choosing a port already used on the other side swaps the saved pair.
        var chosen = pair ?? InputPair(left: .thunderbolt, right: .displayPort)
        if sender.tag < 256 {
            if source == chosen.right { chosen.right = chosen.left }
            chosen.left = source
        } else {
            if source == chosen.left { chosen.left = chosen.right }
            chosen.right = source
        }
        pair = chosen
        pendingInputPair = true
        preferences.save(chosen, for: identifier)
        status = "Inputs saved; choose a layout"
        rebuildMenu()
    }
    @objc private func showError() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Monitor connection"
        alert.informativeText = lastError ?? "No connection error."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch {
            lastError = "Launch at login could not be changed: \(error.localizedDescription)"
            showError()
        }
        rebuildMenu()
    }
    @objc private func toggleAutomaticWake() {
        preferences.wakeOnMonitorChanges.toggle()
        if !preferences.wakeOnMonitorChanges {
            passiveWakeGuard?.cancel()
            passiveWakeGuard = nil
        }
        rebuildMenu()
    }
    @objc private func quitApp() { NSApp.terminate(nil) }
    static func splitIcon(_ fraction: Double, menuBar: Bool = false) -> NSImage {
        let size = menuBar ? NSSize(width: 20, height: 18) : NSSize(width: 32, height: 18)
        let image = NSImage(size: size, flipped: false) { bounds in
            let screen = NSRect(x: 1, y: 4, width: bounds.width - 2, height: 12)
            NSColor.black.setStroke()
            let outline = NSBezierPath(roundedRect: screen, xRadius: 2, yRadius: 2)
            outline.lineWidth = 1.25
            outline.stroke()
            NSGraphicsContext.saveGraphicsState()
            outline.addClip()
            NSColor.black.withAlphaComponent(0.25).setFill()
            let fill = fraction == 0 ? screen : NSRect(x: screen.minX, y: screen.minY, width: screen.width * fraction, height: screen.height)
            fill.fill()
            if fraction > 0 && fraction < 1 {
                let divider = NSBezierPath()
                let x = screen.minX + screen.width * fraction
                divider.move(to: NSPoint(x: x, y: screen.minY))
                divider.line(to: NSPoint(x: x, y: screen.maxY))
                divider.lineWidth = 1
                divider.stroke()
            }
            NSGraphicsContext.restoreGraphicsState()
            let stand = NSBezierPath()
            stand.move(to: NSPoint(x: bounds.midX, y: 4))
            stand.line(to: NSPoint(x: bounds.midX, y: 1.5))
            stand.move(to: NSPoint(x: bounds.midX - 3, y: 1.5))
            stand.line(to: NSPoint(x: bounds.midX + 3, y: 1.5))
            stand.lineWidth = 1.25
            stand.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Monitor layout"
        return image
    }
}
