import RepoBarCore
import SwiftUI

struct HeatmapAxisLabelsView: View {
    let range: HeatmapRange
    private let foregroundStyle: AnyShapeStyle

    init(range: HeatmapRange, foregroundStyle: some ShapeStyle) {
        self.range = range
        self.foregroundStyle = AnyShapeStyle(foregroundStyle)
    }

    var body: some View {
        HStack {
            Text(Self.axisFormatter.string(from: self.range.start))
            Spacer()
            Text(Self.axisFormatter.string(from: self.range.end))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 14)
        .font(.caption2)
        .foregroundStyle(self.foregroundStyle)
    }

    private static let axisFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MMM yyyy"
        return formatter
    }()
}
