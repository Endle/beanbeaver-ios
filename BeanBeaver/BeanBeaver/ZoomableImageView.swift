import SwiftUI
import UIKit

/// A pinch-, double-tap-, and pan-to-zoom image viewer.
///
/// SwiftUI's `ScrollView` can't zoom, so we lean on `UIScrollView`, which gives
/// us the whole native zoom stack for free — pinch magnification, drag-to-pan
/// while zoomed, rubber-band bounce, and fling momentum — behaving exactly like
/// Photos.app. That matters here: reviewing a receipt means zooming into one
/// small line of print and panning around it, which the hand-rolled
/// `MagnifyGesture` alternatives never get quite right.
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    /// How far past "fit to screen" a pinch (or double-tap) can push. 6× is
    /// enough to read the smallest receipt print without letting the image
    /// dissolve into blur.
    private let maxZoomFactor: CGFloat = 6

    func makeUIView(context: Context) -> ImageScrollView {
        let scrollView = ImageScrollView()
        scrollView.delegate = context.coordinator
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.backgroundColor = .clear
        // We size and center the image ourselves; don't let the scroll view add
        // its own nav-bar insets on top and fight us for the offset.
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.maxZoomFactor = maxZoomFactor
        scrollView.setImage(image)
        context.coordinator.imageView = scrollView.imageView

        // Double-tap toggles between fit and zoomed-in-on-the-tap, the gesture
        // people reach for before they think to pinch.
        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        return scrollView
    }

    func updateUIView(_ scrollView: ImageScrollView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var imageView: UIImageView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView = recognizer.view as? UIScrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                let target = min(scrollView.maximumZoomScale, scrollView.zoomScale * 3)
                scrollView.zoom(to: zoomRect(in: scrollView, around: recognizer.location(in: imageView),
                                             scale: target), animated: true)
            }
        }
    }
}

/// The rectangle (in the image view's coordinate space) that, zoomed to fill
/// the scroll view at `scale`, keeps `point` centred. Shared by the double-tap
/// handler.
private func zoomRect(in scrollView: UIScrollView, around point: CGPoint, scale: CGFloat) -> CGRect {
    let size = CGSize(width: scrollView.bounds.width / scale,
                      height: scrollView.bounds.height / scale)
    return CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                  width: size.width, height: size.height)
}

/// A scroll view that shows one image at "fit to viewport" and lets the user
/// zoom in from there.
///
/// This is the long-standing UIKit image-viewer recipe: the image view is sized
/// to the image's own pixels (never to the viewport), `minimumZoomScale` is the
/// scale that fits it on screen, and `layoutSubviews` keeps the image centred
/// while it's smaller than the viewport. Doing it here rather than in the
/// representable's `updateUIView` matters — SwiftUI lays the scroll view out
/// *after* `updateUIView`, so its bounds are still zero there and never
/// revisited, which is what left an earlier attempt showing nothing.
final class ImageScrollView: UIScrollView {
    let imageView = UIImageView()
    var maxZoomFactor: CGFloat = 6
    private var sizedForBounds: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(imageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been used") }

    func setImage(_ image: UIImage) {
        imageView.image = image
        imageView.frame = CGRect(origin: .zero, size: image.size)
        contentSize = image.size
        sizedForBounds = .zero  // force a fit recompute on the next layout pass
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        // Recompute the fit scale the first time we get real bounds, and again
        // whenever the viewport resizes (rotation, split view).
        let imageSize = imageView.bounds.size
        if imageSize.width > 0, bounds.width > 0, bounds.size != sizedForBounds {
            sizedForBounds = bounds.size
            let fit = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
            minimumZoomScale = fit
            maximumZoomScale = fit * maxZoomFactor
            zoomScale = fit
        }

        // Centre the image whenever it's smaller than the viewport (always true
        // along at least one axis at fit scale) so it doesn't cling to a corner.
        var frame = imageView.frame
        frame.origin.x = max((bounds.width - frame.width) / 2, 0)
        frame.origin.y = max((bounds.height - frame.height) / 2, 0)
        imageView.frame = frame
    }
}
