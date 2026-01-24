import Foundation
import SwiftData

@Model
final class SessionRecord {
    var startedAt: Date
    var record1Seconds: Double?
    var record2Seconds: Double?
    var endedAt: Date?

    init(startedAt: Date) {
        self.startedAt = startedAt
    }
}
