// Explicit opt-in integration test. Changes real layouts, then restores the starting state.
import Foundation

@main struct HardwareSmoke {
    static func log(_ message: String) { print(message); fflush(stdout) }
    static func awake<T>(_ body: () throws -> T) rethrows -> T {
        let guardObject = DisplayWakeGuard()
        log("Wake protection: \(guardObject.activeAssertionCount) assertions active")
        defer { guardObject.finish() }
        return try body()
    }
    static func apply(_ layout: Layout, session: MonitorSession, pair: InputPair) throws -> MonitorState {
        let guardObject = DisplayWakeGuard()
        defer { guardObject.finish() }
        return try session.apply(layout, pair: pair, beforeHidingLocalInput: { guardObject.cancel() })
    }
    static func main() {
        guard CommandLine.arguments.contains("--allow-display-changes") else {
            fputs("Requires --allow-display-changes. The display will resize during this test.\n", stderr)
            exit(2)
        }
        do {
            let transport = try NativeTransport()
            let session = MonitorSession(transport)
            let initial = try session.snapshot()
            guard let pair = initial.pair, let initialSplit = Split(rawValue: initial.mode) else {
                fputs("Start from a supported PBP mode with two distinct inputs. No changes made.\n", stderr)
                exit(2)
            }
            log("Initial: \(initialSplit.title), left \(pair.left.title), right \(pair.right.title)")
            var failure: Error?
            var tested: [String] = []
            do {
                let soloCheck = CommandLine.arguments.contains("--solo-stability")
                let layouts: [Layout] = soloCheck ? [.rightOnly] : CommandLine.arguments.contains("--routing-only") ? [.leftOnly, .rightOnly] : Layout.all
                if !soloCheck {
                    let (firstSwap, _) = try awake { try session.switchDisplays() }
                    guard firstSwap.pair == pair.reversed, firstSwap.connectedInput == initial.connectedInput else { throw MonitorFailure.notVerified }
                    log("PASS: Switch Displays, local Mac identity preserved")
                    _ = try awake { try session.switchDisplays() }
                    log("PASS: Switch Displays again restores original sides")
                }
                for layout in layouts {
                    log("Testing: \(layout.title)")
                    _ = try apply(layout, session: session, pair: pair)
                    tested.append(layout.title)
                    log("PASS: \(layout.title), readback verified")
                    if soloCheck {
                        transport.wait(8)
                        guard try session.snapshot().matches(layout, pair: pair) else { throw MonitorFailure.notVerified }
                        log("PASS: solo input remained selected after 8 seconds")
                    }
                    if layout == .leftOnly {
                        _ = try awake { try session.apply(.split(initialSplit), pair: pair) }
                        log("PASS: return from left-only to PBP")
                    }
                }
                if !soloCheck {
                    _ = try awake { try session.apply(.split(initialSplit), pair: pair) }
                    let (flipped, _) = try awake { try session.switchDisplays() }
                    guard flipped.pair == pair.reversed, flipped.mode == initial.mode, flipped.connectedInput == initial.connectedInput else { throw MonitorFailure.notVerified }
                    log("PASS: Switch Displays, ratio and local Mac identity preserved")
                    let (returned, _) = try awake { try session.switchDisplays() }
                    guard returned.pair == pair else { throw MonitorFailure.notVerified }
                    log("PASS: Switch Displays again restores original sides")
                }
            } catch { failure = error; log("FAIL: \(error.localizedDescription)") }
            // The transport rediscovers the service before every restoration command.
            // Only supported PBP and input settings are used; no firmware or USB routing changes.
            log("Restoring original layout and input pair…")
            _ = try awake { try session.apply(.split(initialSplit), pair: pair) }
            let restored = try session.snapshot()
            guard restored == initial else { throw MonitorFailure.notVerified }
            log("RESTORED: \(initialSplit.title), original sources verified")
            log("Verified layouts: \(tested.joined(separator: ", "))")
            if failure != nil { exit(1) }
        } catch {
            fputs("Hardware check ended: \(error.localizedDescription)\nUse the monitor joystick to restore PBP if needed.\n", stderr)
            exit(1)
        }
    }
}
