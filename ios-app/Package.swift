// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ScatchLM",
    platforms: [.iOS(.v17)],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.0.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "ScatchLM",
            dependencies: [
                .product(name: "Supabase", package: "supabase-swift"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "ScatchLM"
        ),
    ]
)
