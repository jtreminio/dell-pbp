import Foundation
import IOKit.pwr_mgt

/// Bounded protection against idle sleep during display link renegotiation.
/// macOS can still enforce sleep for a closed lid, explicit sleep, or low battery.
final class DisplayWakeGuard {
    private var assertions: [IOPMAssertionID] = []
    private var activity = IOPMAssertionID(0)
    private var finishing = false
    private var released = false
    private let queue = DispatchQueue(label: "DellPBP.wake-protection")
    private var reconnectTimer: DispatchSourceTimer?
    private(set) var activeAssertionCount = 0

    init(wakeDelay: Double = 0, maximumDuration: Double = 120) {
        for kind in [kIOPMAssertPreventUserIdleDisplaySleep, kIOPMAssertPreventUserIdleSystemSleep] {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithDescription(kind as CFString,
                "Dell PBP: changing monitor layout" as CFString,
                "Keep this Mac awake while the external display reconnects." as CFString,
                nil, nil, maximumDuration, kIOPMAssertionTimeoutActionTurnOff as CFString, &id)
            if result == kIOReturnSuccess { assertions.append(id) }
        }
        activeAssertionCount = assertions.count
        if wakeDelay == 0 { declareActivity() }
        // A closed-lid Mac can sleep after the first declaration when the video link
        // drops. Renew activity during this user-requested reconnect, not only at its end.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + max(2, wakeDelay), repeating: 2)
        timer.setEventHandler { [weak self] in
            self?.declareActivity()
        }
        reconnectTimer = timer
        timer.resume()
        queue.asyncAfter(deadline: .now() + maximumDuration) { [weak self] in self?.releaseAssertions() }
    }

    private func declareActivity() {
        guard !released else { return }
        // This is a user-initiated display operation, not an artificial keyboard/mouse event.
        let result = IOPMAssertionDeclareUserActivity("Dell PBP: restore display after layout change" as CFString,
                                                    kIOPMUserActiveLocal, &activity)
        if result != kIOReturnSuccess { activity = 0 }
    }

    func cancel() {
        queue.sync {
            finishing = true
            releaseAssertions()
        }
    }

    func finish() {
        queue.async { [self] in
            guard !finishing else { return }
            finishing = true
            declareActivity()
            // Keep protection through the display's final reconnect. No permanent energy settings.
            queue.asyncAfter(deadline: .now() + 15) { [self] in releaseAssertions() }
        }
    }

    private func releaseAssertions() {
        released = true
        reconnectTimer?.cancel()
        reconnectTimer = nil
        for id in assertions { IOPMAssertionRelease(id) }
        assertions.removeAll()
        if activity != 0 { IOPMAssertionRelease(activity); activity = 0 }
    }

    deinit { releaseAssertions() }
}
