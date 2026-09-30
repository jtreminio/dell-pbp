import AppKit
import Sparkle

@main
struct AppUpdaterTests {
    @MainActor static func main() {
        // No AppDelegate, monitor transport, updater start, or update network requests.
        let appUpdater = AppUpdater(startingUpdater: false)
        let dummy = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        let item = SUAppcastItem.empty()
        var installs = 0
        appUpdater.monitorChangeInProgress = true
        precondition(!appUpdater.checkItem.isEnabled)
        let postponed = appUpdater.updater(dummy.updater, shouldPostponeRelaunchForUpdate: item) { installs += 1 }
        precondition(postponed && installs == 0, "An update must wait for monitor writes to finish")
        appUpdater.monitorChangeInProgress = false
        precondition(installs == 1, "Finishing a monitor change must resume the update")
        appUpdater.monitorChangeInProgress = false
        precondition(installs == 1, "A deferred install must resume exactly once")
        let idle = appUpdater.updater(dummy.updater, shouldPostponeRelaunchForUpdate: item) { installs += 1 }
        precondition(!idle && installs == 1, "Idle app should let Sparkle install immediately")
        precondition(appUpdater.supportsGentleScheduledUpdateReminders)
        precondition(!appUpdater.standardUserDriverShouldHandleShowingScheduledUpdate(item, andInImmediateFocus: true))
        print("PASS: updater defers installation during monitor changes and resumes exactly once. No updater started; no monitor accessed.")
    }
}
