import CoreAudio
import Foundation

/// The built-in speakers as their own CoreAudio device (Apple Silicon; no root needed).
/// Muting the device, not "the current output", leaves AirPods / headphones / displays alone and
/// still covers audio falling back to the speakers when one of those disconnects.
enum Speaker {
    static let uid = "BuiltInSpeakerDevice"

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private static var mute = address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)

    /// Looked up on every call: the id changes if coreaudiod restarts.
    static func device() -> AudioDeviceID? {
        var a = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var uid = Speaker.uid as CFString
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = withUnsafePointer(to: &uid) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a,
                                       UInt32(MemoryLayout<CFString>.size), $0, &size, &id)
        }
        return err == noErr && id != kAudioObjectUnknown ? id : nil
    }

    /// nil = could not read it.
    static func muted() -> Bool? {
        guard let id = device() else { return nil }
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &mute, 0, nil, &size, &v) == noErr ? v != 0 : nil
    }

    /// Sets it, then reads it back. Volume level is never touched.
    @discardableResult
    static func setMuted(_ on: Bool) -> Bool {
        guard let id = device() else { return false }
        var v: UInt32 = on ? 1 : 0
        return AudioObjectSetPropertyData(id, &mute, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v) == noErr
            && muted() == on
    }

    /// Event from CoreAudio whenever anything (volume keys, an app, a script) changes the mute. No polling.
    static func onMuteChange(_ handler: @escaping () -> Void) {
        guard let id = device() else { return }
        AudioObjectAddPropertyListenerBlock(id, &mute, .main) { _, _ in handler() }
    }
}
