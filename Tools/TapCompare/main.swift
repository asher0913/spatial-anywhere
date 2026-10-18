// Records a source app's own output and Spatial Anywhere's output at the same
// time, so the two can be aligned and compared sample by sample.
//
// Each recording uses its own private, unmuted Core Audio process tap scoped to
// the default output device, with drift compensation off. Raw interleaved
// Float32 frames are written to <outdir>/source.f32 and <outdir>/relay.f32.
//
// Build: swiftc -O Tools/TapCompare/main.swift -o build/tapcompare
// Use:   build/tapcompare <seconds> <outdir> <source-bundle-prefix> [relay-bundle-id]
//        python3 Tools/TapCompare/compare.py <outdir>
import CoreAudio
import Foundation

func fail(_ message: String) -> Never {
    fputs("tapcompare: \(message)\n", stderr)
    exit(1)
}

func check(_ status: OSStatus, _ what: String) {
    if status != noErr { fail("\(what) failed (\(status))") }
}

func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}

func objectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
    var a = address(selector)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(object, &a, 0, nil, &size, &ids)
    return ids
}

func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
    var a = address(selector)
    var value: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    _ = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0) }
    return value as String
}

let arguments = CommandLine.arguments
guard arguments.count >= 4, let seconds = Double(arguments[1]), seconds > 0 else {
    fail("usage: tapcompare <seconds> <outdir> <source-bundle-prefix> [relay-bundle-id]")
}
let outDir = URL(fileURLWithPath: arguments[2])
let sourcePrefix = arguments[3]
let relayBundleID = arguments.count > 4 ? arguments[4] : "com.asher0913.SpatialAnywhere"
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let system = AudioObjectID(kAudioObjectSystemObject)
var defaultOutput = AudioObjectID(0)
var outputAddress = address(kAudioHardwarePropertyDefaultOutputDevice)
var outputSize = UInt32(MemoryLayout<AudioObjectID>.size)
check(AudioObjectGetPropertyData(system, &outputAddress, 0, nil, &outputSize, &defaultOutput), "Reading the default output")
let outputUID = string(defaultOutput, kAudioDevicePropertyDeviceUID)

var sourceProcesses: [AudioObjectID] = []
var relayProcesses: [AudioObjectID] = []
for process in objectList(system, kAudioHardwarePropertyProcessObjectList) {
    let bundleID = string(process, kAudioProcessPropertyBundleID)
    if bundleID.hasPrefix(sourcePrefix) { sourceProcesses.append(process) }
    if bundleID == relayBundleID { relayProcesses.append(process) }
}
guard !sourceProcesses.isEmpty else { fail("no Core Audio process matches \(sourcePrefix)") }
guard !relayProcesses.isEmpty else { fail("\(relayBundleID) has no Core Audio process; start the relay first") }

final class Recording {
    let name: String
    let capacity: Int
    let samples: UnsafeMutablePointer<Float>
    var frames = 0
    var gaps = 0
    var nextSampleTime: Double = -1

    init(name: String, capacityFrames: Int) {
        self.name = name
        capacity = capacityFrames
        samples = .allocate(capacity: capacityFrames * 2)
        samples.initialize(repeating: 0, count: capacityFrames * 2)
    }
}

var cleanup: [(tap: AudioObjectID, aggregate: AudioObjectID, proc: AudioDeviceIOProcID?)] = []
var recordings: [Recording] = []
let ioQueue = DispatchQueue(label: "tapcompare.io")

for (processes, name) in [(sourceProcesses, "source"), (relayProcesses, "relay")] {
    let description = CATapDescription()
    description.name = "tapcompare \(name)"
    description.processes = processes
    description.isPrivate = true
    description.isExclusive = false
    description.isMixdown = true
    description.isMono = false
    description.muteBehavior = .unmuted
    description.deviceUID = outputUID
    description.stream = 0

    var tap = AudioObjectID(0)
    check(AudioHardwareCreateProcessTap(description, &tap), "Creating the \(name) tap")
    let aggregateDescription: [String: Any] = [
        kAudioAggregateDeviceNameKey: "tapcompare \(name)",
        kAudioAggregateDeviceUIDKey: "tapcompare.\(name).\(UUID().uuidString)",
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceTapListKey: [[
            kAudioSubTapUIDKey: string(tap, kAudioTapPropertyUID),
            kAudioSubTapDriftCompensationKey: false,
        ]],
    ]
    var aggregate = AudioObjectID(0)
    check(AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate), "Creating the \(name) device")

    let recording = Recording(name: name, capacityFrames: Int(seconds * 48_000) + 48_000)
    var proc: AudioDeviceIOProcID?
    check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, ioQueue) { _, input, inputTime, _, _ in
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard buffers.count == 1, buffers[0].mNumberChannels == 2, let data = buffers[0].mData else { return }
        let count = min(Int(buffers[0].mDataByteSize) / 8, recording.capacity - recording.frames)
        guard count > 0 else { return }
        memcpy(recording.samples + recording.frames * 2, data, count * 8)
        let sampleTime = inputTime.pointee.mSampleTime
        if recording.nextSampleTime >= 0, abs(sampleTime - recording.nextSampleTime) > 0.5 { recording.gaps += 1 }
        recording.nextSampleTime = sampleTime + Double(count)
        recording.frames += count
    }, "Creating the \(name) callback")

    cleanup.append((tap, aggregate, proc))
    recordings.append(recording)
}

for item in cleanup { check(AudioDeviceStart(item.aggregate, item.proc), "Starting a recording") }
Thread.sleep(forTimeInterval: seconds)
for item in cleanup { AudioDeviceStop(item.aggregate, item.proc) }
Thread.sleep(forTimeInterval: 0.2)

for recording in recordings {
    let url = outDir.appendingPathComponent("\(recording.name).f32")
    try Data(bytes: recording.samples, count: recording.frames * 8).write(to: url)
    print("\(recording.name): \(recording.frames) frames, \(recording.gaps) gaps -> \(url.path)")
}
for item in cleanup {
    if let proc = item.proc { AudioDeviceDestroyIOProcID(item.aggregate, proc) }
    AudioHardwareDestroyAggregateDevice(item.aggregate)
    AudioHardwareDestroyProcessTap(item.tap)
}
