import Foundation

public enum DeviceKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case phone, tablet, laptop, desktop, computer, television, speaker, camera, robotVacuum, light
    case storage, homeServer, router, printer, gameConsole, watch, plug, appliance, appleDevice, smartHome, unknown
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .phone: "手机"; case .tablet: "平板电脑"; case .laptop: "笔记本电脑"; case .desktop: "台式电脑"
        case .computer: "电脑"; case .television: "电视 / 影音"; case .speaker: "智能音箱"; case .camera: "摄像头"; case .robotVacuum: "扫地机器人"
        case .light: "智能灯具"; case .storage: "网络存储"; case .homeServer: "家庭服务器"; case .router: "网络设备"
        case .printer: "打印机"; case .gameConsole: "游戏主机"; case .watch: "手表 / 穿戴"; case .plug: "智能插座"
        case .appliance: "家用电器"; case .appleDevice: "Apple 设备"; case .smartHome: "智能家居"; case .unknown: "待识别设备"
        }
    }
    public var symbol: String {
        switch self {
        case .phone: "iphone"; case .tablet: "ipad"; case .laptop: "laptopcomputer"; case .desktop: "desktopcomputer"
        case .computer: "desktopcomputer"; case .television: "tv"; case .speaker: "hifispeaker.fill"; case .camera: "web.camera.fill"
        case .robotVacuum: "robotic.vacuum.fill"; case .light: "lightbulb.fill"; case .storage: "externaldrive.fill"
        case .homeServer: "server.rack"; case .router: "wifi.router.fill"; case .printer: "printer.fill"
        case .gameConsole: "gamecontroller.fill"; case .watch: "applewatch"; case .plug: "powerplug.fill"
        case .appliance: "washer.fill"; case .appleDevice: "apple.logo"; case .smartHome: "house.lodge.fill"
        case .unknown: "questionmark.square.dashed"
        }
    }
    public var family: String {
        switch self {
        case .phone, .tablet, .laptop, .desktop, .computer, .watch, .appleDevice: "个人设备"
        case .television, .speaker, .gameConsole: "影音娱乐"
        case .camera, .robotVacuum, .light, .plug, .appliance, .smartHome: "智能家居"
        case .storage, .homeServer, .router, .printer: "网络与存储"
        case .unknown: "待识别"
        }
    }
}

public struct DeviceClassification: Sendable, Equatable {
    public let kind: DeviceKind
    public let reason: String
    public let confidence: String
}

public enum DeviceClassifier {
    public static func classify(name: String, vendor: String?, description: String?) -> DeviceClassification {
        let named = name.lowercased()
        let info = (name + " " + (description ?? "")).lowercased()
        let maker = vendor?.lowercased() ?? ""
        func matches(_ keywords: [String]) -> Bool { keywords.contains { info.contains($0) } }
        func result(_ kind: DeviceKind, _ reason: String = "根据设备名称和类型信息识别", _ confidence: String = "较高") -> DeviceClassification {
            .init(kind: kind, reason: reason, confidence: confidence)
        }
        // Specific product families precede generic OS / manufacturer names.
        if matches(["roborock", "dreame", "deebot", "vacuum", "rockrobo", "扫地", "扫拖", "irobot", "roomba"]) { return result(.robotVacuum) }
        if matches(["yeelink", "yeelight", "light-bslamp", "light-lamp", "zair-light", "philips hue", "灯", "nanoleaf", "lifx"]) { return result(.light) }
        if matches(["chuangmi_camera", "camera", "webcam", "ipc-", "imou", "ezviz", "reolink", "摄像", "doorbell", "hikvision"]) { return result(.camera) }
        if matches(["miaisoundbox", "soundbox", "homepod", "sonos", "speaker", "echo dot", "音箱", "音响"]) { return result(.speaker) }
        if matches(["homeassistant", "home-assistant", "home assistant", "raspberry", "proxmox", "homeserver"]) { return result(.homeServer) }
        if matches(["synology", "diskstation", "qnap", "truenas", "ugreen-nas", "minas", "nas-", "nas_", "网络存储"]) || named == "nas" { return result(.storage) }
        if matches(["appletv", "apple-tv", "apple tv", "xiaodianshi", "电视", "dianshi", "chromecast", "roku", "bravia", "firetv", "smarttv", "android-tv"]) { return result(.television) }
        if matches(["playstation", "ps4", "ps5", "xbox", "nintendo", "steamdeck", "steam-deck", "游戏机"]) { return result(.gameConsole) }
        if matches(["printer", "laserjet", "officejet", "deskjet", "epson", "打印"]) || maker.contains("brother") { return result(.printer) }
        if matches(["iphone", "pixel-", "pixel ", "galaxy-s", "galaxy s", "redmi", "xiaomi-phone", "oneplus", "手机"]) { return result(.phone) }
        if matches(["ipad", "tablet", "galaxy-tab", "galaxy tab", "平板"]) { return result(.tablet) }
        if matches(["applewatch", "apple-watch", "watch", "手表", "fitbit"]) { return result(.watch) }
        if matches(["macbook", "laptop", "thinkpad", "surface", "笔记本"]) { return result(.laptop) }
        if matches(["imac", "macmini", "mac-mini", "mac mini", "mac studio", "desktop", "台式", "pc-"]) { return result(.desktop) }
        if named == "mac" || named.hasSuffix("-mac") { return result(.computer, "名称仅表明 Mac；无法确定具体机型", "一般") }
        if matches(["miwifi", "router", "asus", "unifi", "ubiquiti", "eero", "orbi", "路由", "access-point", "deco"]) { return result(.router) }
        if matches(["plug", "socket", "插座", "powerstrip"]) { return result(.plug) }
        if matches(["purifier", "aircon", "washer", "fridge", "humidifier", "净化", "空调", "洗衣", "冰箱", "petkit", "litter"]) { return result(.appliance) }
        if matches(["android"]) { return result(.phone, "名称含 Android，可能是手机或其他 Android 终端", "较低") }
        if maker.contains("apple") { return result(.appleDevice, "厂商为 Apple，名称不足以判断具体品类", "一般") }
        if maker.contains("xiaomi") || maker.contains("aqara") || maker.contains("tuya") || maker.contains("ifanr") {
            return result(.smartHome, "仅根据厂商推测为智能家居设备", "较低")
        }
        return result(.unknown, "现有名称、厂商和类型信息不足，可手动指定图标", "未知")
    }
}
