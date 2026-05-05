import ExpoModulesCore

public class ExpoLiquidGlassModule: Module {
    public func definition() -> ModuleDefinition {
        Name("ExpoLiquidGlass")

        View(ExpoLiquidGlassView.self) {
            Prop("radius") { (view: ExpoLiquidGlassView, value: CGFloat) in
                view.glassRadius = value
                view.setNeedsGlassUpdate()
            }
            Prop("bezelWidth") { (view: ExpoLiquidGlassView, value: CGFloat) in
                view.bezelWidth = value
            }
            Prop("glassThickness") { (view: ExpoLiquidGlassView, value: CGFloat) in
                view.glassThickness = value
            }
            Prop("refractiveIndex") { (view: ExpoLiquidGlassView, value: CGFloat) in
                view.refractiveIndex = value
            }
            Prop("refractionScale") { (view: ExpoLiquidGlassView, value: CGFloat) in
                view.refractionScale = value
            }
            Prop("specularOpacity") { (view: ExpoLiquidGlassView, value: CGFloat) in
                view.specularOpacity = value
            }
            Prop("blurRadius") { (view: ExpoLiquidGlassView, value: CGFloat) in
                view.blurRadius = value
            }
            Prop("saturation") { (view: ExpoLiquidGlassView, value: CGFloat) in
                view.saturation = value
            }
        }
    }
}
