import AppKit
import AVFoundation
import PugglePhotosKit
import UniformTypeIdentifiers

/// The music under a slideshow: PugglePhotos' own tune, a song the person picked, or nothing. It fades in, dips
/// while a video plays its own sound, and fades out at the end.
final class SlideshowMusic {
    enum Choice: String, CaseIterable, Identifiable {
        case tune, song, none
        var id: String { rawValue }

        var title: String {
            switch self {
            case .tune: "PugglePhotos’ Tune"
            case .song: "A Song of Your Own"
            case .none: "No Music"
            }
        }
    }

    static var choice: Choice {
        Choice(rawValue: UserDefaults.standard.string(forKey: MemoryPreferences.musicKey) ?? "") ?? .tune
    }

    /// Debug runs on the sample library stay silent, unless `-PHAudio YES`.
    static var isSilenced: Bool {
        #if DEBUG
        return DebugLaunchOptions.usesSampleLibrary && !UserDefaults.standard.bool(forKey: "PHAudio")
        #else
        return false
        #endif
    }

    static let fullVolume: Float = 0.55
    private var player: AVAudioPlayer?
    private var accessedURL: URL?
    private(set) var isMuted = false
    private var isDucked = false
    private(set) var isPlaying = false

    /// Starts the chosen music, fading in. The built-in tune is made the first time it's needed.
    func start() {
        guard !Self.isSilenced else { return }
        switch Self.choice {
        case .none:
            return
        case .song:
            guard let url = Self.resolveSong() else { return }
            if url.startAccessingSecurityScopedResource() { accessedURL = url }
            begin(try? AVAudioPlayer(contentsOf: url))
        case .tune:
            Self.tune { [weak self] data in
                guard let self, let data else { return }
                begin(try? AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue))
            }
        }
    }

    private func begin(_ player: AVAudioPlayer?) {
        guard let player else { return }
        self.player = player
        player.numberOfLoops = -1
        player.volume = 0
        player.play()
        isPlaying = true
        applyVolume(fade: 2)
    }

    /// Quieter while a video plays its own sound.
    func duck(_ ducked: Bool) {
        isDucked = ducked
        applyVolume(fade: 0.6)
    }

    func toggleMute() {
        isMuted.toggle()
        applyVolume(fade: 0.4)
    }

    func pause() { player?.pause() }
    func resume() { if isPlaying { player?.play() } }

    /// Fades out and stops.
    func stop() {
        guard let player else { return }
        player.setVolume(0, fadeDuration: 1)
        let accessed = accessedURL
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            player.stop()
            accessed?.stopAccessingSecurityScopedResource()
        }
        self.player = nil
        accessedURL = nil
        isPlaying = false
    }

    private func applyVolume(fade: TimeInterval) {
        let volume: Float = isMuted ? 0 : (isDucked ? Self.fullVolume * 0.2 : Self.fullVolume)
        player?.setVolume(volume, fadeDuration: fade)
    }

    // MARK: The tune

    private static var tuneData: Data?
    private static var tuneWaiters: [(Data?) -> Void] = []

    /// The built-in tune as a WAV file in memory, made once off the main thread.
    static func tune(_ completion: @escaping (Data?) -> Void) {
        if let tuneData {
            completion(tuneData)
            return
        }
        tuneWaiters.append(completion)
        guard tuneWaiters.count == 1 else { return }
        Task {
            let data = await renderTune()
            tuneData = data
            let waiters = tuneWaiters
            tuneWaiters = []
            waiters.forEach { $0(data) }
        }
    }

    @concurrent private nonisolated static func renderTune() async -> Data {
        Soundtrack.wav(Soundtrack.render(sampleRate: 44_100), sampleRate: 44_100)
    }

    // MARK: A song of your own

    /// Asks for a song, and remembers it (with permission to open it again next time).
    static func chooseSong(completion: @escaping (Bool) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a song to play during slideshows."
        panel.prompt = "Choose"
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            else {
                completion(false)
                return
            }
            UserDefaults.standard.set(bookmark, forKey: MemoryPreferences.songBookmarkKey)
            UserDefaults.standard.set(url.deletingPathExtension().lastPathComponent, forKey: MemoryPreferences.songNameKey)
            UserDefaults.standard.set(Choice.song.rawValue, forKey: MemoryPreferences.musicKey)
            completion(true)
        }
    }

    static var songName: String? { UserDefaults.standard.string(forKey: MemoryPreferences.songNameKey) }

    private static func resolveSong() -> URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: MemoryPreferences.songBookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return nil }
        if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: MemoryPreferences.songBookmarkKey)
        }
        return url
    }
}
