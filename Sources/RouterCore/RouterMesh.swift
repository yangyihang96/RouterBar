import Foundation

public struct MeshNode: Sendable, Identifiable, Equatable {
    public let mac: String
    public let name: String
    public let model: String
    public let ip: String
    public let firmware: String
    public let online: Bool
    public let primary: Bool
    public let alias: String
    public var id: String { mac }
}
public enum MeshAction: String, Sendable { case reboot, remove, optimize }
extension RouterClient {
    public func meshNodes() async throws -> [MeshNode] {
        let data = try await request("appGet.cgi", query: [.init(name: "hook", value: "get_cfg_clientlist()")])
        let object = try RouterParser.json(data)
        guard let entries = object["get_cfg_clientlist"] as? [[String: Any]] else { throw RouterError.invalidResponse("AiMesh 节点") }
        return entries.enumerated().compactMap { index, item in
            guard let mac = RouterParser.string(item["mac"]), mac.range(of: #"^(?:[A-Fa-f0-9]{2}:){5}[A-Fa-f0-9]{2}$"#, options: .regularExpression) != nil else { return nil }
            let config = item["config"] as? [String: Any] ?? [:]
            let misc = config["misc"] as? [String: Any] ?? [:]
            let alias = RouterParser.string(misc["cfg_alias"]) ?? RouterParser.string(item["alias"]) ?? ""
            let model = RouterParser.string(item["model_name"]) ?? RouterParser.string(item["productid"]) ?? "ASUS"
            return MeshNode(mac: mac.uppercased(), name: alias.isEmpty ? model : alias, model: model, ip: RouterParser.string(item["ip"]) ?? "", firmware: RouterParser.string(item["fwver"]) ?? "", online: RouterParser.string(item["online"]) == "1" || index == 0, primary: index == 0, alias: alias)
        }
    }
    public func setMeshAlias(mac: String, alias: String) async throws -> Bool {
        try acquireMutation(); defer { releaseMutation() }
        guard (1...32).contains(alias.utf8.count), !alias.containsLineBreak else { throw RouterError.validation("节点名称需为 1–32 字节") }
        guard let node = try await meshNodes().first(where: { $0.mac == mac }) else { throw RouterError.validation("节点已变化，请重新读取") }
        if node.primary { _ = try await submitApply(["action_mode":"apply", "cfg_alias":alias]) }
        else {
            let config = String(decoding: try JSONSerialization.data(withJSONObject: ["cfg_alias":alias]), as: UTF8.self)
            _ = try await sendNativeAction(["action_mode":"config_changed", "re_mac":mac, "config":config])
        }
        try await Task.sleep(for: .seconds(3))
        return try await meshNodes().first(where: { $0.mac == mac })?.alias == alias
    }
    public func meshAction(_ action: MeshAction, mac: String) async throws {
        try acquireMutation(); defer { releaseMutation() }
        guard let node = try await meshNodes().first(where: { $0.mac == mac }), !node.primary else { throw RouterError.validation("请在备份与维护中操作主路由器") }
        let fields: [String: String]
        switch action {
        case .reboot: fields = ["action_mode":"device_reboot", "device_list":mac]
        case .remove: fields = ["action_mode":"reset_default", "slave_mac":mac]
        case .optimize: fields = ["action_mode":"re_reconnect", "device_list":mac]
        }
        _ = try await sendNativeAction(fields)
    }
    func sendNativeAction(_ fields: [String: String]) async throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        guard let encoded = String(decoding: data, as: UTF8.self).addingPercentEncoding(withAllowedCharacters: allowed)?.data(using: .utf8) else { throw RouterError.invalidResponse("请求编码") }
        return try await request("applyapp.cgi", method: "POST", body: encoded, contentType: "application/x-www-form-urlencoded", timeout: 180)
    }
}
