import Foundation

/// Merlin SDN/sdn.js Get_VPNC_Profile maps WireGuard to unit and OpenVPN to unit + 5.
public enum SDNClientRoute: Equatable, Sendable {
    case direct, wireGuard(Int), openVPN(Int)
    public init?(_ value: String) {
        guard let n = Int(value), String(n) == value else { return nil }
        switch n { case 0: self = .direct; case 1...5: self = .wireGuard(n); case 6...10: self = .openVPN(n - 5); default: return nil }
    }
    public var title: String {
        switch self { case .direct: "默认互联网"; case .wireGuard(let n): "WireGuard · 槽位 \(n)"; case .openVPN(let n): "OpenVPN · 槽位 \(n)" }
    }
}
