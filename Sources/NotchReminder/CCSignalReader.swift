import Foundation

/// 从 ~/.notchreminder/cc.json 读出的 CC 活跃信号(App 侧消费)。
public struct CCSignal: Equatable {
    public var ccActive: Bool
    public var project: String?
    public var lastEvent: Date?

    public init(ccActive: Bool, project: String? = nil, lastEvent: Date? = nil) {
        self.ccActive = ccActive
        self.project = project
        self.lastEvent = lastEvent
    }
}

/// 读并解析 CC 状态文件。缺失/损坏一律容错返回 nil, 绝不抛。
public struct CCSignalReader {
    private let path: URL

    public init(
        path: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".notchreminder/cc.json")
    ) {
        self.path = path
    }

    /// cc.json 的磁盘表示。session_start 本读取器不用, 故不声明。
    private struct Payload: Decodable {
        let ccActive: Bool
        let project: String?
        let lastEvent: String?

        enum CodingKeys: String, CodingKey {
            case ccActive = "cc_active"
            case project
            case lastEvent = "last_event"
        }
    }

    /// 读并解析。任何失败(文件缺失/读失败/JSON 损坏)返回 nil。
    public func read() -> CCSignal? {
        guard let data = try? Data(contentsOf: path) else { return nil }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        let lastEvent = payload.lastEvent.flatMap { iso.date(from: $0) }
        return CCSignal(ccActive: payload.ccActive, project: payload.project, lastEvent: lastEvent)
    }
}
