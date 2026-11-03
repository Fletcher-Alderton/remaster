import Foundation

/// Parametric EQ profiles shipped inside the app bundle, so a personal correction does
/// not have to be AirDropped to the device and pasted in by hand.
///
/// Any `.txt` file in the bundle's `EQ/` directory becomes a profile. Its filename, minus
/// the extension, is the profile name: `EQ/Headphones.txt` appears in Settings as
/// "Headphones". Dropping another file into that directory is the only step needed to
/// ship another profile.
enum BundledEQProfiles {
    struct Item: Equatable {
        let name: String
        let text: String
    }

    static let directory = "EQ"

    /// Reads every bundled profile. Unreadable or non-UTF-8 files are skipped rather than
    /// failing the launch, and the result is sorted so import order is stable.
    static func load(from bundle: Bundle = .main, directory: String = BundledEQProfiles.directory) -> [Item] {
        let urls = bundle.urls(forResourcesWithExtension: "txt", subdirectory: directory) ?? []
        return urls.compactMap { url -> Item? in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return Item(name: url.deletingPathExtension().lastPathComponent, text: text)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
