import Foundation
import IOKit
import IOKit.hid
import IOKit.hidsystem

/// Caps Lock as the language key. macOS's own "Caps Lock switches input source" is slow and drops quick taps,
/// so while LazyBoard runs the key is remapped (for this login only, nothing written to disk) to F18. F18 reaches
/// the event tap as a plain key down and key up, so KeyMonitor can time it: a tap switches Thai/English at once,
/// a hold turns the real Caps Lock on or off. Quitting, turning the option off, or a password field (where the
/// tap cannot see keys) puts the normal Caps Lock back.
enum CapsKey {
    /// kVK_F18: what Caps Lock arrives as while remapped.
    static let keyCode = 0x4F
    private static let capsUsage: UInt64 = 0x7_0000_0039
    private static let f18Usage: UInt64 = 0x7_0000_006D
    private static let mappingKey = "UserKeyMapping" as CFString
    private static let srcKey = "HIDKeyboardModifierMappingSrc"
    private static let dstKey = "HIDKeyboardModifierMappingDst"

    private(set) static var isRemapped = false

    /// Remap Caps Lock to F18 on every keyboard, keeping any mapping the writer set up already.
    @discardableResult
    static func remap() -> Bool {
        var count = 0
        for service in keyboards() {
            var map = currentMapping(service).filter { !isCaps($0) }
            map.append([srcKey: NSNumber(value: capsUsage), dstKey: NSNumber(value: f18Usage)])
            if IOHIDServiceClientSetProperty(service, mappingKey, map as CFArray) { count += 1 }
        }
        isRemapped = count > 0
        Log.write("caps: remapped to F18 on \(count) keyboard(s)")
        if isRemapped { startWatchdog() }
        return isRemapped
    }

    /// Give Caps Lock back to macOS.
    static func restore() {
        guard isRemapped else { return }
        for service in keyboards() {
            let map = currentMapping(service)
            guard map.contains(where: isCaps) else { continue }
            _ = IOHIDServiceClientSetProperty(service, mappingKey, map.filter { !isCaps($0) } as CFArray)
        }
        isRemapped = false
        stopWatchdog()
        Log.write("caps: normal Caps Lock restored")
    }

    // MARK: Watchdog

    /// If LazyBoard dies without quitting (a crash, a force quit), nobody is left to handle F18 and Caps Lock
    /// would do nothing until the next launch. A tiny shell process outlives the app and, the moment the app
    /// is gone, takes the remap off again. A normal quit stops it first.
    private static var watchdog: Process?

    private static func startWatchdog() {
        guard watchdog == nil else { return }
        let pid = ProcessInfo.processInfo.processIdentifier
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 1; done; "
            + "/usr/bin/hidutil property --set '{\"UserKeyMapping\":[]}' >/dev/null 2>&1"]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            watchdog = p
        } catch {
            Log.write("caps: watchdog did not start (\(error.localizedDescription))")
        }
    }

    private static func stopWatchdog() {
        if let p = watchdog, p.isRunning { p.terminate() }
        watchdog = nil
    }

    /// The real Caps Lock (upper case) state.
    static var lockOn: Bool {
        get {
            withConnection { c in
                var on = false
                return IOHIDGetModifierLockState(c, Int32(kIOHIDCapsLockState), &on) == KERN_SUCCESS ? on : nil
            } ?? false
        }
        set {
            _ = withConnection { c in IOHIDSetModifierLockState(c, Int32(kIOHIDCapsLockState), newValue) == KERN_SUCCESS }
        }
    }

    // MARK: Private

    /// Kept for the app's life: services point back at their client, and using one after it is freed aborts.
    private static let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)

    private static func keyboards() -> [IOHIDServiceClient] {
        guard let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] else { return [] }
        return services.filter {
            IOHIDServiceClientConformsTo($0, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Keyboard)) != 0
        }
    }

    private static func currentMapping(_ service: IOHIDServiceClient) -> [[String: Any]] {
        (IOHIDServiceClientCopyProperty(service, mappingKey) as? [[String: Any]]) ?? []
    }

    private static func isCaps(_ entry: [String: Any]) -> Bool {
        (entry[srcKey] as? NSNumber)?.uint64Value == capsUsage
    }

    private static func withConnection<T>(_ body: (io_connect_t) -> T?) -> T? {
        let service = IOServiceGetMatchingService(mach_port_t(MACH_PORT_NULL), IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var connect: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect) == KERN_SUCCESS else { return nil }
        defer { IOServiceClose(connect) }
        return body(connect)
    }
}
