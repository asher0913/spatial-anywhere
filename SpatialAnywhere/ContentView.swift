import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: RelayViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            sourcesCard
            outputCard

            if let message = viewModel.message {
                messageCard(message)
            }

            if viewModel.isRelaying {
                meter
                spatialAudioHint
            } else {
                privacyHint
            }

            Spacer(minLength: 0)
            controls
        }
        .padding(28)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { viewModel.refresh() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "airpodspro")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(
                    LinearGradient(
                        colors: [Color(red: 1.0, green: 0.55, blue: 0.32), Color(red: 0.90, green: 0.26, blue: 0.56), Color(red: 0.40, green: 0.26, blue: 0.86)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text("Spatial Anywhere")
                    .font(.title.bold())
                Text("AirPods Spatial Audio for Spotify, Chrome, Firefox and more")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sourcesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Relay these apps")
                .font(.headline)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.sourceRows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            Divider().padding(.leading, 44)
                        }
                        sourceRow(row)
                    }
                    if viewModel.sourceRows.isEmpty {
                        Text("No supported players found. Start playback in an app, then click Refresh.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 60)
                    }
                }
                .padding(.horizontal, 14)
            }
            .frame(height: 236)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            }

            Text("Apps with built-in Spatial Audio (Music, TV, Safari, IINA, Infuse, Petrichor) are not listed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func sourceRow(_ row: RelayViewModel.SourceRow) -> some View {
        Toggle(isOn: Binding(
            get: { row.isSelected },
            set: { viewModel.setSource(row.app, selected: $0) }
        )) {
            HStack(spacing: 10) {
                appIcon(path: row.appPath)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.app.name).font(.body)
                    Text(row.status.label)
                        .font(.caption)
                        .foregroundStyle(row.status == .playing ? Color.green : Color.secondary)
                }
                Spacer()
            }
        }
        .toggleStyle(.checkbox)
        .disabled(viewModel.isBusy)
        .frame(minHeight: 44)
    }

    @ViewBuilder
    private func appIcon(path: String?) -> some View {
        if let path {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .frame(width: 26, height: 26)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
        }
    }

    private var outputCard: some View {
        routeRow(
            icon: "speaker.wave.2.fill",
            title: "Output",
            detail: viewModel.outputDetail,
            state: viewModel.outputState
        )
        .padding(.horizontal, 16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        }
    }

    private func routeRow(icon: String, title: String, detail: String, state: RelayViewModel.CheckState) -> some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: state.symbolName)
                .foregroundStyle(state.color)
                .font(.system(size: 16, weight: .semibold))
        }
        .frame(minHeight: 62)
    }

    private func messageCard(_ message: RelayViewModel.Message) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: message.kind.symbolName)
                .foregroundStyle(message.kind.color)
                .padding(.top, 1)
            Text(message.text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(13)
        .background(message.kind.color.opacity(0.09), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private var meter: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(viewModel.relayingSummary, systemImage: "waveform")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(viewModel.latencyLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.green, .mint, .cyan],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(4, proxy.size.width * viewModel.meterLevel))
                        .animation(.linear(duration: 0.12), value: viewModel.meterLevel)
                }
            }
            .frame(height: 8)
        }
    }

    private var spatialAudioHint: some View {
        Label {
            Text("Open the Sound or AirPods menu and choose **Fixed** or **Head Tracked** under Spatial Audio.")
        } icon: {
            Image(systemName: "gyroscope")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private var privacyHint: some View {
        Label {
            Text("The first start asks for System Audio Recording access. Audio stays in memory and is never saved.")
        } icon: {
            Image(systemName: "hand.raised.fill")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                viewModel.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(viewModel.isBusy)

            Menu {
                Button("Quit Spatial Anywhere", systemImage: "power") {
                    viewModel.quitApplication()
                }
                .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            Button {
                viewModel.toggleRelay()
            } label: {
                if viewModel.isBusy {
                    ProgressView().controlSize(.small)
                        .frame(minWidth: 92)
                } else {
                    Text(viewModel.isRelaying ? "Stop relay" : "Start relay")
                        .frame(minWidth: 92)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(viewModel.isRelaying ? .red : .accentColor)
            .disabled(!viewModel.canToggleRelay)
            .keyboardShortcut(.return, modifiers: [])
        }
    }
}

private extension RelayViewModel.SourceRow.Status {
    var label: String {
        switch self {
        case .playing: "Playing"
        case .open: "Open"
        case .notRunning: "Not running"
        }
    }
}

private extension RelayViewModel.CheckState {
    var symbolName: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .unavailable: "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .ready: .green
        case .warning: .orange
        case .unavailable: .red
        }
    }
}

private extension RelayViewModel.Message.Kind {
    var symbolName: String {
        switch self {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .info: .blue
        case .warning: .orange
        case .error: .red
        }
    }
}
