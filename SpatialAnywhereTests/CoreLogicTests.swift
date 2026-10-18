import CoreAudio
import CoreMedia
import XCTest
@testable import SpatialAnywhere

final class CoreLogicTests: XCTestCase {
    private let spotify = MediaAppCatalog.preset(for: "com.spotify.client")!
    private let chrome = MediaAppCatalog.preset(for: "com.google.Chrome")!
    private let firefox = MediaAppCatalog.preset(for: "org.mozilla.firefox")!

    func testOutermostApplicationResolvesHelpersToTheirApp() {
        XCTAssertEqual(
            AppBundlePath.outermostApplication(
                containing: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/141.0/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
            ),
            "/Applications/Google Chrome.app"
        )
        XCTAssertEqual(
            AppBundlePath.outermostApplication(
                containing: "/Applications/Firefox.app/Contents/MacOS/plugin-container.app/Contents/MacOS/plugin-container"
            ),
            "/Applications/Firefox.app"
        )
        XCTAssertEqual(
            AppBundlePath.outermostApplication(containing: "/Users/me/Applications/Spotify.app"),
            "/Users/me/Applications/Spotify.app"
        )
        XCTAssertNil(AppBundlePath.outermostApplication(containing: "/usr/sbin/coreaudiod"))
    }

    func testMatcherAcceptsAppsAndTheirHelpers() {
        XCTAssertTrue(MediaAppMatcher.owns(spotify, processBundleIdentifier: "com.spotify.client", owningAppBundleIdentifier: nil))
        XCTAssertTrue(MediaAppMatcher.owns(spotify, processBundleIdentifier: "com.spotify.client.helper.renderer", owningAppBundleIdentifier: nil))
        XCTAssertTrue(MediaAppMatcher.owns(chrome, processBundleIdentifier: "com.google.Chrome.helper", owningAppBundleIdentifier: nil))
        // Firefox's audio runs in plugin-container, whose bundle ID shares no prefix with Firefox.
        XCTAssertTrue(MediaAppMatcher.owns(firefox, processBundleIdentifier: "org.mozilla.plugincontainer", owningAppBundleIdentifier: nil))
    }

    func testMatcherPrefersTheResolvedOwningApp() {
        XCTAssertTrue(MediaAppMatcher.owns(firefox, processBundleIdentifier: "org.example.unrelated", owningAppBundleIdentifier: "org.mozilla.firefox"))
        // A process inside another app is not claimed just because its bundle ID looks similar.
        XCTAssertFalse(MediaAppMatcher.owns(chrome, processBundleIdentifier: "com.google.Chrome.helper", owningAppBundleIdentifier: "com.google.Chrome.canary"))
    }

    func testMatcherRejectsUnrelatedApps() {
        XCTAssertFalse(MediaAppMatcher.owns(spotify, processBundleIdentifier: "com.example.notspotify", owningAppBundleIdentifier: nil))
        XCTAssertFalse(MediaAppMatcher.owns(spotify, processBundleIdentifier: "com.spotify.clientx", owningAppBundleIdentifier: nil))
        XCTAssertFalse(MediaAppMatcher.owns(chrome, processBundleIdentifier: "", owningAppBundleIdentifier: nil))
    }

    func testNativeSpatialAppsAreNeverPresets() {
        let presetIDs = Set(MediaAppCatalog.presets.map(\.bundleIdentifier))
        XCTAssertTrue(presetIDs.isDisjoint(with: MediaAppCatalog.nativeSpatialBundleIdentifiers))
        XCTAssertTrue(MediaAppCatalog.isNativeSpatial("com.colliderli.iina"))
        XCTAssertFalse(MediaAppCatalog.isNativeSpatial("com.google.Chrome"))
    }

    func testTapPlannerCollectsSelectedAppsAndObservedHelpers() {
        let processes = [
            process(10, "com.google.Chrome", owner: "com.google.Chrome"),
            process(11, "com.google.Chrome.helper.audio", owner: "com.google.Chrome"),
            process(12, "com.spotify.client", owner: "com.spotify.client"),
            process(13, "org.mozilla.plugincontainer", owner: "org.mozilla.firefox"),
        ]
        let target = TapPlanner.target(for: [chrome, firefox], processes: processes)
        XCTAssertEqual(target.processObjectIDs, [10, 11, 13])
        XCTAssertTrue(target.bundleIdentifiers.contains("com.google.Chrome.helper.audio"))
        XCTAssertTrue(target.bundleIdentifiers.contains("org.mozilla.plugincontainer"))
        XCTAssertFalse(target.bundleIdentifiers.contains("com.spotify.client"))
    }

    func testTapTargetRebuildsOnlyForNewlyCapturedAudio() {
        let active = TapTarget(bundleIdentifiers: ["com.google.Chrome", "com.google.Chrome.helper"], processObjectIDs: [10, 11])
        let helperExited = TapTarget(bundleIdentifiers: ["com.google.Chrome"], processObjectIDs: [10])
        let newProcessSameBundle = TapTarget(bundleIdentifiers: ["com.google.Chrome", "com.google.Chrome.helper"], processObjectIDs: [10, 11, 12])
        let newHelperBundle = TapTarget(bundleIdentifiers: ["com.google.Chrome", "com.google.Chrome.helper", "com.google.Chrome.helper.audio"], processObjectIDs: [10, 11])

        XCTAssertFalse(active.needsRebuild(toCapture: helperExited, followsBundleIdentifiers: true))
        XCTAssertFalse(active.needsRebuild(toCapture: helperExited, followsBundleIdentifiers: false))
        // A bundle-ID tap picks up new processes of a known bundle by itself.
        XCTAssertFalse(active.needsRebuild(toCapture: newProcessSameBundle, followsBundleIdentifiers: true))
        XCTAssertTrue(active.needsRebuild(toCapture: newProcessSameBundle, followsBundleIdentifiers: false))
        XCTAssertTrue(active.needsRebuild(toCapture: newHelperBundle, followsBundleIdentifiers: true))
    }

    func testSelectionStoreDefaultsToSpotifyAndDropsNativeSpatialApps() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SpatialAnywhereTests.\(UUID().uuidString)"))
        let store = SourceSelectionStore(defaults: defaults)
        XCTAssertEqual(store.load(), ["com.spotify.client"])

        store.save(["org.mozilla.firefox", "com.google.Chrome", "com.google.Chrome", "com.apple.Music"])
        XCTAssertEqual(store.load(), ["com.google.Chrome", "org.mozilla.firefox"])

        store.save([])
        XCTAssertEqual(store.load(), [])
    }

    private func process(_ id: AudioObjectID, _ bundleID: String, owner: String?) -> AudioProcessInfo {
        AudioProcessInfo(
            id: id,
            pid: pid_t(id),
            bundleIdentifier: bundleID,
            owningAppBundleIdentifier: owner,
            owningAppName: nil,
            owningAppPath: nil,
            owningAppIsRegular: true,
            isRunningOutput: false
        )
    }

    func testAirPodsOutputDetectionIsCaseInsensitive() {
        let airPods = OutputDeviceInfo(
            id: 1,
            uid: "airpods",
            name: "TEST AIRPODS PRO",
            sampleRate: 48_000
        )
        let speakers = OutputDeviceInfo(
            id: 2,
            uid: "speakers",
            name: "MacBook Pro Speakers",
            sampleRate: 48_000
        )

        XCTAssertTrue(airPods.isLikelySpatialAudioHeadphones)
        XCTAssertFalse(speakers.isLikelySpatialAudioHeadphones)
    }

    func testOSStatusDescriptionShowsFourCharacterCode() {
        let status = OSStatus(bitPattern: 0x666D743F) // 'fmt?'
        XCTAssertEqual(CoreAudioFailure.describe(status), "'fmt?' / 1718449215")
        XCTAssertEqual(CoreAudioFailure.describe(-50), "-50")
    }

    func testRendererRecoveryRebasesAtLatestValidOutputTime() {
        let timescale: CMTimeScale = 48_000
        let currentTime = CMTime(value: 96_000, timescale: timescale)

        XCTAssertEqual(
            RendererRecoveryTimeline.restartFrame(
                currentTime: currentTime,
                suggestedFlushTime: CMTime(value: 72_000, timescale: timescale),
                timescale: timescale,
                fallbackFrame: 150_000
            ),
            96_000,
            "Flushed renderer timestamps must not force the live timeline backwards"
        )
        XCTAssertEqual(
            RendererRecoveryTimeline.restartFrame(
                currentTime: currentTime,
                suggestedFlushTime: CMTime(value: 120_000, timescale: timescale),
                timescale: timescale,
                fallbackFrame: 150_000
            ),
            120_000,
            "A later automatic-flush timestamp must remain eligible as the restart anchor"
        )
        XCTAssertEqual(
            RendererRecoveryTimeline.restartFrame(
                currentTime: .invalid,
                suggestedFlushTime: nil,
                timescale: timescale,
                fallbackFrame: 150_000
            ),
            150_000
        )
    }

    func testOutputReconfigurationGraceIncludesFiveSecondBoundary() {
        let start: UInt64 = 10_000
        XCTAssertTrue(
            OutputReconfigurationGrace.contains(
                startUptimeNanoseconds: start,
                nowUptimeNanoseconds: start + OutputReconfigurationGrace.durationNanoseconds
            )
        )
        XCTAssertFalse(
            OutputReconfigurationGrace.contains(
                startUptimeNanoseconds: start,
                nowUptimeNanoseconds: start + OutputReconfigurationGrace.durationNanoseconds + 1
            )
        )
    }

    func testCaptureRingPreservesStereoFramesAndConsumesPeak() throws {
        let bridge = SRAudioCaptureBridge()
        let input: [Float] = [0.25, -0.5, 0.75, -0.125, -0.2, 0.4]
        let data = input.withUnsafeBytes { Data($0) }

        bridge.debugEnqueueInterleavedFloat(data)

        XCTAssertEqual(bridge.availableFrameCount, 3)
        XCTAssertEqual(bridge.capturedFrameCount, 3)
        XCTAssertEqual(bridge.peakLevel, 0.75, accuracy: 0.0001)
        XCTAssertEqual(bridge.peakLevel, 0, accuracy: 0.0001)

        let firstChunk = try XCTUnwrap(bridge.dequeueChunk(withMaximumFrameCount: 2))
        XCTAssertEqual(firstChunk.frameCount, 2)
        XCTAssertEqual(floatArray(from: firstChunk.data), Array(input.prefix(4)))

        let secondChunk = try XCTUnwrap(bridge.dequeueChunk(withMaximumFrameCount: 8))
        XCTAssertEqual(secondChunk.frameCount, 1)
        XCTAssertEqual(floatArray(from: secondChunk.data), Array(input.suffix(2)))
        XCTAssertEqual(bridge.availableFrameCount, 0)
    }

    func testCaptureRingBoundsOverflowAndReportsDroppedFrames() {
        let bridge = SRAudioCaptureBridge()
        let capacity = 524_288
        let extraFrames = 17
        let input = [Float](repeating: 0.1, count: (capacity + extraFrames) * 2)

        bridge.debugEnqueueInterleavedFloat(input.withUnsafeBytes { Data($0) })

        XCTAssertEqual(bridge.availableFrameCount, UInt32(capacity))
        XCTAssertEqual(bridge.capturedFrameCount, UInt64(capacity))
        XCTAssertEqual(bridge.droppedFrameCount, UInt64(extraFrames))

        bridge.reset()
        XCTAssertEqual(bridge.availableFrameCount, 0)
        XCTAssertEqual(bridge.capturedFrameCount, 0)
        XCTAssertEqual(bridge.droppedFrameCount, 0)
    }

    func testCaptureRingPreservesOrderAcrossStorageWrap() throws {
        let bridge = SRAudioCaptureBridge()
        let capacity = 524_288
        let initialFrameCount = capacity - 2
        var initial = [Float]()
        initial.reserveCapacity(initialFrameCount * 2)
        for frame in 0..<initialFrameCount {
            initial.append(Float(frame))
            initial.append(-Float(frame))
        }
        bridge.debugEnqueueInterleavedFloat(initial.withUnsafeBytes { Data($0) })

        _ = try XCTUnwrap(
            bridge.dequeueChunk(withMaximumFrameCount: UInt32(initialFrameCount - 2))
        )

        let wrapped: [Float] = [
            1_000_001, -1_000_001,
            1_000_002, -1_000_002,
            1_000_003, -1_000_003,
            1_000_004, -1_000_004,
            1_000_005, -1_000_005,
            1_000_006, -1_000_006
        ]
        bridge.debugEnqueueInterleavedFloat(wrapped.withUnsafeBytes { Data($0) })

        let output = try XCTUnwrap(bridge.dequeueChunk(withMaximumFrameCount: 8))
        let expected = Array(initial.suffix(4)) + wrapped
        XCTAssertEqual(output.frameCount, 8)
        XCTAssertEqual(floatArray(from: output.data), expected)
    }

    func testApplicationBundleContainsStablePrivacyIdentity() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.asher0913.SpatialAnywhere")
        XCTAssertNotNil(Bundle.main.object(forInfoDictionaryKey: "NSAudioCaptureUsageDescription"))
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundlePackageType") as? String, "APPL")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String, "AppIcon")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool, true)
    }

    private func floatArray(from data: Data) -> [Float] {
        data.withUnsafeBytes { bytes in
            Array(bytes.bindMemory(to: Float.self))
        }
    }
}
