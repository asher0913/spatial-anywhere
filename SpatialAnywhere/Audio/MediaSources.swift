import Foundation

/// One macOS app whose audio can be relayed.
///
/// Browsers and Electron apps play audio from helper processes, not from the
/// main app process, so a source also lists the helper bundle identifiers a
/// Core Audio tap has to follow.
struct MediaApp: Equatable, Hashable, Identifiable, Sendable {
    let bundleIdentifier: String
    let name: String
    let helperBundleIdentifiers: [String]

    init(_ bundleIdentifier: String, _ name: String, helpers: [String] = []) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.helperBundleIdentifiers = helpers
    }

    var id: String { bundleIdentifier }

    /// Bundle identifiers a tap should follow for this app, before any helper
    /// identifiers observed at runtime are added.
    var declaredTapBundleIdentifiers: [String] {
        [bundleIdentifier] + helperBundleIdentifiers
    }
}

enum MediaAppCatalog {
    /// Common Mac players that render audio with their own engines, so macOS
    /// does not offer them Spatialize Stereo. Bundle IDs come from each app's
    /// Info.plist as recorded in Homebrew cask uninstall data or app catalogs.
    /// Chromium, Electron and Gecko apps share the audio path measured for
    /// Chrome and Firefox; see the README for which apps were tested.
    static let presets: [MediaApp] = [
        // Music streaming
        MediaApp("com.spotify.client", "Spotify", helpers: ["com.spotify.client.helper"]),
        MediaApp("com.tidal.desktop", "TIDAL", helpers: ["com.tidal.desktop.helper"]),
        MediaApp("com.amazon.music", "Amazon Music", helpers: ["com.amazon.music-renderer"]),
        MediaApp("com.deezer.deezer-desktop", "Deezer"),
        MediaApp("com.qobuz.QobuzDesktop", "Qobuz"),
        MediaApp("com.pandora.desktop", "Pandora"),
        MediaApp("com.netease.163music", "NetEase Cloud Music"),
        MediaApp("com.tencent.QQMusicMac", "QQ Music"),
        MediaApp("tv.plex.plexamp", "Plexamp"),
        // Video and local-file players
        MediaApp("org.videolan.vlc", "VLC"),
        MediaApp("tv.plex.desktop", "Plex"),
        MediaApp("tv.plex.htpc", "Plex HTPC"),
        MediaApp("org.xbmc.kodi", "Kodi"),
        MediaApp("com.Eltima.ElmediaPlayer", "Elmedia Player"),
        MediaApp("com.movist.MovistPro", "Movist Pro"),
        MediaApp("com.stremio.Stremio", "Stremio", helpers: ["com.smartcodeltd.stremio"]),
        MediaApp("com.coppertino.Vox", "VOX", helpers: ["com.coppertino.Vox-Helper"]),
        MediaApp("com.swinsian.Swinsian", "Swinsian"),
        MediaApp("com.foobar2000.mac", "foobar2000"),
        MediaApp("com.bilibili.bilibiliPC", "Bilibili"),
        MediaApp("com.youku.mac", "Youku"),
        // Browsers (web players such as YouTube, YouTube Music and Netflix)
        MediaApp("com.google.Chrome", "Google Chrome", helpers: ["com.google.Chrome.helper"]),
        MediaApp("com.microsoft.edgemac", "Microsoft Edge", helpers: ["com.microsoft.edgemac.helper"]),
        MediaApp("com.brave.Browser", "Brave", helpers: ["com.brave.Browser.helper"]),
        MediaApp("company.thebrowser.Browser", "Arc", helpers: ["company.thebrowser.browser.helper"]),
        MediaApp("com.operasoftware.Opera", "Opera", helpers: ["com.operasoftware.Opera.helper"]),
        MediaApp("com.vivaldi.Vivaldi", "Vivaldi", helpers: ["com.vivaldi.Vivaldi.helper"]),
        MediaApp("org.mozilla.firefox", "Firefox", helpers: ["org.mozilla.plugincontainer"]),
        MediaApp("app.zen-browser.zen", "Zen", helpers: ["org.mozilla.plugincontainer"]),
    ]

    static let defaultSelection: [String] = ["com.spotify.client"]

    /// Apps that already hand macOS spatializable audio. Relaying them would
    /// spatialize the signal a second time, so they are never offered.
    /// Music, IINA and Petrichor were confirmed on a Mac: coreaudiod logs their
    /// streams as `Is Spatializable = 1`. WebKit browsers play media through
    /// Apple's WebKit, which already supports Spatial Audio.
    static let nativeSpatialBundleIdentifiers: Set<String> = [
        "com.apple.Music",
        "com.apple.TV",
        "com.apple.podcasts",
        "com.apple.QuickTimePlayerX",
        "com.apple.Safari",
        "com.kagi.kagimacOS",
        "com.colliderli.iina",
        "com.firecore.infuse",
        "org.Petrichor",
    ]

    /// Apps that play sound but are not media players, kept out of the list.
    static let nonMediaBundleIdentifiers: Set<String> = [
        "com.openai.chat",
        "com.openai.codex",
        "com.anthropic.claudefordesktop",
    ]

    static func preset(for bundleIdentifier: String) -> MediaApp? {
        presets.first { $0.bundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame }
    }

    static func isNativeSpatial(_ bundleIdentifier: String) -> Bool {
        nativeSpatialBundleIdentifiers.contains(bundleIdentifier)
    }

    /// Whether an app may appear in the source list at all.
    static func isOffered(_ bundleIdentifier: String) -> Bool {
        !isNativeSpatial(bundleIdentifier) &&
            !nonMediaBundleIdentifiers.contains(bundleIdentifier) &&
            bundleIdentifier != Bundle.main.bundleIdentifier
    }
}

enum AppBundlePath {
    /// The outermost `.app` bundle that contains `path`, so a helper such as
    /// `…/Google Chrome.app/…/Google Chrome Helper.app/Contents/MacOS/…`
    /// resolves to `…/Google Chrome.app`.
    static func outermostApplication(containing path: String) -> String? {
        var components: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            components.append(String(component))
            if component.lowercased().hasSuffix(".app") {
                let joined = components.joined(separator: "/")
                return joined.isEmpty ? nil : joined
            }
        }
        return nil
    }
}

enum MediaAppMatcher {
    /// Whether a Core Audio process belongs to `app`.
    ///
    /// - Parameters:
    ///   - processBundleIdentifier: the bundle ID Core Audio reports for the process.
    ///   - owningAppBundleIdentifier: the bundle ID of the outermost app bundle
    ///     that contains the process executable, when it could be resolved.
    static func owns(
        _ app: MediaApp,
        processBundleIdentifier: String,
        owningAppBundleIdentifier: String?
    ) -> Bool {
        let process = processBundleIdentifier.lowercased()
        let target = app.bundleIdentifier.lowercased()

        if let owner = owningAppBundleIdentifier?.lowercased(), !owner.isEmpty {
            return owner == target
        }
        guard !process.isEmpty else { return false }
        if process == target || process.hasPrefix(target + ".") { return true }
        return app.helperBundleIdentifiers.contains { helper in
            let helper = helper.lowercased()
            return process == helper || process.hasPrefix(helper + ".")
        }
    }
}

/// What a process tap should capture. On macOS 26 and later the tap follows
/// bundle identifiers, so helper processes that start later are captured too.
/// Earlier releases can only tap process objects that already exist.
struct TapTarget: Equatable, Sendable {
    var bundleIdentifiers: [String]
    var processObjectIDs: [UInt32]

    init(bundleIdentifiers: some Sequence<String>, processObjectIDs: some Sequence<UInt32>) {
        self.bundleIdentifiers = Array(Set(bundleIdentifiers)).sorted()
        self.processObjectIDs = Array(Set(processObjectIDs)).sorted()
    }

    /// True when `desired` would capture something this target does not, so
    /// the tap has to be rebuilt. Identifiers that disappear (a helper process
    /// that exited) do not require a rebuild.
    func needsRebuild(toCapture desired: TapTarget, followsBundleIdentifiers: Bool) -> Bool {
        if followsBundleIdentifiers {
            return !Set(desired.bundleIdentifiers).isSubset(of: bundleIdentifiers)
        }
        return !Set(desired.processObjectIDs).isSubset(of: processObjectIDs)
    }
}

enum TapPlanner {
    /// The tap target that captures every selected app: its declared bundle
    /// IDs plus the bundle IDs and process objects of helpers seen right now.
    static func target(for selection: [MediaApp], processes: [AudioProcessInfo]) -> TapTarget {
        var bundleIdentifiers = Set<String>()
        var objectIDs = Set<UInt32>()
        for app in selection {
            bundleIdentifiers.formUnion(app.declaredTapBundleIdentifiers)
            for process in ownedProcesses(of: app, in: processes) {
                if !process.bundleIdentifier.isEmpty { bundleIdentifiers.insert(process.bundleIdentifier) }
                objectIDs.insert(process.id)
            }
        }
        return TapTarget(bundleIdentifiers: bundleIdentifiers, processObjectIDs: objectIDs)
    }

    static func ownedProcesses(of app: MediaApp, in processes: [AudioProcessInfo]) -> [AudioProcessInfo] {
        processes.filter {
            MediaAppMatcher.owns(
                app,
                processBundleIdentifier: $0.bundleIdentifier,
                owningAppBundleIdentifier: $0.owningAppBundleIdentifier
            )
        }
    }
}

/// Persists which apps the user wants to relay.
struct SourceSelectionStore {
    static let key = "selectedSourceBundleIdentifiers"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [String] {
        guard let stored = defaults.array(forKey: Self.key) as? [String] else {
            return MediaAppCatalog.defaultSelection
        }
        return stored.filter(MediaAppCatalog.isOffered)
    }

    func save(_ bundleIdentifiers: [String]) {
        defaults.set(Array(Set(bundleIdentifiers)).sorted(), forKey: Self.key)
    }
}
