import Foundation
import SwiftData

@Model
final class SessionRecord {
    var startedAt: Date
    var endedAt: Date?

    var record1Seconds: Double?
    var record2Seconds: Double?

    init(startedAt: Date) {
        self.startedAt = startedAt
    }
}
