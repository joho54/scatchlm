import ExpoModulesCore
import UIKit

public class ExpoLiquidGlassView: ExpoView {

    // MARK: - Props

    var glassRadius: CGFloat = 14
    var bezelWidth: CGFloat = 18
    var glassThickness: CGFloat = 80
    var refractiveIndex: CGFloat = 1.5
    var refractionScale: CGFloat = 1.0
    var specularOpacity: CGFloat = 0.5
    var blurRadius: CGFloat = 0
    var saturation: CGFloat = 1.4

    // MARK: - Internal

    var effectView: UIVisualEffectView?

    // MARK: - Lifecycle

    required init(appContext: AppContext? = nil) {
        super.init(appContext: appContext)
        setupGlass()
    }

    private func setupGlass() {
        if #available(iOS 26.0, *) {
            let glassEffect = UIGlassEffect(style: .clear)
            glassEffect.isInteractive = true
            let ev = UIVisualEffectView(effect: glassEffect)
            ev.translatesAutoresizingMaskIntoConstraints = false
            addSubview(ev)

            NSLayoutConstraint.activate([
                ev.topAnchor.constraint(equalTo: topAnchor),
                ev.bottomAnchor.constraint(equalTo: bottomAnchor),
                ev.leadingAnchor.constraint(equalTo: leadingAnchor),
                ev.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])

            effectView = ev
        } else {
            let blur = UIBlurEffect(style: .systemUltraThinMaterial)
            let ev = UIVisualEffectView(effect: blur)
            ev.translatesAutoresizingMaskIntoConstraints = false
            addSubview(ev)

            NSLayoutConstraint.activate([
                ev.topAnchor.constraint(equalTo: topAnchor),
                ev.bottomAnchor.constraint(equalTo: bottomAnchor),
                ev.leadingAnchor.constraint(equalTo: leadingAnchor),
                ev.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])

            effectView = ev
        }

        clipsToBounds = true
    }

    func setNeedsGlassUpdate() {
        setNeedsLayout()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = glassRadius
        effectView?.layer.cornerRadius = glassRadius
        effectView?.clipsToBounds = true
    }

    // Fabric adds children directly as subviews.
    // Move any non-effectView child into effectView.contentView
    public override func didAddSubview(_ subview: UIView) {
        super.didAddSubview(subview)
        guard subview !== effectView,
              let contentView = effectView?.contentView else { return }
        subview.removeFromSuperview()
        contentView.addSubview(subview)
    }
}
