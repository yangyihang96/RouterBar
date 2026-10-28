import Foundation

extension RouterProfile {
    /// The router the native pages were written for and checked against, with its firmware line (3.0.0.6).
    public static let referenceModel = "RT-BE88U"
}

/// Which catalog sections a router may save from the app. The catalog mirrors the 3.0.0.6 web pages of the reference
/// router: every 3.0.0.6 router shares those pages, but the professional wireless settings and the 160 MHz switch
/// list fields and choices per model, so they are saved only on the reference model. Other firmware lines are
/// refused before any section (RouterClient.acquireMutation).
public enum SettingsCompatibility {
    public static func isModelSpecific(_ sectionID: String) -> Bool { sectionID.hasPrefix("radio") || sectionID.hasPrefix("band") }

    public static let modelSpecificText = "这一组的选项随机型不同；App 只按 \(RouterProfile.referenceModel) 的网页核对过，这里只显示当前值。如需修改，请在浏览器中使用路由器网页。"

    /// Why a section of this session only shows its values, or nil when it can be saved. The same cases
    /// RouterClient.acquireMutation refuses, said for a page rather than for a request.
    public static func readOnlyReason(sectionID: String, writes: WriteScope) -> String? {
        switch writes {
        case .unverified:
            return "还没有核对这台路由器的型号和固件，这里暂时只显示当前值；核对完成后即可修改。"
        case .verified(_, _, false):
            return "未能读取这台路由器的网页菜单，无法确认它有这一页，这里只显示当前值。如需修改，请在浏览器中使用路由器网页。"
        case .verified(let branch, _, _) where branch != .v3006:
            return "这台路由器是 \(branch.title) 固件；App 的设置页按 3.0.0.6 固件的网页核对，这里只显示当前值。如需修改，请在浏览器中使用路由器网页。"
        case .verified(_, let model, _):
            return isModelSpecific(sectionID) && model != RouterProfile.referenceModel ? modelSpecificText : nil
        }
    }
}
