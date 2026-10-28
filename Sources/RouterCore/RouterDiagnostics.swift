import Foundation

extension RouterClient {
    /// Starts ping, traceroute, nslookup or netstat on the router: an action, so it passes the write checks. netool()
    /// reads the same parameters on every line from 384 to 3006 (`.identified`).
    public func startDiagnostic(method: String, host: String, version: String) async throws -> String {
        try acquireMutation(.identified); defer { releaseMutation() }
        guard ["3", "4", "5", "6", "7"].contains(method), ["v4", "v6"].contains(version) else { throw RouterError.validation("请选择支持的网络工具") }
        if !["6", "7"].contains(method) {
            guard host.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,252}$"#, options: .regularExpression) != nil else { throw RouterError.validation("请输入有效的 IP 地址或域名") }
        }
        let fields = ["type": method, "target": host, "pcnt": "5", "ver": method == "5" ? "" : version, "netst": "0x0001"]
        let data = try await request("netool.cgi", query: fields.map { .init(name: $0.key, value: $0.value) }, changes: true)
        let json = try RouterParser.json(data)
        guard let job = RouterParser.string(json["successful"]), job != "0", job.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil else { throw RouterError.invalidResponse("诊断任务") }
        return job
    }
    public func diagnosticResult(job: String) async throws -> (text: String, complete: Bool) {
        guard job.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil, !job.contains("..") else { throw RouterError.invalidResponse("诊断任务") }
        let data = try await request("netool.cgi", query: [.init(name: "type", value: "0"), .init(name: "target", value: job)])
        let text = String(decoding: data, as: UTF8.self)
        return (text.replacingOccurrences(of: "XU6J03M6", with: ""), text.contains("XU6J03M6"))
    }
}
