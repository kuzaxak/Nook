// Licensed under GPL-3.0. See LICENSE.
//
//  HIDSecurityKeySource.swift
//  Nook
//
//  USB security keys through IOHIDManager: HID devices whose primary usage is FIDO (page
//  0xF1D0, usage 0x01) with 64-byte reports. Devices are opened shared, only while a ceremony
//  runs, and reports arrive on the main run loop.
//

#if os(macOS)
import Foundation
import IOKit.hid

@MainActor
final class HIDSecurityKeySource: SecurityKeyHIDSource {
    private var manager: IOHIDManager?
    private var keys: [HIDSecurityKey] = []
    private var arrived: ((SecurityKeyHID) -> Void)?

    func start(arrived: @escaping (SecurityKeyHID) -> Void) -> [SecurityKeyHID] {
        stop()
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDPrimaryUsagePageKey: 0xf1d0, kIOHIDPrimaryUsageKey: 0x01] as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            let source = Unmanaged<HIDSecurityKeySource>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { source.matched(device) }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let source = Unmanaged<HIDSecurityKeySource>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { source.removed(device) }
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        // A device another program holds exclusively makes this fail; the others still open.
        _ = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        let present = (IOHIDManagerCopyDevices(manager) as NSSet?)?.allObjects ?? []
        for device in present { add(device as! IOHIDDevice) }
        self.arrived = arrived
        return keys
    }

    func stop() {
        arrived = nil
        keys.forEach { $0.close() }
        keys = []
        guard let manager else { return }
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
    }

    @discardableResult
    private func add(_ device: IOHIDDevice) -> HIDSecurityKey? {
        guard !keys.contains(where: { $0.device === device }), let key = HIDSecurityKey(device) else { return nil }
        keys.append(key)
        return key
    }

    private func matched(_ device: IOHIDDevice) {
        guard let key = add(device) else { return }
        arrived?(key)
    }

    private func removed(_ device: IOHIDDevice) {
        guard let index = keys.firstIndex(where: { $0.device === device }) else { return }
        let key = keys.remove(at: index)
        key.close()
        key.unplugged()
    }
}

@MainActor
final class HIDSecurityKey: SecurityKeyHID {
    let device: IOHIDDevice
    var onInput: ((Data?) -> Void)?
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: CTAPHID.reportSize)
    private var isOpen = true

    init?(_ device: IOHIDDevice) {
        func size(_ key: String) -> Int? { IOHIDDeviceGetProperty(device, key as CFString) as? Int }
        guard size(kIOHIDMaxInputReportSizeKey) == CTAPHID.reportSize, size(kIOHIDMaxOutputReportSizeKey) == CTAPHID.reportSize
        else {
            buffer.deallocate()
            return nil
        }
        self.device = device
        IOHIDDeviceRegisterInputReportCallback(device, buffer, CTAPHID.reportSize, { context, result, _, _, _, report, length in
            guard let context, result == kIOReturnSuccess else { return }
            let key = Unmanaged<HIDSecurityKey>.fromOpaque(context).takeUnretainedValue()
            let data = Data(bytes: report, count: length)
            MainActor.assumeIsolated { key.onInput?(data) }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit {
        buffer.deallocate()
    }

    func write(_ report: Data) -> Bool {
        guard isOpen, report.count == CTAPHID.reportSize else { return false }
        // FIDO HID descriptors have no report IDs: ID 0 and the 64 bytes alone.
        let result = report.withUnsafeBytes { bytes in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, bytes.bindMemory(to: UInt8.self).baseAddress!, bytes.count)
        }
        return result == kIOReturnSuccess
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        IOHIDDeviceRegisterInputReportCallback(device, buffer, CTAPHID.reportSize, nil, nil)
    }

    func unplugged() {
        onInput?(nil)
    }
}
#endif
