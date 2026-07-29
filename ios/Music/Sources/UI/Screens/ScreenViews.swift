import UIKit

final class ArtworkView: UIImageView {
    init(image: UIImage?, cornerRadius: CGFloat = 8) {
        super.init(image: image)
        translatesAutoresizingMaskIntoConstraints = false
        contentMode = .scaleAspectFill; clipsToBounds = true
        backgroundColor = ScreenPalette.softFill; layer.cornerRadius = cornerRadius
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
