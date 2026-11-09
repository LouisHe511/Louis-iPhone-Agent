// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Persisted developer route; active bridges retain the shared connection and
/// prevent route changes until their run has released it.
enum DeviceControlRoute: String, Sendable {
    case onDeviceXCTest
    case vpnLoopback = "localDevVPN"
    case ncmDeveloper
    case localCaptureUSB
    static let defaultsKey = "deviceControlRoute"
    static var current: Self { load(from: .standard) }
    static func load(from defaults: UserDefaults) -> Self {
        // Retained capture route is not exposed by this setting.
        switch defaults.string(forKey: defaultsKey) {
        case Self.onDeviceXCTest.rawValue: return .onDeviceXCTest
        case Self.ncmDeveloper.rawValue: return .ncmDeveloper
        default: return .vpnLoopback
        }
    }
    var title: String { if self == .onDeviceXCTest { return String(localized: "On-device control") }; return self == .vpnLoopback ? String(localized: "VPN loopback") : "ESP32 NCM" }
    var connectionName: String { if self == .onDeviceXCTest { return String(localized: "On-device control") }; return self == .vpnLoopback ? String(localized: "VPN loopback") : "ESP32" }
    var controlTitle: String { if self == .onDeviceXCTest { return String(localized: "On-device control") }; return self == .vpnLoopback ? String(localized: "VPN loopback control") : String(localized: "ESP32 control") }
    var modelContext: String {
        switch self {
        case .onDeviceXCTest:
            return "Screenshots and input use the authenticated local UI automation runner on this iPhone. No Wi-Fi, VPN or external hardware is needed while the runner is active; cellular data can serve model requests. Device tools retain session ownership, frame geometry checks and action authorization. A reconnect invalidates old frames and grants. Never automatically replay an uncertain input. Follow readiness errors; developer-service preparation and signing are still required."
        case .ncmDeveloper:
            return "Screenshots and touch input use the authenticated ESP32 NCM developer connection. Background execution needs an active execution source. Device tools wait for a paired connection internally; reconnecting invalidates old frames and action grants, while read tools can bind the new session."
        case .vpnLoopback:
            return "Screenshots and touch input use authenticated CoreDevice services through a local VPN loopback on this phone, without ESP32. A compatible packet-reflection VPN must already be enabled with the configured interface and peer addresses. Device tools verify the paired connection internally; reconnecting invalidates old frames and action grants. Follow actual readiness errors."
        case .localCaptureUSB:
            return "Screenshots use this App's authorized ScreenCaptureKit capture, independently of USB. Touch input uses the retained USB HID route. Follow the tools' actual foreground/background capabilities."
        }
    }
}
