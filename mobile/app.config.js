const { execSync } = require("child_process");

function getLocalIP() {
  try {
    return execSync("ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null")
      .toString()
      .trim();
  } catch {
    return "localhost";
  }
}

module.exports = {
  expo: {
    name: "ScatchLM",
    slug: "scatchlm",
    version: "1.0.0",
    orientation: "portrait",
    icon: "./assets/icon.png",
    userInterfaceStyle: "light",
    newArchEnabled: true,
    splash: {
      image: "./assets/splash-icon.png",
      resizeMode: "contain",
      backgroundColor: "#ffffff",
    },
    ios: {
      supportsTablet: true,
      bundleIdentifier: "com.joho54.scatchlm",
    },
    android: {
      adaptiveIcon: {
        foregroundImage: "./assets/adaptive-icon.png",
        backgroundColor: "#ffffff",
      },
      edgeToEdgeEnabled: true,
      predictiveBackGestureEnabled: false,
      package: "com.joho54.scatchlm",
    },
    web: {
      favicon: "./assets/favicon.png",
    },
    scheme: "scatchlm",
    plugins: [
      "expo-sqlite",
      "expo-router",
    ],
    extra: {
      apiHost: getLocalIP(),
    },
  },
};
