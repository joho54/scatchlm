import { requireNativeViewManager } from "expo-modules-core";
import { ViewProps } from "react-native";

export interface LiquidGlassProps extends ViewProps {
  /** Border radius (px) */
  radius: number;
  /** Bezel width — reserved for future custom refraction */
  bezelWidth?: number;
  /** Glass thickness — reserved */
  glassThickness?: number;
  /** Refractive index — reserved */
  refractiveIndex?: number;
  /** Refraction scale — reserved */
  refractionScale?: number;
  /** Specular opacity — reserved */
  specularOpacity?: number;
  /** Blur radius — reserved */
  blurRadius?: number;
  /** Saturation — reserved */
  saturation?: number;
}

const NativeView = requireNativeViewManager<LiquidGlassProps>("ExpoLiquidGlass");

export default NativeView;
