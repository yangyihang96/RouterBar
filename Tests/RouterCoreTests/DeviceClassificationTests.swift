import Foundation
import Testing
@testable import RouterCore

@Test(arguments: [
    ("roborock-vacuum-a157", DeviceKind.robotVacuum),
    ("yeelink-light-bslamp2_mibt1234", .light),
    ("zair-light-zcw02w_mibt1234", .light),
    ("chuangmi_camera_021a04", .camera),
    ("MiAiSoundbox-L17A", .speaker),
    ("homeassistant", .homeServer),
    ("minas123456", .storage),
    ("MiWiFi-RB04-srv", .router),
    ("xiaodianshi", .television),
    ("iPhone", .phone),
    ("iPad Pro", .tablet),
    ("MacBook-Pro", .laptop),
    ("Mac", .computer),
    ("PS5", .gameConsole)
]) func recognizableNamesGetSpecificDeviceIcons(_ name: String, _ expected: DeviceKind) {
    #expect(DeviceClassifier.classify(name: name, vendor: nil, description: nil).kind == expected)
}

@Test func manufacturerAloneDoesNotInventAPhoneOrLaptop() {
    #expect(DeviceClassifier.classify(name: "bedroom", vendor: "Apple, Inc.", description: nil).kind == .appleDevice)
    #expect(DeviceClassifier.classify(name: "unidentified", vendor: "SHENZHEN BILIAN ELECTRONIC CO.LTD", description: nil).kind == .unknown)
    #expect(DeviceClassifier.classify(name: "Beijing Xiaomi Mobile Software", vendor: "Beijing Xiaomi Mobile Software Co., Ltd.", description: nil).confidence == "较低")
}

@Test func specificDeviceDescriptionBeatsManufacturer() {
    #expect(DeviceClassifier.classify(name: "living-room", vendor: "Apple", description: "Apple TV").kind == .television)
}

@Test func sessionCookieBridgeIsRestrictedToExactRouter() throws {
    let cookie = try #require(HTTPCookie(properties: [.name: "asus_token", .value: "synthetic-test-token", .domain: "192.168.50.1", .path: "/", HTTPCookiePropertyKey("HttpOnly"): "TRUE"]))
    let value = RouterSessionCookie(cookie)
    #expect(value.belongs(to: try RouterEndpoint("192.168.50.1")))
    #expect(!value.belongs(to: try RouterEndpoint("192.168.50.2")))
    #expect(value.nativeCookie()?.value == "synthetic-test-token")
    #expect(value.nativeCookie()?.isHTTPOnly == true)
}
