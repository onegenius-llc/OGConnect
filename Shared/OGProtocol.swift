import Foundation

enum OGProtocol {
    static let version = 1
    static let defaultPort: UInt16 = 5959
    static let maxMessageSize = 32 * 1024 * 1024
}

/// Every message on the wire is `[UInt32 length][UInt8 type][payload]`, where length covers type + payload.
/// Payloads are JSON unless noted.
enum OGMessageType: UInt8 {
    case hello = 1             // S→C ServerHello
    case listWindows = 2       // C→S empty
    case windowList = 3        // S→C [WindowInfo]
    case thumbnailRequest = 4  // C→S ThumbnailRequest
    case thumbnail = 5         // S→C binary: UInt32 window id + JPEG
    case startStream = 6       // C→S StartStream
    case streamStarted = 7     // S→C WindowInfo
    case stopStream = 8        // C→S empty
    case streamEnded = 9       // S→C TextMessage
    case videoFrame = 10       // S→C binary: VideoPacket
    case requestKeyframe = 11  // C→S empty
    case input = 12            // C→S InputEvent
    case error = 13            // S→C TextMessage
    case unlock = 14           // C→S UnlockRequest
    case lockState = 15        // S→C LockState
    case menuRequest = 16      // C→S MenuRequest
    case menu = 17             // S→C MenuListing
    case menuAction = 18       // C→S MenuAction
    case listApps = 19         // C→S empty
    case appList = 20          // S→C [AppInfo]
    case appIconRequest = 21   // C→S AppRequest
    case appIcon = 22          // S→C binary: UInt32 app id + PNG
    case launchApp = 23        // C→S AppRequest
}

struct ServerHello: Codable {
    var version: Int
    var name: String
    var canCapture: Bool
    var canControl: Bool
    var isLocked: Bool?
}

/// Asks the server to type the Mac account password into the lock screen.
struct UnlockRequest: Codable {
    var password: String
}

struct LockState: Codable {
    var isLocked: Bool
    /// Why an unlock attempt didn't work, if one was made.
    var message: String?
}

struct WindowInfo: Codable, Identifiable, Hashable {
    var id: UInt32
    var title: String
    var appName: String
    /// Size in points on the Mac.
    var width: Int
    var height: Int
    /// True for an item in the Mac's menu bar rather than an app window.
    var isMenuBarItem: Bool?
}

/// An app installed on the Mac. The id is only valid until the next app list.
struct AppInfo: Codable, Identifiable, Hashable {
    var id: UInt32
    var name: String
    var isRunning: Bool
}

struct AppRequest: Codable {
    var id: UInt32
}

struct ThumbnailRequest: Codable {
    var windowID: UInt32
    var maxDimension: Int
}

struct StartStream: Codable {
    var windowID: UInt32
}

struct TextMessage: Codable {
    var message: String
}

/// One entry in the streamed app's menu bar or in one of its menus.
struct MenuItemInfo: Codable, Identifiable, Hashable {
    /// Position within its menu; with the parent's path this identifies the item.
    var index: Int
    var title: String
    var enabled: Bool
    var checked: Bool
    var shortcut: String?
    var hasSubmenu: Bool
    var isSeparator: Bool

    var id: Int { index }
}

/// Asks for the items under `path`; an empty path is the menu bar itself.
struct MenuRequest: Codable {
    var path: [Int]
}

struct MenuListing: Codable {
    var path: [Int]
    var items: [MenuItemInfo]
    var error: String?
}

struct MenuAction: Codable {
    var path: [Int]
    var title: String
}

struct Modifiers: OptionSet, Codable, Hashable {
    let rawValue: UInt8
    static let shift = Modifiers(rawValue: 1 << 0)
    static let control = Modifiers(rawValue: 1 << 1)
    static let option = Modifiers(rawValue: 1 << 2)
    static let command = Modifiers(rawValue: 1 << 3)
}

struct InputEvent: Codable {
    enum Kind: String, Codable {
        case move, button, scroll, key, text
    }

    var kind: Kind
    /// Pointer position, normalized 0...1 within the streamed window.
    var x: Double?
    var y: Double?
    /// 0 = left, 1 = right, 2 = middle.
    var button: Int?
    var down: Bool?
    var clicks: Int?
    /// Scroll distance in Mac points; positive dy moves content down.
    var dx: Double?
    var dy: Double?
    /// macOS virtual key code.
    var keyCode: UInt16?
    var isRepeat: Bool?
    var text: String?
    var mods: Modifiers = []

    static func move(x: Double, y: Double, mods: Modifiers) -> InputEvent {
        InputEvent(kind: .move, x: x, y: y, mods: mods)
    }

    static func button(_ button: Int, down: Bool, clicks: Int, x: Double, y: Double, mods: Modifiers) -> InputEvent {
        InputEvent(kind: .button, x: x, y: y, button: button, down: down, clicks: clicks, mods: mods)
    }

    static func scroll(dx: Double, dy: Double, x: Double, y: Double, mods: Modifiers) -> InputEvent {
        InputEvent(kind: .scroll, x: x, y: y, dx: dx, dy: dy, mods: mods)
    }

    static func key(_ keyCode: UInt16, down: Bool, mods: Modifiers, isRepeat: Bool = false) -> InputEvent {
        InputEvent(kind: .key, down: down, keyCode: keyCode, isRepeat: isRepeat, mods: mods)
    }

    static func text(_ text: String, mods: Modifiers) -> InputEvent {
        InputEvent(kind: .text, text: text, mods: mods)
    }
}

/// One encoded H.264 access unit. `data` is AVCC (4-byte length-prefixed NAL units);
/// keyframes carry the SPS/PPS needed to decode from that point.
struct VideoPacket {
    var isKeyframe: Bool
    var parameterSets: [Data]
    var data: Data

    func encoded() -> Data {
        var out = Data(capacity: data.count + 64)
        out.append(isKeyframe ? 1 : 0)
        out.append(UInt8(parameterSets.count))
        for set in parameterSets {
            out.append(UInt8(set.count >> 8))
            out.append(UInt8(set.count & 0xFF))
            out.append(set)
        }
        out.append(data)
        return out
    }

    init(isKeyframe: Bool, parameterSets: [Data], data: Data) {
        self.isKeyframe = isKeyframe
        self.parameterSets = parameterSets
        self.data = data
    }

    init?(payload: Data) {
        let bytes = Data(payload)  // rebase indices to 0
        guard bytes.count >= 2 else { return nil }
        isKeyframe = bytes[0] != 0
        let count = Int(bytes[1])
        var offset = 2
        var sets: [Data] = []
        for _ in 0..<count {
            guard bytes.count >= offset + 2 else { return nil }
            let length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            offset += 2
            guard bytes.count >= offset + length else { return nil }
            sets.append(bytes.subdata(in: offset..<offset + length))
            offset += length
        }
        parameterSets = sets
        data = bytes.subdata(in: offset..<bytes.count)
    }
}

enum ThumbnailPayload {
    static func encode(windowID: UInt32, jpeg: Data) -> Data {
        var out = Data(capacity: jpeg.count + 4)
        withUnsafeBytes(of: windowID.bigEndian) { out.append(contentsOf: $0) }
        out.append(jpeg)
        return out
    }

    static func decode(_ payload: Data) -> (windowID: UInt32, jpeg: Data)? {
        let bytes = Data(payload)
        guard bytes.count > 4 else { return nil }
        let id = bytes.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return (id, bytes.subdata(in: 4..<bytes.count))
    }
}
