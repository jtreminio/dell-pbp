import AppKit

@main
struct DellPBP {
    @MainActor static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--status") {
            do {
                let connection = try NativeTransport()
                let state = try MonitorSession(connection).snapshot()
                let result: [String: Any] = ["monitor": "Dell U4025QW", "mode": state.mode, "mainInput": state.primary.title,
                    "mainInputValue": state.primary.rawValue, "secondaryInput": state.secondary?.title ?? "Unknown", "secondaryRaw": state.secondaryRaw,
                    "thisMacInput": state.connectedInput?.title ?? "Unknown"]
                let json = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                print(String(decoding: json, as: UTF8.self))
            } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
            return
        }
        if arguments.contains("--help") {
            print("Dell PBP: menu-bar app for Apple silicon and Dell U4025QW.\n--status      Read current monitor settings; no changes\n--demo        Run with a simulated monitor\n--show-menu   Open the menu after launch")
            return
        }
        guard arguments.allSatisfy({ ["--demo", "--show-menu"].contains($0) }) else {
            fputs("Unknown option. Use --help.\n", stderr); exit(2)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate(demo: arguments.contains("--demo"))
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
