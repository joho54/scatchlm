module.exports = {
  preset: "ts-jest",
  testEnvironment: "node",
  roots: ["<rootDir>/__tests__"],
  moduleFileExtensions: ["ts", "tsx", "js", "jsx"],
  setupFiles: ["./jest.setup.js"],
  moduleNameMapper: {
    "^expo-sqlite$": "<rootDir>/__mocks__/expo-sqlite.js",
    "^@shopify/react-native-skia$": "<rootDir>/__mocks__/react-native-skia.js",
    "^@react-native-async-storage/async-storage$": "<rootDir>/__mocks__/async-storage.js",
  },
};
