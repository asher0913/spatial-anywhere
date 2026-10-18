import AppKit
import Combine
import Foundation

@MainActor
final class RelayViewModel: ObservableObject {
    enum CheckState {
        case ready
        case warning
        case unavailable
    }

    struct Message: Equatable {
        enum Kind {
            case info
            case warning
            case error
        }

        let kind: Kind
        let text: String
    }

    struct SourceRow: Identifiable, Equatable {
        enum Status {
            case playing
            case open
            case notRunning
        }

        let app: MediaApp
        let status: Status
        let isSelected: Bool
        let appPath: String?
        let isPreset: Bool

        var id: String { app.id }
    }

    @Published private(set) var sourceRows: [SourceRow] = []
    @Published private(set) var outputDetail = "Looking for the current output…"
    @Published private(set) var outputState: CheckState = .warning
    @Published private(set) var message: Message?
    @Published private(set) var isRelaying = false
    @Published private(set) var isBusy = false
    @Published private(set) var meterLevel: CGFloat = 0
    @Published private(set) var latencyLabel = "~80 ms prebuffer"

    private let coordinator = AudioRelayCoordinator()
    private let selectionStore = SourceSelectionStore()
    private let startupQueue = DispatchQueue(
        label: "com.asher0913.SpatialAnywhere.startup",
        qos: .userInitiated
    )
    private var discovery: RelayDiscovery?
    private var selectedBundleIdentifiers: [String]
    private var knownApps: [String: MediaApp] = [:]
    private var meterTimer: Timer?
    private var healthTick = 0
    private var startupOperationID: UUID?
    private var terminationCleanupIsRunning = false
    private var terminationCompletions: [() -> Void] = []
    private(set) var isReadyToTerminate = false

    init() {
        selectedBundleIdentifiers = selectionStore.load()
    }

    deinit {
        MainActor.assumeIsolated {
            meterTimer?.invalidate()
            coordinator.stop()
        }
    }

    var selectedApps: [MediaApp] {
        selectedBundleIdentifiers.map { id in
            knownApps[id] ?? MediaAppCatalog.preset(for: id) ?? MediaApp(id, Self.displayName(forBundleIdentifier: id))
        }
    }

    var canToggleRelay: Bool {
        if isRelaying { return !isBusy }
        guard !isBusy, discovery?.outputDevice != nil, !selectedBundleIdentifiers.isEmpty else { return false }
        if AudioHardwareClient.tapsFollowBundleIdentifiers { return true }
        return sourceRows.contains { $0.isSelected && $0.status != .notRunning }
    }

    var relayingSummary: String {
        let names = sourceRows.filter(\.isSelected).map(\.app.name)
        return names.isEmpty ? "Relaying" : "Relaying " + names.joined(separator: ", ")
    }

    var menuBarSymbolName: String {
        if isBusy { return "ellipsis.circle" }
        if isRelaying { return "waveform.circle.fill" }
        if message?.kind == .error { return "exclamationmark.triangle.fill" }
        return "waveform.circle"
    }

    var menuBarStatusText: String {
        if isBusy { return "Spatial Anywhere is changing audio state" }
        if isRelaying { return "Spatial Anywhere is active" }
        if message?.kind == .error { return "Spatial Anywhere needs attention" }
        return "Spatial Anywhere is stopped"
    }

    func refresh() {
        // Reopening the menu-bar window calls this view's onAppear again. Do not
        // make the main actor wait on Core Audio while a permission prompt or
        // pipeline startup is already running on the coordinator queue.
        guard !isBusy else { return }

        do {
            let discovery = try coordinator.discover()
            self.discovery = discovery
            // Keep an error visible after the panel is reopened; clear only hints.
            if !isRelaying, message?.kind != .error { message = nil }
            apply(discovery)
        } catch {
            discovery = nil
            outputDetail = "Unable to inspect the current output"
            outputState = .unavailable
            message = Message(kind: .error, text: error.localizedDescription)
        }
    }

    func setSource(_ app: MediaApp, selected: Bool) {
        guard !MediaAppCatalog.isNativeSpatial(app.bundleIdentifier) else { return }
        knownApps[app.bundleIdentifier] = app
        var ids = selectedBundleIdentifiers.filter { $0 != app.bundleIdentifier }
        if selected { ids.append(app.bundleIdentifier) }
        selectedBundleIdentifiers = ids
        selectionStore.save(ids)
        if let discovery { apply(discovery) }

        guard isRelaying else { return }
        if ids.isEmpty {
            stopRelay()
            return
        }
        // Rebuilding the tap waits on Core Audio; keep it off the main actor.
        isBusy = true
        let coordinator = coordinator
        let selection = selectedApps
        startupQueue.async { [weak self] in
            let failure = coordinator.updateSelection(selection)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isBusy = false
                    if let failure {
                        self.handlePipelineFailure(failure)
                    } else {
                        self.message = Message(kind: .info, text: "\(self.relayingSummary). Spatial Audio is controlled in the macOS Sound menu.")
                    }
                }
            }
        }
    }

    func toggleRelay() {
        if isRelaying {
            stopRelay()
        } else {
            startRelay()
        }
    }

    func prepareForTermination(completion: @escaping () -> Void) {
        if isReadyToTerminate {
            completion()
            return
        }

        terminationCompletions.append(completion)
        guard !terminationCleanupIsRunning else { return }
        terminationCleanupIsRunning = true

        startupOperationID = nil
        meterTimer?.invalidate()
        meterTimer = nil
        isRelaying = false
        isBusy = true
        meterLevel = 0

        // The serial startup queue gives cleanup strict ordering after a tap
        // creation that may still be waiting for the privacy prompt. AppKit's
        // terminate-later reply keeps the process alive, while leaving the main
        // actor and menu responsive until the tapped apps have been unmuted.
        let coordinator = coordinator
        startupQueue.async { [weak self] in
            _ = coordinator.stop()
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isBusy = false
                    self.isReadyToTerminate = true
                    self.terminationCleanupIsRunning = false
                    let completions = self.terminationCompletions
                    self.terminationCompletions.removeAll()
                    completions.forEach { $0() }
                }
            }
        }
    }

    func quitApplication() {
        NSApplication.shared.terminate(nil)
    }

    private func startRelay() {
        isBusy = true
        message = nil
        let operationID = UUID()
        startupOperationID = operationID
        let coordinator = coordinator
        let selection = selectedApps

        // Tap creation can wait for Core Audio or a privacy prompt. Keep it off
        // the main actor so the window and progress indicator stay responsive.
        startupQueue.async { [weak self] in
            let result: Result<RelayDiscovery, Error>
            do {
                let discovery = try coordinator.start(selection: selection) { [weak self] error in
                    Task { @MainActor in
                        self?.handlePipelineFailure(error)
                    }
                }
                result = .success(discovery)
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.completeStart(result, operationID: operationID)
                }
            }
        }
    }

    private func completeStart(
        _ result: Result<RelayDiscovery, Error>,
        operationID: UUID
    ) {
        guard startupOperationID == operationID else { return }
        startupOperationID = nil
        isBusy = false

        switch result {
        case .success(let discovery):
            self.discovery = discovery
            isRelaying = true
            apply(discovery)
            if let output = discovery.outputDevice, !output.isLikelySpatialAudioHeadphones {
                message = Message(
                    kind: .warning,
                    text: "Relay active, but \(output.name) does not look like Spatial Audio-capable AirPods. Choose your AirPods as the Mac's output, then restart the relay."
                )
            } else {
                message = Message(
                    kind: .info,
                    text: "\(relayingSummary). Spatial Audio is now controlled for Spatial Anywhere in the macOS Sound menu."
                )
            }
            startMetering()
        case .failure(let error):
            let cleanupFailure = coordinator.stop()
            isRelaying = false
            message = Message(
                kind: .error,
                text: startFailureMessage(cleanupFailure ?? error)
            )
        }
    }

    private func stopRelay() {
        startupOperationID = nil
        isBusy = true
        meterTimer?.invalidate()
        meterTimer = nil
        let cleanupFailure = coordinator.stop()
        isRelaying = false
        meterLevel = 0
        isBusy = false
        message = cleanupFailure.map {
            Message(kind: .error, text: $0.localizedDescription)
        } ?? Message(kind: .info, text: "Relay stopped. The apps play directly again.")
        refreshRowsPreservingMessage()
    }

    private func handlePipelineFailure(_ error: Error) {
        startupOperationID = nil
        meterTimer?.invalidate()
        meterTimer = nil
        isRelaying = false
        isBusy = false
        meterLevel = 0
        message = Message(kind: .error, text: error.localizedDescription)
        refreshRowsPreservingMessage()
    }

    private func startMetering() {
        meterTimer?.invalidate()
        healthTick = 0
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRelaying else { return }

                let metrics = self.coordinator.metrics()
                let shapedPeak = CGFloat(pow(max(0, min(1, metrics.peakLevel)), 0.45))
                self.meterLevel = max(shapedPeak, self.meterLevel * 0.72)
                self.latencyLabel = metrics.droppedFrameCount == 0
                    ? "~80 ms prebuffer"
                    : "\(metrics.droppedFrameCount) frames dropped"

                self.healthTick += 1
                if self.healthTick >= 8, !self.isBusy {
                    self.healthTick = 0
                    if let failure = self.coordinator.healthFailure() {
                        let cleanupFailure = self.coordinator.stop()
                        self.handlePipelineFailure(cleanupFailure ?? failure)
                    } else {
                        self.refreshRowsPreservingMessage()
                    }
                }
            }
        }
    }

    private func apply(_ discovery: RelayDiscovery) {
        sourceRows = Self.rows(
            processes: discovery.processes,
            selected: selectedBundleIdentifiers,
            knownApps: &knownApps
        )

        if let output = discovery.outputDevice {
            outputDetail = "\(output.name) · \(Int(output.sampleRate.rounded())) Hz"
            outputState = output.isLikelySpatialAudioHeadphones ? .ready : .warning
        } else {
            outputDetail = "No default output device"
            outputState = .unavailable
        }

        guard message == nil || message?.kind != .error else { return }

        #if !arch(arm64)
        message = Message(kind: .error, text: RelayError.unsupportedMac.localizedDescription)
        #else
        if isRelaying { return }
        if selectedBundleIdentifiers.isEmpty {
            message = Message(kind: .warning, text: "Choose the apps whose audio should get Spatial Audio.")
        } else if let output = discovery.outputDevice, !output.isLikelySpatialAudioHeadphones {
            message = Message(kind: .warning, text: "The current output does not look like Spatial Audio-capable AirPods. Connect AirPods before starting the relay.")
        } else if !canToggleRelay {
            message = Message(kind: .warning, text: "Before macOS 26, apps only appear in Core Audio after they open an audio stream. Start playback, then click Refresh.")
        } else {
            message = nil
        }
        #endif
    }

    /// Rows for every preset that is installed or running, every other app
    /// that is playing right now, and every selected app.
    private static func rows(
        processes: [AudioProcessInfo],
        selected: [String],
        knownApps: inout [String: MediaApp]
    ) -> [SourceRow] {
        var appsWithAudio: [String: (name: String, path: String?, playing: Bool)] = [:]
        for process in processes where process.owningAppIsRegular {
            guard let owner = process.owningAppBundleIdentifier, !owner.isEmpty else { continue }
            let entry = appsWithAudio[owner]
            appsWithAudio[owner] = (
                name: process.owningAppName ?? entry?.name ?? owner,
                path: process.owningAppPath ?? entry?.path,
                playing: (entry?.playing ?? false) || process.isRunningOutput
            )
        }

        func status(of app: MediaApp) -> SourceRow.Status {
            let owned = TapPlanner.ownedProcesses(of: app, in: processes)
            if owned.contains(where: \.isRunningOutput) { return .playing }
            let isRunning = !owned.isEmpty || !NSRunningApplication
                .runningApplications(withBundleIdentifier: app.bundleIdentifier).isEmpty
            return isRunning ? .open : .notRunning
        }

        var rows: [SourceRow] = []
        var seen = Set<String>()

        for preset in MediaAppCatalog.presets {
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: preset.bundleIdentifier)
            let isSelected = selected.contains(preset.bundleIdentifier)
            guard url != nil || appsWithAudio[preset.bundleIdentifier] != nil || isSelected else { continue }
            knownApps[preset.bundleIdentifier] = preset
            rows.append(SourceRow(app: preset, status: status(of: preset), isSelected: isSelected, appPath: url?.path, isPreset: true))
            seen.insert(preset.bundleIdentifier)
        }

        // Apps outside the presets show up only while they play or when
        // selected; many apps keep an idle Core Audio connection open.
        let playingOthers = appsWithAudio.filter(\.value.playing).map(\.key)
        let others = Set(playingOthers).union(selected)
            .subtracting(seen)
            .filter { !MediaAppCatalog.isNativeSpatial($0) && $0 != Bundle.main.bundleIdentifier }
        var otherRows: [SourceRow] = []
        for id in others {
            let info = appsWithAudio[id]
            let app = knownApps[id] ?? MediaApp(id, info?.name ?? displayName(forBundleIdentifier: id))
            knownApps[id] = app
            let path = info?.path ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?.path
            otherRows.append(SourceRow(app: app, status: status(of: app), isSelected: selected.contains(id), appPath: path, isPreset: false))
        }
        rows += otherRows.sorted { $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }
        return rows
    }

    private static func displayName(forBundleIdentifier id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private func refreshRowsPreservingMessage() {
        let savedMessage = message
        do {
            let discovery = try coordinator.discover()
            self.discovery = discovery
            apply(discovery)
        } catch {
            discovery = nil
            outputDetail = "Unable to inspect the current output"
            outputState = .unavailable
        }
        message = savedMessage
    }

    private func startFailureMessage(_ error: Error) -> String {
        let description = error.localizedDescription
        if description.localizedCaseInsensitiveContains("permission") ||
            description.localizedCaseInsensitiveContains("denied") ||
            description.localizedCaseInsensitiveContains("operation not permitted") ||
            description.localizedCaseInsensitiveContains("'perm'") ||
            description.contains("560492391") ||
            description.localizedCaseInsensitiveContains("!hog") {
            return "\(description) Allow Spatial Anywhere in System Settings → Privacy & Security → Screen & System Audio Recording, then relaunch it."
        }
        return description
    }
}
