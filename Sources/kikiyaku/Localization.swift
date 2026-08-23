import Foundation

/// Resource bundle for localized strings.
///
/// SwiftPM's generated Bundle.module is deliberately avoided. For executable
/// targets the generated accessor only looks directly under Bundle.main.bundleURL
/// and at an absolute .build path on the build machine, so distributing the .app
/// (with the bundle placed in Contents/Resources) to another Mac fails to resolve
/// and crashes with fatalError. Instead, resolve it ourselves: Contents/Resources
/// (distributed .app) first, then next to the bare executable (running from .build
/// during development), and fall back to .main without crashing when neither
/// exists (keys are shown as-is, which is survivable).
private let resourceBundle: Bundle = {
    let bundleName = "kikiyaku_kikiyaku.bundle"
    let candidates: [URL?] = [
        Bundle.main.resourceURL,   // kikiyaku.app/Contents/Resources (placed by build.sh)
        Bundle.main.bundleURL,     // next to the bare executable (inside .build during development)
    ]
    for base in candidates {
        if let base, let bundle = Bundle(url: base.appendingPathComponent(bundleName)) {
            return bundle
        }
    }
    return .main
}()

/// The localization the resource bundle actually selected ("ja" / "en").
/// Display locales must follow this — not Locale.current. When the macOS preferred
/// language is one the app does not support (e.g. French), UI strings fall back to
/// a supported language while Locale.current stays French, so language names would
/// appear in a different language than the rest of the UI.
let resolvedUILanguage: String = resourceBundle.preferredLocalizations.first ?? "en"

/// Fetches a localized string from Localizable.strings.
func L(_ key: String) -> String {
    NSLocalizedString(key, bundle: resourceBundle, comment: "")
}

/// Localized string with format arguments.
func LF(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), arguments: args)
}
