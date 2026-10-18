import Foundation

enum RelayError: LocalizedError {
    case unsupportedMac
    case noSourceSelected
    case sourcesNotRunning(String)
    case noOutputDevice
    case unsupportedTapFormat(String)
    case rendererFailed(String)
    case captureFailed(String)
    case cleanupFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedMac:
            "Spatial Audio on Mac requires Apple silicon."
        case .noSourceSelected:
            "Choose at least one app to relay."
        case .sourcesNotRunning(let names):
            "\(names) is not connected to the Mac audio system yet. Start playback in it, then try again."
        case .noOutputDevice:
            "macOS has no default audio output device."
        case .unsupportedTapFormat(let detail):
            "The selected apps produced an audio format this relay cannot handle (\(detail))."
        case .rendererFailed(let detail):
            "The spatial audio renderer stopped (\(detail)). The apps' direct output has been restored."
        case .captureFailed(let detail):
            "Audio capture failed (\(detail))."
        case .cleanupFailed(let detail):
            "Spatial Anywhere could not fully release the audio tap (\(detail)). It attempted to restore the apps' direct output; quit the app before retrying."
        }
    }
}
