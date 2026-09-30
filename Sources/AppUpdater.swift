import AppKit
import Sparkle

/// Sparkle and its menu items stay on the main thread. Demo mode never creates this object.
@MainActor
final class AppUpdater: NSObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    let checkItem = NSMenuItem(title: "Check for Updates…", action: nil, keyEquivalent: "")
    let automaticItem = NSMenuItem(title: "Check for updates automatically", action: nil, keyEquivalent: "")
    private var controller: SPUStandardUpdaterController!
    private var observations: [NSKeyValueObservation] = []
    private var pendingInstall: (() -> Void)?
    var monitorChangeInProgress = false {
        didSet {
            updateMenu()
            if !monitorChangeInProgress, let install = pendingInstall {
                pendingInstall = nil
                install()
            }
        }
    }

    init(startingUpdater: Bool = true) {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        checkItem.target = self
        checkItem.action = #selector(checkForUpdates)
        automaticItem.target = self
        automaticItem.action = #selector(toggleAutomaticChecks)
        observations = [
            controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.updateMenu() }
            },
            controller.updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.updateMenu() }
            }
        ]
        if startingUpdater { controller.startUpdater() }
        updateMenu()
    }

    private func updateMenu() {
        checkItem.isEnabled = !monitorChangeInProgress && controller.updater.canCheckForUpdates
        automaticItem.state = controller.updater.automaticallyChecksForUpdates ? .on : .off
    }

    @objc private func checkForUpdates() {
        guard !monitorChangeInProgress else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    @objc private func toggleAutomaticChecks() {
        controller.updater.automaticallyChecksForUpdates.toggle()
        updateMenu()
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard monitorChangeInProgress else { return false }
        pendingInstall = installHandler
        return true
    }

    // A menu bar app has no Dock icon to draw attention to a background update window.
    // Present scheduled updates through its menu, and let the user open Sparkle's UI.
    var supportsGentleScheduledUpdateReminders: Bool { true }
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                               andInImmediateFocus immediateFocus: Bool) -> Bool { false }
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        checkItem.title = "Update Available…"
    }
    func standardUserDriverWillFinishUpdateSession() {
        checkItem.title = "Check for Updates…"
    }
}
