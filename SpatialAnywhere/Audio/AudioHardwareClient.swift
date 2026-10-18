import AppKit
import CoreAudio
import Foundation

struct AudioProcessInfo: Equatable, Identifiable, Sendable {
    let id: AudioObjectID
    let pid: pid_t
    /// Bundle ID Core Audio reports for this process (a helper's own ID for helpers).
    let bundleIdentifier: String
    /// The app the process belongs to: the outermost `.app` bundle around its executable.
    let owningAppBundleIdentifier: String?
    let owningAppName: String?
    let owningAppPath: String?
    /// The owning app shows in the Dock, i.e. it is something a person plays media in.
    let owningAppIsRegular: Bool
    let isRunningOutput: Bool
}

struct OutputDeviceInfo: Equatable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let sampleRate: Double

    var isLikelySpatialAudioHeadphones: Bool {
        let normalized = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return normalized.contains("airpods") ||
            normalized.contains("beats fit pro") ||
            normalized.contains("beats studio pro")
    }
}

final class AudioHardwareClient {
    private let systemObject = AudioObjectID(kAudioObjectSystemObject)

    /// macOS 26 taps can follow bundle identifiers, which also captures helper
    /// processes that start after the tap was created.
    static var tapsFollowBundleIdentifiers: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// Every process Core Audio knows about, except this app itself.
    func audioProcesses() throws -> [AudioProcessInfo] {
        var address = propertyAddress(kAudioHardwarePropertyProcessObjectList)
        var byteCount: UInt32 = 0
        try CoreAudioFailure.check(
            AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &byteCount),
            operation: "Reading the audio process list size"
        )

        let count = Int(byteCount) / MemoryLayout<AudioObjectID>.stride
        guard count > 0 else { return [] }
        var objectIDs = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        let listStatus = objectIDs.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(systemObject, &address, 0, nil, &byteCount, bytes.baseAddress!)
        }
        try CoreAudioFailure.check(listStatus, operation: "Reading the audio process list")

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let runningApps = NSWorkspace.shared.runningApplications
        var appsByPath: [String: NSRunningApplication] = [:]
        for app in runningApps {
            if let path = app.bundleURL?.standardizedFileURL.path { appsByPath[path] = app }
        }

        return objectIDs.compactMap { objectID in
            guard objectID != kAudioObjectUnknown else { return nil }

            let pid = (try? readPID(objectID)) ?? 0
            guard pid != ownPID else { return nil }

            let application = NSRunningApplication(processIdentifier: pid)
            let coreAudioBundleID = (try? readString(objectID, selector: kAudioProcessPropertyBundleID)) ?? ""
            let bundleID = coreAudioBundleID.isEmpty ? (application?.bundleIdentifier ?? "") : coreAudioBundleID

            let executablePath = application?.bundleURL?.standardizedFileURL.path ?? Self.executablePath(of: pid)
            let ownerPath = executablePath.flatMap(AppBundlePath.outermostApplication(containing:))
            let owner = ownerPath.flatMap { appsByPath[$0] }
            let ownerBundleID = owner?.bundleIdentifier ?? ownerPath.flatMap { Bundle(path: $0)?.bundleIdentifier }
            let ownerName = owner?.localizedName ?? ownerPath.map {
                FileManager.default.displayName(atPath: $0).replacingOccurrences(of: ".app", with: "")
            }

            return AudioProcessInfo(
                id: objectID,
                pid: pid,
                bundleIdentifier: bundleID,
                owningAppBundleIdentifier: ownerBundleID,
                owningAppName: ownerName,
                owningAppPath: ownerPath,
                owningAppIsRegular: owner?.activationPolicy == .regular,
                isRunningOutput: (try? readBool(objectID, selector: kAudioProcessPropertyIsRunningOutput)) ?? false
            )
        }
        .sorted { $0.pid < $1.pid }
    }

    private static func executablePath(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    func defaultOutputDevice() throws -> OutputDeviceInfo {
        var address = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var byteCount = UInt32(MemoryLayout<AudioDeviceID>.size)
        try CoreAudioFailure.check(
            AudioObjectGetPropertyData(systemObject, &address, 0, nil, &byteCount, &deviceID),
            operation: "Finding the default output device"
        )

        guard deviceID != kAudioObjectUnknown else {
            throw RelayError.noOutputDevice
        }

        return OutputDeviceInfo(
            id: deviceID,
            uid: try readString(deviceID, selector: kAudioDevicePropertyDeviceUID),
            name: try readString(deviceID, selector: kAudioObjectPropertyName),
            sampleRate: try readDouble(deviceID, selector: kAudioDevicePropertyNominalSampleRate)
        )
    }

    func createTap(target: TapTarget, outputDevice: OutputDeviceInfo) throws -> AudioObjectID {
        let description = CATapDescription()
        description.name = "Spatial Anywhere"
        if #available(macOS 26.0, *) {
            description.bundleIDs = target.bundleIdentifiers
            description.processes = []
            description.isProcessRestoreEnabled = true
        } else {
            description.processes = target.processObjectIDs
        }
        description.isPrivate = true
        description.isExclusive = false
        description.isMixdown = true
        description.isMono = false
        description.muteBehavior = .mutedWhenTapped
        description.deviceUID = outputDevice.uid
        description.stream = 0

        var tapID = AudioObjectID(kAudioObjectUnknown)
        try CoreAudioFailure.check(
            AudioHardwareCreateProcessTap(description, &tapID),
            operation: "Creating the process tap"
        )
        return tapID
    }

    func tapUID(_ tapID: AudioObjectID) throws -> String {
        try readString(tapID, selector: kAudioTapPropertyUID)
    }

    func tapFormat(_ tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = propertyAddress(kAudioTapPropertyFormat)
        var format = AudioStreamBasicDescription()
        var byteCount = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try CoreAudioFailure.check(
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &byteCount, &format),
            operation: "Reading the process tap format"
        )
        return format
    }

    func createAggregateDevice(tapUID: String) throws -> AudioObjectID {
        let aggregateUID = "com.asher0913.SpatialAnywhere.aggregate.\(UUID().uuidString)"
        let tapEntry: [String: Any] = [
            kAudioSubTapUIDKey: tapUID,
            kAudioSubTapDriftCompensationKey: true
        ]
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Spatial Anywhere Capture",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [tapEntry]
        ]

        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        try CoreAudioFailure.check(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID),
            operation: "Creating the private tap device"
        )
        return aggregateID
    }

    @discardableResult
    func destroyAggregateDevice(_ deviceID: AudioObjectID) -> OSStatus {
        guard deviceID != kAudioObjectUnknown else { return noErr }
        return AudioHardwareDestroyAggregateDevice(deviceID)
    }

    @discardableResult
    func destroyTap(_ tapID: AudioObjectID) -> OSStatus {
        guard tapID != kAudioObjectUnknown else { return noErr }
        return AudioHardwareDestroyProcessTap(tapID)
    }

    /// Restores direct process audio even if a lower-level callback cannot be
    /// destroyed immediately. This is the teardown path's last-resort safety net.
    @discardableResult
    func unmuteTap(_ tapID: AudioObjectID) -> OSStatus {
        guard tapID != kAudioObjectUnknown else { return noErr }

        var address = propertyAddress(kAudioTapPropertyDescription)
        var description: CATapDescription?
        var byteCount = UInt32(MemoryLayout<CATapDescription?>.size)
        let readStatus = withUnsafeMutablePointer(to: &description) { pointer in
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &byteCount, pointer)
        }
        guard readStatus == noErr else { return readStatus }
        guard let description else { return kAudioHardwareUnspecifiedError }

        description.muteBehavior = .unmuted
        var updatedDescription: CATapDescription? = description
        byteCount = UInt32(MemoryLayout<CATapDescription?>.size)
        return withUnsafePointer(to: &updatedDescription) { pointer in
            AudioObjectSetPropertyData(tapID, &address, 0, nil, byteCount, pointer)
        }
    }

    private func readPID(_ objectID: AudioObjectID) throws -> pid_t {
        var address = propertyAddress(kAudioProcessPropertyPID)
        var value: pid_t = 0
        var byteCount = UInt32(MemoryLayout<pid_t>.size)
        try CoreAudioFailure.check(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &byteCount, &value),
            operation: "Reading an audio process identifier"
        )
        return value
    }

    private func readBool(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) throws -> Bool {
        var address = propertyAddress(selector)
        var value: UInt32 = 0
        var byteCount = UInt32(MemoryLayout<UInt32>.size)
        try CoreAudioFailure.check(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &byteCount, &value),
            operation: "Reading an audio property"
        )
        return value != 0
    }

    private func readDouble(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) throws -> Double {
        var address = propertyAddress(selector)
        var value: Float64 = 0
        var byteCount = UInt32(MemoryLayout<Float64>.size)
        try CoreAudioFailure.check(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &byteCount, &value),
            operation: "Reading an audio property"
        )
        return value
    }

    private func readString(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) throws -> String {
        var address = propertyAddress(selector)
        var value: CFString = "" as CFString
        var byteCount = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &byteCount, pointer)
        }
        try CoreAudioFailure.check(status, operation: "Reading an audio property")
        return value as String
    }
}
