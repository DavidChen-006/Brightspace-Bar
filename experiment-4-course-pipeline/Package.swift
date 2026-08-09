// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CoursePipeline",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CoursePipeline", targets: ["CoursePipeline"])
    ],
    targets: [
        .target(name: "CoursePipeline"),
        .testTarget(name: "CoursePipelineTests", dependencies: ["CoursePipeline"]),
    ]
)
