import Foundation

enum InputSource: UInt16, CaseIterable, Codable {
    case thunderbolt = 0x19, displayPort = 0x0F, hdmi = 0x11
    var title: String {
        switch self { case .thunderbolt: return "Thunderbolt / USB-C"; case .displayPort: return "DisplayPort"; case .hdmi: return "HDMI" }
    }
    // Dell packs the control connection in the high byte and selected input in the low byte.
    init?(reportedValue: UInt16) { self.init(rawValue: reportedValue & 0xFF) }
}

enum Split: UInt16, CaseIterable, Codable {
    case twentyEighty = 0x27, twentyFiveSeventyFive = 0x29, half = 0x24, seventyFiveTwentyFive = 0x2A, eightyTwenty = 0x28
    var leftFraction: Double {
        switch self { case .twentyEighty: return 0.2; case .twentyFiveSeventyFive: return 0.25; case .half: return 0.5; case .seventyFiveTwentyFive: return 0.75; case .eightyTwenty: return 0.8 }
    }
    var title: String { "\(Int((leftFraction * 100).rounded())) / \(Int(((1-leftFraction) * 100).rounded()))" }
}

struct InputPair: Codable, Equatable {
    var left: InputSource
    var right: InputSource
    var isValid: Bool { left != right }
    var reversed: InputPair { InputPair(left: right, right: left) }
}

enum Layout: Equatable {
    case split(Split), leftOnly, rightOnly
    var title: String {
        switch self { case .split(let split): return split.title; case .leftOnly: return "Only left input"; case .rightOnly: return "Only right input" }
    }
    var leftFraction: Double {
        switch self { case .split(let split): return split.leftFraction; case .leftOnly: return 1; case .rightOnly: return 0 }
    }
    static let all: [Layout] = Split.allCases.map(Layout.split) + [.leftOnly, .rightOnly]
    func shows(_ input: InputSource?, pair: InputPair) -> Bool {
        guard let input else { return false }
        switch self {
        case .split: return input == pair.left || input == pair.right
        case .leftOnly: return input == pair.left
        case .rightOnly: return input == pair.right
        }
    }
}

struct MonitorState: Equatable {
    var mode: UInt16
    var primary: InputSource
    var secondaryRaw: UInt16
    var connectedInput: InputSource? = nil
    var isLocalInputVisible: Bool {
        guard let connectedInput else { return false }
        if mode == 0 { return primary == connectedInput }
        guard Split(rawValue: mode) != nil else { return false }
        return primary == connectedInput || secondary == connectedInput
    }
    var secondary: InputSource? { InputSource(rawValue: secondaryRaw & 0x1F) }
    var pair: InputPair? {
        guard Split(rawValue: mode) != nil, let secondary, secondary != primary else { return nil }
        return InputPair(left: primary, right: secondary)
    }
    func matches(_ layout: Layout, pair: InputPair) -> Bool {
        switch layout {
        case .split(let split): return mode == split.rawValue && primary == pair.left && secondary == pair.right
        case .leftOnly: return mode == 0 && primary == pair.left
        case .rightOnly: return mode == 0 && primary == pair.right
        }
    }
    func layout(for pair: InputPair?) -> Layout? {
        guard let pair else { return nil }
        return Layout.all.first { matches($0, pair: pair) }
    }
}

enum MonitorFailure: LocalizedError {
    case configureInputs, duplicateInputs, unsupportedInput(UInt16), notVerified, operationBusy, requiresPBP, sourceReverted
    var errorDescription: String? {
        switch self {
        case .configureInputs: return "Choose the left and right inputs in Inputs, or enable PBP on the monitor and refresh."
        case .duplicateInputs: return "Left and right must use different input ports."
        case .unsupportedInput(let value): return String(format: "Unrecognized input 0x%04X. Refresh to check the monitor state.", value)
        case .notVerified: return "The monitor did not confirm the requested layout. Refresh to check its current state."
        case .operationBusy: return "A monitor change is already in progress."
        case .requiresPBP: return "Choose a split before switching the left and right displays."
        case .sourceReverted: return "The monitor returned to another input. Wake the selected computer and check Auto Select in the monitor's input menu."
        }
    }
}

protocol MonitorTransport: AnyObject {
    var identifier: String { get }
    func read(_ feature: UInt8) throws -> UInt16
    func write(_ feature: UInt8, value: UInt16) throws
    func wait(_ seconds: Double)
}

/// Executes on a single worker queue. Never treats successful transport as verified state.
final class MonitorSession {
    let transport: MonitorTransport
    init(_ transport: MonitorTransport) { self.transport = transport }
    func snapshot() throws -> MonitorState {
        let mode = try transport.read(0xE9)
        let raw = try transport.read(0x60)
        guard let primary = InputSource(reportedValue: raw) else { throw MonitorFailure.unsupportedInput(raw) }
        return MonitorState(mode: mode, primary: primary, secondaryRaw: try transport.read(0xE8),
                            connectedInput: InputSource(rawValue: raw >> 8))
    }
    func switchDisplays() throws -> (MonitorState, InputPair) {
        // Use the monitor's actual pair, even if its joystick changed it since our last refresh.
        let current = try snapshot()
        guard let split = Split(rawValue: current.mode), let pair = current.pair else { throw MonitorFailure.requiresPBP }
        let flipped = pair.reversed
        return (try apply(.split(split), pair: flipped), flipped)
    }
    func apply(_ layout: Layout, pair: InputPair, beforeHidingLocalInput: (() -> Void)? = nil) throws -> MonitorState {
        guard pair.isValid else { throw MonitorFailure.duplicateInputs }
        let before = try snapshot()
        if before.matches(layout, pair: pair) { return before }
        switch layout {
        case .split(let split):
            // Restore both visible regions first. The native transport reconnects after hot-plug events.
            if before.mode != split.rawValue {
                try transport.write(0xE9, value: split.rawValue)
                transport.wait(3)
            }
            if before.primary != pair.left {
                try transport.write(0x60, value: pair.left.rawValue)
                transport.wait(4)
            }
            // A primary-input change can also alter the secondary input. Read it again.
            let secondary = try transport.read(0xE8)
            if secondary & 0x1F != pair.right.rawValue {
                try transport.write(0xE8, value: (secondary & 0xFFE0) | pair.right.rawValue)
                transport.wait(4)
            }
        case .leftOnly, .rightOnly:
            let target = layout == .leftOnly ? pair.left : pair.right
            let hidesLocal = !layout.shows(before.connectedInput, pair: pair)
            // Select the intended computer while both inputs are still visible. Its
            // receiving app can handle the reconnect before the other region disappears.
            if before.primary != target {
                if before.mode == 0 && hidesLocal { beforeHidingLocalInput?() }
                try transport.write(0x60, value: target.rawValue)
                transport.wait(4)
            }
            if before.mode != 0 {
                if hidesLocal { beforeHidingLocalInput?() }
                try transport.write(0xE9, value: 0)
                transport.wait(3)
            }
            if hidesLocal { beforeHidingLocalInput?() }
            // Read the resulting source instead of assuming the mode change preserved it.
            // One corrective selection is allowed only when readback shows another source.
            let selected = try transport.read(0x60)
            guard let primary = InputSource(reportedValue: selected) else { throw MonitorFailure.unsupportedInput(selected) }
            if primary != target {
                try transport.write(0x60, value: target.rawValue)
                transport.wait(4)
            }
            // Allow an automatic fallback to become visible before reporting success.
            transport.wait(4)
        }
        // Re-read after mode settling. Retry reads only; never blindly repeat a write.
        var lastError: Error = MonitorFailure.notVerified
        for attempt in 0..<3 {
            do {
                let actual = try snapshot()
                if actual.matches(layout, pair: pair) { return actual }
                lastError = actual.mode == 0 && (layout == .leftOnly || layout == .rightOnly)
                    ? MonitorFailure.sourceReverted : MonitorFailure.notVerified
            } catch { lastError = error }
            if attempt < 2 { transport.wait(1) }
        }
        throw lastError
    }
}
