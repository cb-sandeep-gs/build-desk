import SwiftUI

/// The app's icon, drawn in code so it can be re-rendered at any size: a hammer on a blue tile.
/// `Scripts/make-icon.sh` renders it and builds `Resources/AppIcon.icns`.
public struct AppIconView: View {
    /// The side of the square the icon is drawn in, in points.
    public static let canvasSize: CGFloat = 1024
    // Apple's macOS icon grid: the tile leaves a margin for its shadow and has continuous corners.
    private static let tileInset: CGFloat = 100
    private static let cornerRadius: CGFloat = 185
    private static let symbolSize: CGFloat = 440
    private static let shadowRadius: CGFloat = 18
    private static let shadowOffset: CGFloat = 10

    public init() {}

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.26, green: 0.56, blue: 1.0), Color(red: 0.08, green: 0.30, blue: 0.85)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .shadow(color: .black.opacity(0.3), radius: Self.shadowRadius, y: Self.shadowOffset)
                .padding(Self.tileInset)
            Image(systemName: "hammer.fill")
                .font(.system(size: Self.symbolSize, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: Self.canvasSize, height: Self.canvasSize)
    }
}
