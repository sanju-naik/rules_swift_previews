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
        extra_excludes = None,
    main_target_path = ".",
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
        main_target_path: Relative path to the main target sources
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
    if extra_excludes == None:
        extra_excludes = []

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

    lines = [
        "// swift-tools-version: 5.9",
        "// GENERATED - Regenerate with: bazel run :previews",
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
    ]

    # All available modules (for filtering deps)
    all_modules = set(filtered_dep_modules + list(separate_resource_modules) + cc_modules + objc_modules + xcframework_modules)

    # Add XCFramework binary targets
    for module in xcframework_modules:
        lines.extend([
            "        .binaryTarget(",
            '            name: "{module}",'.format(module = module),
            '            path: ".deps/{module}/{module}.xcframework"'.format(module = module),
            "        ),",
        ])

    # Add C/C++ module targets first (they're typically at the bottom of the dependency tree)
    for module in cc_modules:
        deps = module_deps.get(module, [])
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
        deps = module_deps.get(module, [])
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
    all_deps = cc_modules + objc_modules + xcframework_modules + filtered_dep_modules + list(separate_resource_modules)

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

    # Add any user-specified extra excludes (for source directories, bazel symlinks, etc.)
    excludes.extend(extra_excludes)

    # Format the exclude list
    exclude_str = ", ".join(['"{}"'.format(e) for e in excludes])

    main_resources_str = ""
    if main_resource_modules:
        main_resource_entries = [
            '.process(".deps/{}/Resources")'.format(module)
            for module in main_resource_modules
        ]
        main_resources_str = "            resources: [{}],".format(", ".join(main_resource_entries))

    lines.extend([
        "        .target(",
        '            name: "{name}",'.format(name = normalized_name),
        "            dependencies: [{deps}],".format(deps = deps_str),
            '            path: "{path}",'.format(path = main_target_path),
        "            exclude: [{excludes}]".format(excludes = exclude_str),
    ])

    if main_resources_str:
        lines.append(main_resources_str)

    lines.extend([
        "        ),",
        "    ]",
        ")",
    ])

    return "\n".join(lines)
