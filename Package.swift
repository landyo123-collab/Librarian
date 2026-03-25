// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Librarian",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Librarian", targets: ["IdeaLibrarian"]),
    ],
    dependencies: [
    ],
    targets: [
        .target(
            name: "IdeaLibrarianCore",
            dependencies: [],
            path: "IdeaLibrarian",
            exclude: ["IdeaLibrarianApp.swift", "ContentView.swift", "Assets.xcassets", "IdeaLibrarian.xcdatamodeld", "Persistence.swift", "ViewModels"],
            sources: [
                "Core", "Retriever", "Reasoner", "Scanner", "Index",
                "ContextBuilder", "Distiller"
            ]
        ),
        .executableTarget(
            name: "IdeaLibrarian",
            dependencies: ["IdeaLibrarianCore"],
            path: "IdeaLibrarian",
            exclude: ["Core", "Retriever", "Reasoner", "Scanner", "Index", "ContextBuilder", "Distiller", "Assets.xcassets", "IdeaLibrarian.xcdatamodeld"],
            sources: ["IdeaLibrarianApp.swift", "ContentView.swift", "Persistence.swift", "ViewModels"]
        ),
        .testTarget(
            name: "IdeaLibrarianCoreTests",
            dependencies: ["IdeaLibrarianCore"],
            path: "Tests/IdeaLibrarianCoreTests"
        ),
    ]
)
