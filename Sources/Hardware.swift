import Foundation

final class NativeTransport: MonitorTransport {
    private let helper: URL
    let identifier: String
    init() throws {
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            helper = bundle.appendingPathComponent("Contents/Helpers/ddc-helper")
        } else {
            // The opt-in hardware test runs beside the built app.
            helper = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
                .deletingLastPathComponent().appendingPathComponent("Dell PBP.app/Contents/Helpers/ddc-helper")
        }
        let identified = try Self.invoke(helper, ["identify"])
        guard let id = identified["identifier"] as? String else { throw MonitorFailure.notVerified }
        identifier = id
    }
    private static func invoke(_ helper: URL, _ arguments: [String]) throws -> [String: Any] {
        let process = Process()
        process.executableURL = helper
        process.arguments = arguments
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        try process.run()
        guard ended.wait(timeout: .now() + 12) == .success else {
            process.terminate()
            throw NSError(domain: "DellPBP.Helper", code: 8, userInfo: [NSLocalizedDescriptionKey: "Monitor communication timed out. Refresh before trying again."])
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(domain: "DellPBP.Helper", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: detail.isEmpty ? "The monitor helper could not complete the request." : detail])
        }
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MonitorFailure.notVerified }
        return result
    }
    func read(_ feature: UInt8) throws -> UInt16 {
        var lastError: Error = MonitorFailure.notVerified
        let deadline = Date().addingTimeInterval(20)
        repeat {
            do {
                let reply = try Self.invoke(helper, ["read", String(feature), identifier])
                guard let number = reply["value"] as? NSNumber, number.intValue >= 0, number.intValue <= 65535 else { throw MonitorFailure.notVerified }
                trace("read \(String(feature, radix: 16)): \(String(number.uint16Value, radix: 16))")
                return number.uint16Value
            } catch { lastError = error; trace("reconnecting: \(error.localizedDescription)") }
            if Date() >= deadline { break }
            Thread.sleep(forTimeInterval: 1)
        } while true
        throw lastError
    }
    func write(_ feature: UInt8, value: UInt16) throws {
        // Confirm discovery/readiness before a single write. Input changes can briefly
        // remove the monitor from CoreGraphics even after its picture has returned.
        _ = try read(0xE9)
        trace("write \(String(feature, radix: 16)): \(String(value, radix: 16))")
        _ = try Self.invoke(helper, ["write", String(feature), String(value), identifier])
    }
    private func trace(_ message: String) {
        if CommandLine.arguments.contains("--trace") { print(message); fflush(stdout) }
    }
    func wait(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }
}

final class DemoTransport: MonitorTransport {
    let identifier = "demo"
    private var values: [UInt8: UInt16] = [0xE9: 0x24, 0x60: 0x1919, 0xE8: 0x0F]
    func read(_ feature: UInt8) throws -> UInt16 { values[feature, default: 0] }
    func write(_ feature: UInt8, value: UInt16) throws {
        values[feature] = feature == 0x60 ? (0x1900 | value) : value
    }
    func wait(_ seconds: Double) { Thread.sleep(forTimeInterval: 0.1) }
}

final class MonitorWorker {
    private let queue = DispatchQueue(label: "DellPBP.monitor", qos: .userInitiated)
    private var session: MonitorSession?
    private var recentWakeGuard: DisplayWakeGuard?
    let demo: Bool
    init(demo: Bool) { self.demo = demo }
    private func connectedSession() throws -> MonitorSession {
        if let session { return session }
        let transport: MonitorTransport = demo ? DemoTransport() : try NativeTransport()
        let created = MonitorSession(transport)
        session = created
        return created
    }
    func refresh(_ completion: @escaping (Result<(MonitorState, String), Error>) -> Void) {
        queue.async {
            let result = Result { () -> (MonitorState, String) in
                do {
                    let current = try self.connectedSession()
                    return (try current.snapshot(), current.transport.identifier)
                } catch {
                    // Rediscover the monitor identity after a disconnect or monitor replacement.
                    if self.demo { throw error }
                    let replacement = MonitorSession(try NativeTransport())
                    let state = try replacement.snapshot()
                    self.session = replacement
                    return (state, replacement.transport.identifier)
                }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
    func apply(_ layout: Layout, pair: InputPair, completion: @escaping (Result<MonitorState, Error>) -> Void) {
        queue.async {
            let result = Result {
                let session = try self.connectedSession()
                self.recentWakeGuard?.cancel()
                let wakeGuard = self.demo ? nil : DisplayWakeGuard()
                self.recentWakeGuard = wakeGuard
                defer { wakeGuard?.finish() }
                return try session.apply(layout, pair: pair, beforeHidingLocalInput: { wakeGuard?.cancel() })
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
    func switchDisplays(completion: @escaping (Result<(MonitorState, InputPair), Error>) -> Void) {
        queue.async {
            self.recentWakeGuard?.cancel()
            let wakeGuard = self.demo ? nil : DisplayWakeGuard()
            self.recentWakeGuard = wakeGuard
            defer { wakeGuard?.finish() }
            let result = Result { try self.connectedSession().switchDisplays() }
            DispatchQueue.main.async { completion(result) }
        }
    }
}

final class PairPreferences {
    private let defaults: UserDefaults
    init(demo: Bool) {
        let appIdentifier = Bundle.main.bundleIdentifier ?? "DellPBP"
        defaults = demo ? UserDefaults(suiteName: appIdentifier + ".demo")! : .standard
    }
    var wakeOnMonitorChanges: Bool {
        get { defaults.object(forKey: "wakeOnMonitorChanges") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "wakeOnMonitorChanges") }
    }
    var lastIdentifier: String? {
        get { defaults.string(forKey: "lastMonitor") }
        set { defaults.set(newValue, forKey: "lastMonitor") }
    }
    func load(_ identifier: String?) -> InputPair? {
        guard let identifier, let data = defaults.data(forKey: "pair." + identifier),
              let pair = try? JSONDecoder().decode(InputPair.self, from: data), pair.isValid else { return nil }
        return pair
    }
    func save(_ pair: InputPair, for identifier: String) {
        guard pair.isValid, let data = try? JSONEncoder().encode(pair) else { return }
        defaults.set(data, forKey: "pair." + identifier)
        lastIdentifier = identifier
    }
    func names(for identifier: String?) -> [String: String] {
        guard let identifier else { return [:] }
        return defaults.dictionary(forKey: "names." + identifier) as? [String: String] ?? [:]
    }
    func saveNames(_ names: [String: String], for identifier: String) {
        defaults.set(names, forKey: "names." + identifier)
    }
}
