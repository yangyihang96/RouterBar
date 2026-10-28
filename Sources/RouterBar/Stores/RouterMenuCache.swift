import Foundation
import RouterCore

/// The last router's own web menu and profile, so the next launch shows that router's menus before it has
/// reconnected. Only menu structure, names, model, capabilities and the management address it was read from (the
/// one the app connects to anyway): no settings values. It is shown only for that address, and only until this
/// session has read the router again; nothing is written on its strength (RouterStore.writeScope).
struct RouterMenuCache: Codable {
    var entries: [RouterMenuEntry]
    var profile: RouterProfile
    /// The connection address it was read from; a cache from before 2.0.0 build 37 has none and is not used.
    var endpoint: String?
    var savedAt = Date()

    private static let key = "routerMenuCache"

    static func load() -> RouterMenuCache? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(RouterMenuCache.self, from: data)
    }
    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
