import Foundation
import CoreAudio
import Observation

/// Watches the system's default output device with Core Audio property listeners: device
/// switches (AirPods connecting, picking another output in Control Center) and the built-in
/// output's data source (headphones plugged into the jack). Main actor; posts
/// `didChangeNotification` after each change.
@MainActor
@Observable
final class AudioOutputMonitor {
    static let shared = AudioOutputMonitor()
    static let didChangeNotification = Notification.Name("ReelAudioOutputDidChange")

    private(set) var device: AudioOutputDevice?

    @ObservationIgnored private var deviceID = AudioObjectID(kAudioObjectUnknown)
    @ObservationIgnored private var started = false
    @ObservationIgnored private var systemListener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var deviceListener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var pendingRefresh: DispatchWorkItem?

    private init() {}

    /// Starts listening (idempotent) and reads the current device.
    func start() {
        guard !started else { return }
        started = true
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
        systemListener = listener
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        if status != noErr { Log.audio.error("Can't watch the output device (\(status))") }
        refresh()
    }

    /// Core Audio sends bursts of notifications while a device (re)connects; settle first.
    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func refresh() {
        let id = Self.defaultOutputDeviceID() ?? AudioObjectID(kAudioObjectUnknown)
        if id != deviceID {
            watchDevice(id)
            deviceID = id
        }
        let current = id == AudioObjectID(kAudioObjectUnknown) ? nil : Self.describe(id)
        guard current != device else { return }
        device = current
        if let d = current {
            Log.audio.notice("Output device: \(d.name, privacy: .public) [\(d.transport.rawValue, privacy: .public), \(d.manufacturer, privacy: .public), model \(d.modelUID, privacy: .public), \(d.outputChannels) ch\(d.isHeadphonePort ? ", headphone jack" : "", privacy: .public)] → \(String(describing: d.kind), privacy: .public)")
        } else {
            Log.audio.notice("No output device")
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// Follows the headphone jack and renames on the current device.
    private func watchDevice(_ id: AudioObjectID) {
        let old = deviceID
        if old != AudioObjectID(kAudioObjectUnknown), let listener = deviceListener {
            for var address in Self.deviceAddresses {
                _ = AudioObjectRemovePropertyListenerBlock(old, &address, .main, listener)
            }
        }
        deviceListener = nil
        guard id != AudioObjectID(kAudioObjectUnknown) else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
        deviceListener = listener
        for var address in Self.deviceAddresses {
            if AudioObjectHasProperty(id, &address) {
                _ = AudioObjectAddPropertyListenerBlock(id, &address, .main, listener)
            }
        }
    }

    private static let deviceAddresses: [AudioObjectPropertyAddress] = [
        address(kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput),
        address(kAudioObjectPropertyName),
    ]

    // MARK: - Reading device properties

    nonisolated static func defaultOutputDeviceID() -> AudioObjectID? {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != AudioObjectID(kAudioObjectUnknown) ? id : nil
    }

    nonisolated static func describe(_ id: AudioObjectID) -> AudioOutputDevice {
        let name = string(id, kAudioObjectPropertyName) ?? "Output \(id)"
        let uid = string(id, kAudioDevicePropertyDeviceUID) ?? name
        let dataSource = uint32(id, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput)
        return AudioOutputDevice(
            uid: uid, name: name,
            manufacturer: string(id, kAudioObjectPropertyManufacturer) ?? "",
            modelUID: string(id, kAudioDevicePropertyModelUID) ?? "",
            transport: transport(uint32(id, kAudioDevicePropertyTransportType) ?? 0),
            isHeadphonePort: dataSource == fourCC("hdpn"),
            outputChannels: outputChannels(id))
    }

    nonisolated static func transport(_ value: UInt32) -> AudioOutputDevice.Transport {
        switch value {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeBluetooth: return .bluetooth
        case kAudioDeviceTransportTypeBluetoothLE: return .bluetoothLE
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeHDMI: return .hdmi
        case kAudioDeviceTransportTypeDisplayPort: return .displayPort
        case kAudioDeviceTransportTypeAirPlay: return .airPlay
        case kAudioDeviceTransportTypeThunderbolt: return .thunderbolt
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: return .aggregate
        case kAudioDeviceTransportTypeVirtual: return .virtual
        default: return .other
        }
    }

    nonisolated static func fourCC(_ s: String) -> UInt32 {
        s.utf8.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private nonisolated static func address(_ selector: AudioObjectPropertySelector,
                                            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private nonisolated static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        let s = value.takeRetainedValue() as String
        return s.isEmpty ? nil : s
    }

    private nonisolated static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                           scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var address = address(selector, scope: scope)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private nonisolated static func outputChannels(_ id: AudioObjectID) -> Int {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
