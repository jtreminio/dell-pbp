import CoreGraphics
import Foundation

/// Begin notifications arrive before macOS completes a display reconfiguration.
/// Keep the CoreGraphics callback small; handle power and UI work outside it.
final class DisplayChangeObserver {
    private let handler: (CGDirectDisplayID) -> Void
    private var registered = false
    private static let callback: CGDisplayReconfigurationCallBack = { display, flags, context in
        guard flags.contains(.beginConfigurationFlag), let context else { return }
        let observer = Unmanaged<DisplayChangeObserver>.fromOpaque(context).takeUnretainedValue()
        DispatchQueue.main.async { [weak observer] in observer?.handler(display) }
    }
    init(handler: @escaping (CGDirectDisplayID) -> Void) {
        self.handler = handler
        registered = CGDisplayRegisterReconfigurationCallback(Self.callback, Unmanaged.passUnretained(self).toOpaque()) == .success
    }
    func stop() {
        if registered {
            CGDisplayRemoveReconfigurationCallback(Self.callback, Unmanaged.passUnretained(self).toOpaque())
            registered = false
        }
    }
    deinit { stop() }
}
