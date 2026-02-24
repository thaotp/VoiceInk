import Foundation
import SwiftUI

private struct ProgressDotsWithNumber: View {
    let value: Double

    private var clampedValue: Double {
        min(max(value, 0.0), 10.0)
    }

    private var filledDots: Int {
        Int((clampedValue / 2.0).rounded(.toNearestOrAwayFromZero))
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                Circle()
                    .fill(index < filledDots ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: 4, height: 4)
            }
            Text(String(format: "%.1f", clampedValue))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(.secondary)
        }
    }
}

@ViewBuilder
func progressDotsWithNumber(value: Double) -> some View {
    ProgressDotsWithNumber(value: value)
}
