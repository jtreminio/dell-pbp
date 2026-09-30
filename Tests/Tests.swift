import Foundation

final class FakeTransport: MonitorTransport {
    let identifier = "test"
    var values: [UInt8: UInt16]
    var writes: [(UInt8, UInt16)] = []
    var waits: [Double] = []
    var ignoreWrites = false
    var rejectWrites = false
    var primaryAlsoChangesSecondary = false
    var soloInputOnPBPOff: UInt16?
    init(mode: UInt16 = 0x24, main: UInt16 = 0x1919, secondary: UInt16 = 0x0F) {
        values = [0xE9: mode, 0x60: main, 0xE8: secondary]
    }
    func read(_ feature: UInt8) throws -> UInt16 { values[feature]! }
    func write(_ feature: UInt8, value: UInt16) throws {
        if rejectWrites { throw NSError(domain: "test", code: 1) }
        writes.append((feature, value))
        if !ignoreWrites {
            values[feature] = value
            if primaryAlsoChangesSecondary && feature == 0x60 { values[0xE8] = 0x11 }
            if feature == 0xE9 && value == 0, let soloInputOnPBPOff { values[0x60] = soloInputOnPBPOff }
        }
    }
    func wait(_ seconds: Double) { waits.append(seconds) }
}

@main struct Tests {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ description: String) {
        guard condition() else { fatalError("FAIL: " + description) }
        count += 1
    }
    static func rejects(_ description: String, _ operation: () throws -> Void) {
        do { try operation(); fatalError("FAIL: expected rejection: " + description) }
        catch { count += 1 }
    }
    static func main() throws {
        let pair = InputPair(left: .thunderbolt, right: .displayPort)
        check(Layout.all.count == 7, "exactly seven layouts")
        check(Layout.leftOnly.shows(.thunderbolt, pair: pair), "wake visible local input")
        check(!Layout.rightOnly.shows(.thunderbolt, pair: pair), "do not wake hidden local input and steal monitor")
        check(Layout.rightOnly.shows(.displayPort, pair: pair), "local Mac can be on either port")
        check(!Layout.rightOnly.shows(nil, pair: pair), "unknown local port cannot trigger solo wake")
        let hidden = FakeTransport()
        var writesAtCancellation: [UInt8] = []
        _ = try MonitorSession(hidden).apply(.rightOnly, pair: pair, beforeHidingLocalInput: {
            if writesAtCancellation.isEmpty { writesAtCancellation = hidden.writes.map { $0.0 } }
        })
        check(writesAtCancellation == [0x60], "wake stays active during PBP source swap, stops before local input is hidden")
        let rememberedSolo = FakeTransport(main: 0x190F, secondary: 0x19)
        rememberedSolo.soloInputOnPBPOff = 0x1919
        let rememberedState = try MonitorSession(rememberedSolo).apply(.rightOnly, pair: pair)
        check(rememberedState.matches(.rightOnly, pair: pair), "solo source selected after monitor restores remembered source")
        let visible = FakeTransport()
        var cancelledVisible = false
        _ = try MonitorSession(visible).apply(.leftOnly, pair: pair, beforeHidingLocalInput: { cancelledVisible = true })
        check(!cancelledVisible, "wake remains active for visible local solo input")
        check(Set(Split.allCases.map(\.rawValue)) == [0x24,0x27,0x28,0x29,0x2A], "only supported PBP values")
        check(InputSource(reportedValue: 0x1919) == .thunderbolt, "duplicate input bytes normalize")
        check(InputSource(reportedValue: 0x0F0F) == .displayPort, "DisplayPort duplicate bytes normalize")
        check(InputSource(reportedValue: 0x1B) == nil, "cross-model USB-C code is not guessed")
        let connected = try MonitorSession(FakeTransport(main: 0x190F, secondary: 0x19)).snapshot()
        check(connected.primary == .displayPort && connected.connectedInput == .thunderbolt, "local Mac port stays distinct from selected main input")
        check(connected.isLocalInputVisible, "secondary Mac is visible in PBP")
        var hiddenLocal = connected
        hiddenLocal.mode = 0
        check(!hiddenLocal.isLocalInputVisible, "inactive solo Mac must stop automatic wake")
        hiddenLocal.primary = .thunderbolt
        check(hiddenLocal.isLocalInputVisible, "active solo Mac remains protected")
        hiddenLocal.connectedInput = nil
        check(!hiddenLocal.isLocalInputVisible, "unknown local connection does not arm automatic wake")
        let swappedHardware = FakeTransport(mode: Split.twentyEighty.rawValue)
        let swappedSession = MonitorSession(swappedHardware)
        let (swappedState, swappedPair) = try swappedSession.switchDisplays()
        check(swappedPair == pair.reversed && swappedState.pair == swappedPair, "Switch Displays flips actual inputs")
        check(swappedState.mode == Split.twentyEighty.rawValue, "Switch Displays preserves asymmetric ratio")
        let (_, backAgain) = try swappedSession.switchDisplays()
        check(backAgain == pair, "Switch Displays twice restores input order")
        let soloSwap = FakeTransport(mode: 0)
        rejects("Switch Displays requires PBP") { _ = try MonitorSession(soloSwap).switchDisplays() }
        check(soloSwap.writes.isEmpty, "solo swap performs no writes")
        let failedSwap = FakeTransport()
        failedSwap.ignoreWrites = true
        rejects("unconfirmed swap does not return a saved pair") { _ = try MonitorSession(failedSwap).switchDisplays() }
        for split in Split.allCases {
            let hardware = FakeTransport()
            let state = try MonitorSession(hardware).apply(.split(split), pair: pair)
            check(state.matches(.split(split), pair: pair), "split readback matches")
            check(hardware.writes.count == (split == .half ? 0 : 1), "no unnecessary routing changes")
            check(hardware.writes.allSatisfy { $0.0 == 0xE9 }, "split changes only E9 when inputs match")
        }
        for layout: Layout in [.leftOnly, .rightOnly] {
            let hardware = FakeTransport()
            let session = MonitorSession(hardware)
            let solo = try session.apply(layout, pair: pair)
            check(solo.matches(layout, pair: pair), "solo selects intended port")
            check(solo.pair == nil, "solo cannot redefine saved pair")
            let restored = try session.apply(.split(.half), pair: pair)
            check(restored.matches(.split(.half), pair: pair), "solo returns to original pair")
        }
        let packed = FakeTransport(main: 0x0F0F, secondary: 0x6B11)
        _ = try MonitorSession(packed).apply(.split(.half), pair: pair)
        check(packed.values[0xE8] == 0x6B0F, "secondary update preserves packed upper fields")
        let swap = FakeTransport(main: 0x0F, secondary: 0x19)
        swap.primaryAlsoChangesSecondary = true
        let swapped = try MonitorSession(swap).apply(.split(.half), pair: pair)
        check(swapped.matches(.split(.half), pair: pair), "secondary reread handles monitor source side effects")
        let ignoring = FakeTransport()
        ignoring.ignoreWrites = true
        rejects("transport success is not acceptance") { _ = try MonitorSession(ignoring).apply(.split(.twentyEighty), pair: pair) }
        check(ignoring.writes.count == 1, "failed verification does not repeat writes")
        let rejecting = FakeTransport()
        rejecting.rejectWrites = true
        rejects("write error surfaces") { _ = try MonitorSession(rejecting).apply(.leftOnly, pair: pair) }
        let invalid = FakeTransport(main: 0xFF)
        rejects("unknown input blocks operation") { _ = try MonitorSession(invalid).apply(.leftOnly, pair: pair) }
        check(invalid.writes.isEmpty, "unknown input never sends changes")
        let duplicate = FakeTransport()
        rejects("same input on both sides") { _ = try MonitorSession(duplicate).apply(.leftOnly, pair: InputPair(left: .hdmi, right: .hdmi)) }
        check(duplicate.writes.isEmpty, "duplicate input fails before changes")
        try packetTests()
        print("PASS: \(count) checks. No monitor accessed.")
    }
    static func packetTests() throws {
        var response: [UInt8] = [0x6E,0x88,0x02,0x00,0xE9,0x00,0x00,0xFF,0x00,0x24,0x86,0]
        func decode(_ bytes: [UInt8], feature: UInt8 = 0xE9) -> (Bool, UInt16) {
            var result: UInt16 = 0
            let accepted = bytes.withUnsafeBufferPointer { DDCDecodeReply($0.baseAddress!, $0.count, feature, &result) }
            return (accepted, result)
        }
        check(decode(response).0 && decode(response).1 == 0x24, "valid wire reply")
        check(!decode(Array(response.prefix(10))).0, "truncated reply rejected")
        check(!decode(response, feature: 0x60).0, "wrong feature rejected")
        for index in 0..<11 {
            var corrupt = response
            corrupt[index] ^= 1
            check(!decode(corrupt).0, "corrupt byte \(index) rejected")
        }
        response[3] = 1
        response[10] ^= 1
        check(!decode(response).0, "valid checksum with monitor error still rejected")
        response = [0x6E,0x88,0x02,0x00,0x60,0x00,0x19,0x19,0x19,0x19,0,0]
        response[10] = response.prefix(10).reduce(0x50, ^)
        check(decode(response, feature: 0x60).1 == 0x1919, "full 16-bit current value preserved")
    }
}
