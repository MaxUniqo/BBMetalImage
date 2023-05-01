// swift-tools-version:5.5
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "BBMetalImage",
    platforms: [.iOS(.v10)],
    products: [
        .library(name: "BBMetalImage", targets: [
            "BBMetalImage"
        ]),
    ],
    targets: [
        .target(
            name: "BBMetalImageObjC",
            path: "BBMetalImage/BBMetalImageObjC",
            publicHeadersPath: "Headers"
        ),
        .target(
            name: "BBMetalImage",
            dependencies: [
                .target(name: "BBMetalImageObjC")
            ],
            path: "BBMetalImage/BBMetalImage",
            resources: [
                .process("BBMetalImage/BBMetalImage/Metal/")
            ]
        )
    ]
)
