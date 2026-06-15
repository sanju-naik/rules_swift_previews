# Copyright 2025 Jeff Hodsdon
# SPDX-License-Identifier: Apache-2.0

"""Package.swift generation logic for rules_swift_previews."""

def generate_package_swift(
        name,
        dep_modules,
        resource_modules,
        module_deps = None,
        cc_modules = None,
        objc_modules = None,
    xcframework_modules = None,
    binary_xcfw_modules = None,
    binary_module_renames = None,
    swift6_modules = None,
    detected_swift6_modules = None,
        extra_excludes = None,
    exclude_modules = None,
    main_target_path = ".",
    main_target_sources = None,
        ios_version = "18",
        macos_version = "",
        tvos_version = "",
        watchos_version = "",
        visionos_version = ""):
    """Generate the Package.swift content.

    Args:
        name: The main module name (from the swift_library target)
        dep_modules: List of Swift dependency module names
        resource_modules: List of resource module names
        module_deps: Dict mapping module names to their dependency module names
        cc_modules: List of C/C++ module names
        objc_modules: List of Objective-C module names
        xcframework_modules: List of XCFramework module names
        extra_excludes: Additional directories/files to exclude from main target
        exclude_modules: Module names to drop entirely from the package. Each is
            removed as a target/binaryTarget and stripped from every other
            target's dependencies (it is filtered out of every module list, so
            the all_modules set logic strips it everywhere). Use for a dependency
            that cannot link in the SwiftUI Preview executor (e.g. a prebuilt
            library-evolution Swift binary).
        main_target_path: Relative path to the main target sources
        main_target_sources: Optional explicit list of package-root-relative
            source paths for the main target. Set when the main module's sources
            are scattered across multiple top-level directories (main_target_path
            == "."); emitted as a SwiftPM `sources:` array so SwiftPM compiles
            exactly these files instead of scanning the whole package root.
        ios_version: iOS deployment target version
        macos_version: macOS deployment target version (empty to omit)
        tvos_version: tvOS deployment target version (empty to omit)
        watchos_version: watchOS deployment target version (empty to omit)
        visionos_version: visionOS deployment target version (empty to omit)

    Returns:
        String content of the Package.swift file
    """
    if module_deps == None:
        module_deps = {}
    if cc_modules == None:
        cc_modules = []
    if objc_modules == None:
        objc_modules = []
    if xcframework_modules == None:
        xcframework_modules = []
    if binary_xcfw_modules == None:
        binary_xcfw_modules = []
    if binary_module_renames == None:
        binary_module_renames = {}
    if swift6_modules == None:
        swift6_modules = []
    if detected_swift6_modules == None:
        detected_swift6_modules = []
    if extra_excludes == None:
        extra_excludes = []
    if exclude_modules == None:
        exclude_modules = []

    # Drop fully-excluded modules from every module list. Because all downstream
    # target emission and the all_modules dependency filter read these lists, an
    # excluded module produces no target/binaryTarget and disappears from every
    # other target's dependencies array.
    exclude_set = {m: True for m in exclude_modules}
    if exclude_set:
        dep_modules = [m for m in dep_modules if m not in exclude_set]
        resource_modules = [m for m in resource_modules if m not in exclude_set]
        cc_modules = [m for m in cc_modules if m not in exclude_set]
        objc_modules = [m for m in objc_modules if m not in exclude_set]
        xcframework_modules = [m for m in xcframework_modules if m not in exclude_set]
        binary_xcfw_modules = [m for m in binary_xcfw_modules if m not in exclude_set]

    swift6_set = {m: True for m in swift6_modules}

    def _xcfw_bundle_name(module):
        return module.replace("-", "_").replace(".", "_")

    normalized_name = name[:-5] if name.endswith("Views") and len(name) > 5 else name

    swift_modules = [normalized_name] + dep_modules
    resource_owner = {}
    separate_resource_modules = []
    for res_module in resource_modules:
        owner = None
        if res_module.endswith("Resources") and len(res_module) > len("Resources"):
            owner_candidate = res_module[:-len("Resources")]
            if owner_candidate == name or owner_candidate == normalized_name:
                owner = normalized_name
            elif owner_candidate in swift_modules:
                owner = owner_candidate
        elif res_module in swift_modules and not res_module.endswith("Resources"):
            owner = res_module

        if owner:
            if owner not in resource_owner:
                resource_owner[owner] = []
            resource_owner[owner].append(res_module)
        else:
            separate_resource_modules.append(res_module)

    main_resource_modules = resource_owner.get(normalized_name, [])
    merged_resource_modules = []
    for modules in resource_owner.values():
        merged_resource_modules.extend(modules)
    merged_resource_to_owner = {}
    for owner, modules in resource_owner.items():
        for module in modules:
            merged_resource_to_owner[module] = owner

    # Filter out resource modules from dep_modules to avoid duplicates
    filtered_dep_modules = [m for m in dep_modules if m not in resource_modules]

    # Build platforms array from provided versions
    platform_entries = []
    if ios_version:
        platform_entries.append('.iOS("{}.0")'.format(ios_version))
    if macos_version:
        platform_entries.append('.macOS("{}.0")'.format(macos_version))
    if tvos_version:
        platform_entries.append('.tvOS("{}.0")'.format(tvos_version))
    if watchos_version:
        platform_entries.append('.watchOS("{}.0")'.format(watchos_version))
    if visionos_version:
        platform_entries.append('.visionOS("{}.0")'.format(visionos_version))

    platforms_str = ", ".join(platform_entries) if platform_entries else '.iOS("18.0")'

    # tools-version 6.0 is required so per-target .swiftLanguageMode(.v6) is
    # available. The package default language mode is pinned to .v5 (see
    # swiftLanguageModes at the bottom) so only modules explicitly opted into the
    # rule's swift6_modules attribute compile in Swift 6; everything else keeps
    # compiling exactly as before.
    lines = [
        "// swift-tools-version: 6.0",
        "// GENERATED - Regenerate with: bazel run :previews",
    ]

    # Surface modules whose Bazel target builds with -swift-version 6 as opt-in
    # candidates. They are NOT forced to v6 (that surfaces strict-concurrency /
    # @retroactive errors the app's per-module build does not hit); add the ones
    # that actually need Swift 6 semantics to the swift6_modules attribute.
    candidates = [m for m in detected_swift6_modules if m not in swift6_set]
    if candidates:
        lines.append(
            "// Bazel Swift-6 module candidates (add to swift6_modules to enable .v6): " +
            ", ".join(sorted(candidates)),
        )

    lines.extend([
        "",
        "import PackageDescription",
        "",
        "let package = Package(",
        '    name: "{name}",'.format(name = normalized_name),
        '    defaultLocalization: "en",',
        "    platforms: [{platforms}],".format(platforms = platforms_str),
        "    products: [",
        '        .library(name: "{name}", targets: ["{name}"]),'.format(name = normalized_name),
        "    ],",
        "    dependencies: [",
        "    ],",
        "    targets: [",
    ])

    # All available modules (for filtering deps)
    all_modules = set(filtered_dep_modules + list(separate_resource_modules) + cc_modules + objc_modules + xcframework_modules + binary_xcfw_modules)

    # Add XCFramework binary targets
    for module in xcframework_modules:
        lines.extend([
            "        .binaryTarget(",
            '            name: "{module}",'.format(module = module),
            '            path: ".deps/{module}/{module}.xcframework"'.format(module = module),
            "        ),",
        ])

    # Add Bazel-built ObjC/C dependency xcframeworks as binary targets. The inner
    # framework uses a sanitized (identifier-safe) bundle name, while the SwiftPM
    # target keeps the module name so other targets' dependency lists resolve.
    for module in binary_xcfw_modules:
        bundle = _xcfw_bundle_name(module)
        lines.extend([
            "        .binaryTarget(",
            '            name: "{module}",'.format(module = module),
            '            path: ".deps/{module}/{bundle}.xcframework"'.format(module = module, bundle = bundle),
            "        ),",
        ])

    # Add C/C++ module targets first (they're typically at the bottom of the dependency tree)
    for module in cc_modules:
        deps = [binary_module_renames.get(d, d) for d in module_deps.get(module, [])]
        deps = [d for d in deps if d in all_modules and d != module]
        deps_str = ", ".join(['"{}"'.format(d) for d in deps])
        lines.extend([
            "        .target(",
            '            name: "{module}",'.format(module = module),
            "            dependencies: [{deps}],".format(deps = deps_str),
            '            path: ".deps/{module}",'.format(module = module),
            '            publicHeadersPath: "include"',
            "        ),",
        ])

    # Add Objective-C module targets (typically depend on C modules)
    for module in objc_modules:
        deps = [binary_module_renames.get(d, d) for d in module_deps.get(module, [])]
        deps = [d for d in deps if d in all_modules and d != module]
        deps_str = ", ".join(['"{}"'.format(d) for d in deps])
        lines.extend([
            "        .target(",
            '            name: "{module}",'.format(module = module),
            "            dependencies: [{deps}],".format(deps = deps_str),
            '            path: ".deps/{module}",'.format(module = module),
            '            publicHeadersPath: "include"',
            "        ),",
        ])

    # Add Swift dependency module targets
    for module in filtered_dep_modules:
        # Get deps from module_deps, filter to only include modules we have
        deps = module_deps.get(module, [])
        resolved_deps = []
        seen_resolved = set()
        for dep in deps:
            resolved_dep = merged_resource_to_owner.get(dep, dep)
            resolved_dep = binary_module_renames.get(resolved_dep, resolved_dep)
            if resolved_dep in all_modules and resolved_dep != module and resolved_dep not in seen_resolved:
                seen_resolved.add(resolved_dep)
                resolved_deps.append(resolved_dep)
        deps_str = ", ".join(['"{}"'.format(d) for d in resolved_deps])

        dep_resources_str = ""
        if module in resource_owner:
            dep_resource_entries = [
                '.process("{}/Resources")'.format(res_module)
                for res_module in resource_owner[module]
            ]
            dep_resources_str = "            resources: [{}],".format(", ".join(dep_resource_entries))

        lines.extend([
            "        .target(",
            '            name: "{module}",'.format(module = module),
            "            dependencies: [{deps}],".format(deps = deps_str),
            '            path: ".deps/{module}",'.format(module = module),
            '            exclude: ["Package.swift"],',
        ])

        if dep_resources_str:
            lines.append(dep_resources_str)

        if module in swift6_set:
            lines.extend([
                "            swiftSettings: [",
                "                .swiftLanguageMode(.v6),",
                "            ]",
            ])

        lines.append("        ),")

    # Add resource module targets - also in .deps/
    for res_module in separate_resource_modules:
        lines.extend([
            "        .target(",
            '            name: "{name}",'.format(name = res_module),
            "            dependencies: [],",
            '            path: ".deps/{name}",'.format(name = res_module),
            '            resources: [.process("Resources")]',
            "        ),",
        ])

    # Add main view target - path is "." (the Views directory itself)
    # Include all module types in dependencies
    all_deps = cc_modules + objc_modules + xcframework_modules + binary_xcfw_modules + filtered_dep_modules + list(separate_resource_modules)

    # Remove duplicates while preserving order
    seen = set()
    unique_deps = []
    for d in all_deps:
        if d not in seen:
            seen.add(d)
            unique_deps.append(d)

    deps_str = ", ".join(['"{}"'.format(d) for d in unique_deps])

    # Build exclude list for the main target
    # Only include excludes that are very likely to exist in any Bazel project
    excludes = [
        "BUILD.bazel",
        ".deps",
        "Package.swift",
        "MODULE.bazel",
        "MODULE.bazel.lock",
    ]

    # User-specified extra excludes. Callers typically copy these straight from
    # the swift_library glob `exclude`, so they are relative to the Bazel package
    # (e.g. "GoMartNew/src/Foo.swift"). SwiftPM `exclude` paths, however, are
    # relative to the target's `path`. Strip the main target path prefix so both
    # the package-relative (BUILD) form and the already-relative form land
    # correctly. SwiftPM exclude does not support glob/wildcards, so entries
    # containing glob metacharacters are dropped (they cannot be expressed).
    strip_prefix = main_target_path + "/" if main_target_path and main_target_path != "." else ""
    for e in extra_excludes:
        if "*" in e or "?" in e or "{" in e:
            continue
        excludes.append(e[len(strip_prefix):] if strip_prefix and e.startswith(strip_prefix) else e)

    # Format the exclude list
    exclude_str = ", ".join(['"{}"'.format(e) for e in excludes])

    main_resources_str = ""
    if main_resource_modules:
        main_resource_entries = [
            '.process(".deps/{}/Resources")'.format(module)
            for module in main_resource_modules
        ]
        main_resources_str = "            resources: [{}],".format(", ".join(main_resource_entries))

    main_is_swift6 = normalized_name in swift6_set or name in swift6_set

    # When the main module's sources are scattered (path == "."), emit an explicit
    # per-file `sources` list so SwiftPM compiles exactly these files. We list
    # files, not their parent directory: a directory entry makes SwiftPM scan the
    # whole subtree, dragging in non-Swift resources and *+Previews.swift that the
    # Bazel glob excludes. NOTE: `exclude` is still emitted alongside `sources` --
    # `sources` only restricts which *source* files compile; SwiftPM still
    # auto-discovers *resources* across the whole `path`, so `exclude` (extended
    # via extra_excludes) is required to keep sibling resources out and avoid
    # "multiple resources named ..." collisions.
    sources_line = None
    if main_target_sources:
        sources_entries = ", ".join(['"{}"'.format(s) for s in main_target_sources])
        sources_line = "            sources: [{}]".format(sources_entries)

    exclude_line = "            exclude: [{excludes}]".format(excludes = exclude_str)
    if sources_line or main_resources_str or main_is_swift6:
        exclude_line += ","

    lines.extend([
        "        .target(",
        '            name: "{name}",'.format(name = normalized_name),
        "            dependencies: [{deps}],".format(deps = deps_str),
            '            path: "{path}",'.format(path = main_target_path),
        exclude_line,
    ])

    if sources_line:
        if main_resources_str or main_is_swift6:
            sources_line += ","
        lines.append(sources_line)

    if main_resources_str:
        lines.append(main_resources_str)

    if main_is_swift6:
        lines.extend([
            "            swiftSettings: [",
            "                .swiftLanguageMode(.v6),",
            "            ]",
        ])

    # Pin the package default language mode to .v5 so only swift6_modules opt
    # into Swift 6. tools-version is 6.0, whose implicit default would otherwise
    # be .v6 for every target.
    lines.extend([
        "        ),",
        "    ],",
        "    swiftLanguageModes: [.v5]",
        ")",
    ])

    return "\n".join(lines)
