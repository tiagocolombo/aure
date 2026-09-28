import Foundation

public enum AureVersion {
    /// Version in source; release builds stamp the real one into Info.plist
    /// (scripts/next-version.sh picks it from the commits since the last tag).
    public static let source = "0.1.0"

    public static var string: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? source
    }
}
