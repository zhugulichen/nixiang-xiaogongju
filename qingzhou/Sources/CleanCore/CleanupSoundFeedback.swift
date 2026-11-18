import Foundation
import AudioToolbox

public enum CleanupSoundFeedback {
    @MainActor private static var gate = CleanupSoundFeedbackGate()

    public static func shouldPlay(batch: TrashBatch, method: TrashMoveMethod, enabled: Bool) -> Bool {
        guard enabled, method != .finderInteractive else { return false }
        let moved = batch.entries.filter { $0.trashURL != nil && $0.error == nil && !$0.restored }
        return !moved.isEmpty && !moved.contains { $0.recycledByFinder == true }
    }

    /// Returns whether a playback request was submitted, not whether sound was audible.
    @MainActor @discardableResult
    public static func play(for batch: TrashBatch, method: TrashMoveMethod, enabled: Bool) -> Bool {
        gate.submit(batch: batch, method: method, enabled: enabled, request: requestSystemPlayback)
    }

    /// Only use in response to an explicit user request to preview the sound.
    @MainActor @discardableResult
    public static func preview() -> Bool { requestSystemPlayback() }

    @MainActor private static func requestSystemPlayback() -> Bool {
        let url = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/finder/move to trash.aif")
        var sound: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &sound) == noErr else { return false }

        // Respect the user's system sound-effects preference rather than reading private defaults.
        var isUISound: UInt32 = 1
        guard AudioServicesSetProperty(kAudioServicesPropertyIsUISound,
                                      UInt32(MemoryLayout<SystemSoundID>.size), &sound,
                                      UInt32(MemoryLayout<UInt32>.size), &isUISound) == noErr else {
            AudioServicesDisposeSystemSoundID(sound)
            return false
        }
        let identifier = sound
        AudioServicesPlaySystemSoundWithCompletion(identifier) {
            AudioServicesDisposeSystemSoundID(identifier)
        }
        return true
    }
}

struct CleanupSoundFeedbackGate {
    // A batch may be reported repeatedly; retain successful submissions for this process lifetime.
    private var submitted = Set<UUID>()

    mutating func submit(batch: TrashBatch, method: TrashMoveMethod, enabled: Bool, request: () -> Bool) -> Bool {
        guard CleanupSoundFeedback.shouldPlay(batch: batch, method: method, enabled: enabled),
              !submitted.contains(batch.id), request() else { return false }
        submitted.insert(batch.id)
        return true
    }
}
