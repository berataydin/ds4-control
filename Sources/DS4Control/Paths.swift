import Foundation

/// UserDefaults key holding the user-chosen model-downloads folder (Settings ▸ Downloads).
/// An empty/absent value means the default App Support location.
let downloadsDirectoryDefaultsKey = "downloadsDirectoryPath"

/// Writable per-app support directory (`~/Library/Application Support/DS4 Control`),
/// created on demand. Holds the disk KV cache and — unless the user picks another folder
/// in Settings — the downloaded model (gguf) files: the app bundle's Resources are
/// read-only and code-signed, so multi-hundred-GB model data cannot live there.
func ds4AppSupportDir() -> URL {
    let base =
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    let dir = base.appendingPathComponent("DS4 Control", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Default model-downloads directory: `~/Library/Application Support/DS4 Control/gguf`.
func defaultGGUFDir() -> URL {
    ds4AppSupportDir().appendingPathComponent("gguf", isDirectory: true)
}

/// The user's chosen model-downloads folder, or nil when unset or not currently an
/// existing directory (e.g. an unmounted external drive — resolution then falls back
/// to `defaultGGUFDir()` rather than failing downloads into a dead path). Validated on
/// every call so mounting/unmounting a volume is picked up without an app restart.
func configuredDownloadsDir(defaults: UserDefaults = .standard) -> URL? {
    guard
        let raw = defaults.string(forKey: downloadsDirectoryDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
    else { return nil }
    let url = URL(fileURLWithPath: raw, isDirectory: true)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue
    else { return nil }
    return url
}

/// The bundled ds4 directory (`ds4-server` + `download_model.sh` + `metal/` shaders),
/// resolved automatically. `DS4_DIR` overrides it for development against a live checkout.
func bundledDS4Dir() -> URL {
    if let override = ProcessInfo.processInfo.environment["DS4_DIR"], !override.isEmpty {
        return URL(fileURLWithPath: override)
    }
    let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
    return resources.appendingPathComponent("ds4", isDirectory: true)
}

/// True when running unbundled (no packaged Info.plist — e.g. `swift run`). Gates
/// dev/test-only UI, like the wired-limit help shortcut in the popup footer.
func isDevBuild() -> Bool {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] == nil
}
