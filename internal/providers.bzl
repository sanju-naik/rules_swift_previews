# Copyright 2025 Jeff Hodsdon
# SPDX-License-Identifier: Apache-2.0

"""Shared providers for rules_swift_previews."""

SourceFilesInfo = provider(
    doc = "Provider that contains source files collected from library targets.",
    fields = {
        # Swift sources
        "sources": "depset of Swift source files",
        "module_sources": "dict mapping module names to their Swift source files",
        "resource_modules": "dict mapping resource module names to {resources: [...], generated_source: File}",
        "module_deps": "dict mapping module names to their dependency module names",
        # C/C++ modules (from cc_library)
        "cc_modules": "dict mapping module names to {srcs: [...], hdrs: [...]}",
        # Objective-C modules (from objc_library)
        "objc_modules": "dict mapping module names to {srcs: [...], hdrs: [...], private_hdrs: [...]}",
        # XCFramework modules (from data deps/imports)
        "xcframework_modules": "dict mapping module names to xcframework file lists",
        # ObjC/C external (Pod/SPM) modules to build as static xcframeworks.
        # dict mapping module name -> {
        #   "target": str label of the objc/cc library,
        #   "hdrs": [str labels of public headers],
        #   "avoid_deps": [str labels of direct library deps],
        # }
        "binary_xcfw_modules": "dict mapping module names to xcframework build metadata",
        # Swift modules whose Bazel target compiles in Swift 6 language mode
        # (copts contain `-swift-version 6`). These need .swiftLanguageMode(.v6)
        # in the generated Package.swift; the package default stays .v5.
        "swift6_modules": "dict mapping Swift module names that require Swift 6 language mode to True",
    },
)
