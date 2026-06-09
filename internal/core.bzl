# Copyright 2025 Jeff Hodsdon
# SPDX-License-Identifier: Apache-2.0

"""Core implementation for rules_swift_previews.

Uses convention-based resource detection (checks rule kind) rather than
importing SwiftResourceInfo. Delegates source collection to language-specific
modules for Swift, C/C++, and Objective-C.
"""

load("//internal:cc_collector.bzl", "collect_cc_sources")
load("//internal:objc_collector.bzl", "collect_objc_sources")
load("//internal:package_generator.bzl", "generate_package_swift")
load("//internal:providers.bzl", "SourceFilesInfo")
load(
    "//internal:script_generator.bzl",
    "generate_base_script",
    "generate_copy_cc_module_script",
    "generate_copy_xcframework_script",
    "generate_copy_objc_module_script",
    "generate_copy_resources_script",
    "generate_copy_sources_script",
    "generate_package_write_script",
)
load("//internal:swift_collector.bzl", "collect_apple_bundle_resources", "collect_swift_resources", "collect_swift_sources")

def _is_skipped_resource_file(path):
    if path.endswith("/Info.plist") or path == "Info.plist":
        return True
    if path.endswith(".bundle") or ".bundle/" in path:
        return True
    if path.endswith(".xcframework") or ".xcframework/" in path:
        return True
    return False

def _normalize_module_name(name):
    if name.endswith(".rspm_objc"):
        name = name[:-len(".rspm_objc")]
    elif name.endswith(".rspm"):
        name = name[:-len(".rspm")]
    return name

def _xcframework_root(path):
    marker = ".xcframework"
    idx = path.find(marker)
    for _i in range(10):
        if idx == -1:
            return None
        end = idx + len(marker)
        if end < len(path) and path[end:end + 4] == ".zip":
            idx = path.find(marker, end)
        else:
            return path[:end]
    return None

def _xcframework_name_from_root(root):
    base = root.split("/")[-1]
    if base.endswith(".xcframework"):
        name = base[:-len(".xcframework")]
        if name.endswith("-Static-SPM"):
            return name[:-len("-Static-SPM")]
        if name.endswith("-Dynamic-SPM"):
            return name[:-len("-Dynamic-SPM")]
        return name
    return base

def _common_dir(paths):
    if not paths:
        return "."

    common_parts = paths[0].split("/")
    for path in paths[1:]:
        parts = path.split("/")

        max_len = len(common_parts)
        if len(parts) < max_len:
            max_len = len(parts)

        new_common_parts = []
        for i in range(max_len):
            if common_parts[i] == parts[i]:
                new_common_parts.append(common_parts[i])
            else:
                break

        common_parts = new_common_parts
        if not common_parts:
            return "."

    return "/".join(common_parts) if common_parts else "."

def _compute_main_target_path(main_sources, package_dir):
    if not main_sources:
        return "."

    package_prefix = package_dir + "/"
    rel_dirs = []
    for src in main_sources:
        short_path = src.short_path
        rel_path = short_path[len(package_prefix):] if short_path.startswith(package_prefix) else short_path
        if "/" not in rel_path:
            return "."
        rel_dirs.append(rel_path.rsplit("/", 1)[0])

    return _common_dir(rel_dirs)

def _collect_xcframework_modules_from_files(files):
    xcframework_name_to_files = {}
    for f in files:
        root = _xcframework_root(f.short_path)
        if not root:
            continue
        xcframework_name = _xcframework_name_from_root(root)
        if xcframework_name not in xcframework_name_to_files:
            xcframework_name_to_files[xcframework_name] = []
        xcframework_name_to_files[xcframework_name].append(f)
    return xcframework_name_to_files

def _merge_xcframework_maps(dst, src):
    for name, files in src.items():
        if name not in dst:
            dst[name] = []
        dst[name].extend(files)

def _collect_xcframework_modules_from_rule_attrs(ctx):
    xcframework_name_to_files = {}
    candidate_attrs = [
        "actual",
        "data",
        "deps",
        "srcs",
        "framework_imports",
        "frameworks",
        "xcframework_imports",
        "libraries",
    ]

    for attr_name in candidate_attrs:
        if not hasattr(ctx.rule.attr, attr_name):
            continue

        attr_value = getattr(ctx.rule.attr, attr_name)
        items = attr_value if type(attr_value) == "list" else ([attr_value] if attr_value != None else [])
        for item in items:
            if hasattr(item, "files"):
                item_xcframeworks = _collect_xcframework_modules_from_files(item.files.to_list())
                _merge_xcframework_maps(xcframework_name_to_files, item_xcframeworks)

    return xcframework_name_to_files

def _add_xcframeworks_from_dep_files(dep, direct_dep_modules, xcframework_modules):
    if not hasattr(dep, "files"):
        return

    xcframework_name_to_files = _collect_xcframework_modules_from_files(dep.files.to_list())
    for xcframework_name, xcframework_files in xcframework_name_to_files.items():
        if xcframework_name not in xcframework_modules:
            xcframework_modules[xcframework_name] = []
        xcframework_modules[xcframework_name].extend(xcframework_files)
        if xcframework_name not in direct_dep_modules:
            direct_dep_modules.append(xcframework_name)

def _merge_module_dep_lists(module_deps, module_name, new_deps):
    if module_name not in module_deps:
        module_deps[module_name] = list(new_deps)
        return

    existing = module_deps[module_name]
    seen = {d: True for d in existing}
    for dep in new_deps:
        if dep not in seen:
            seen[dep] = True
            existing.append(dep)

def _source_collector_aspect_impl(target, ctx):
    """Aspect that collects source files from library targets.

    Handles swift_library, cc_library, and objc_library targets.
    Resource modules are detected by convention (checking rule kind).
    """
    sources = []
    module_sources = {}
    resource_modules = {}
    module_deps = {}
    cc_modules = {}
    objc_modules = {}
    xcframework_modules = {}

    dep_targets = []
    if hasattr(ctx.rule.attr, "actual") and ctx.rule.attr.actual:
        dep_targets.append(ctx.rule.attr.actual)
    if hasattr(ctx.rule.attr, "deps"):
        dep_targets.extend(ctx.rule.attr.deps)
    if hasattr(ctx.rule.attr, "data"):
        dep_targets.extend(ctx.rule.attr.data)

    # Skip most external dependencies, but collect XCFrameworks and own Swift sources
    label = target.label
    if label.workspace_name != "" or label.package.startswith("external"):
        target_files = target.files.to_list() if hasattr(target, "files") else []
        external_xcframeworks = _collect_xcframework_modules_from_files(target_files)
        attr_xcframeworks = _collect_xcframework_modules_from_rule_attrs(ctx)
        _merge_xcframework_maps(external_xcframeworks, attr_xcframeworks)

        ext_module_sources = {}
        ext_module_deps = {}
        ext_cc_modules = {}
        ext_objc_modules = {}
        ext_sources = []
        ext_module_name = None
        swift_result = collect_swift_sources(ctx, target)
        if swift_result:
            ext_module_name, swift_sources = swift_result
            ext_module_name = _normalize_module_name(ext_module_name)
            ext_module_sources[ext_module_name] = swift_sources
            ext_sources = list(swift_sources)

        cc_result = collect_cc_sources(ctx, target)
        if cc_result:
            cc_name, cc_info = cc_result
            cc_name = _normalize_module_name(cc_name)
            ext_cc_modules[cc_name] = cc_info
            if not ext_module_name:
                ext_module_name = cc_name

        objc_result = collect_objc_sources(ctx, target)
        if objc_result:
            objc_name, objc_info = objc_result
            objc_name = _normalize_module_name(objc_name)
            ext_objc_modules[objc_name] = objc_info
            if not ext_module_name:
                ext_module_name = objc_name

        ext_direct_deps = []
        for dep in dep_targets:
            if SourceFilesInfo in dep:
                dep_info = dep[SourceFilesInfo]
                for name, srcs in dep_info.module_sources.items():
                    if name not in ext_module_sources:
                        ext_module_sources[name] = srcs
                        ext_sources.extend(srcs)
                    if name not in ext_direct_deps:
                        ext_direct_deps.append(name)
                for name, deps in dep_info.module_deps.items():
                    _merge_module_dep_lists(ext_module_deps, name, deps)
                for name, cc_info in dep_info.cc_modules.items():
                    if name not in ext_cc_modules:
                        ext_cc_modules[name] = cc_info
                    if name not in ext_direct_deps:
                        ext_direct_deps.append(name)
                for name, objc_info in dep_info.objc_modules.items():
                    if name not in ext_objc_modules:
                        ext_objc_modules[name] = objc_info
                    if name not in ext_direct_deps:
                        ext_direct_deps.append(name)
                _merge_xcframework_maps(external_xcframeworks, dep_info.xcframework_modules)
                for name in dep_info.xcframework_modules.keys():
                    if name not in ext_direct_deps:
                        ext_direct_deps.append(name)

        if ext_module_name and ext_direct_deps:
            ext_module_deps[ext_module_name] = ext_direct_deps

        return [SourceFilesInfo(
            sources = depset(ext_sources),
            module_sources = ext_module_sources,
            resource_modules = {},
            module_deps = ext_module_deps,
            cc_modules = ext_cc_modules,
            objc_modules = ext_objc_modules,
            xcframework_modules = external_xcframeworks,
        )]

    # Collect from this target using language-specific collectors
    swift_result = collect_swift_sources(ctx, target)
    if swift_result:
        module_name, swift_sources = swift_result
        module_name = _normalize_module_name(module_name)
        sources.extend(swift_sources)
        module_sources[module_name] = swift_sources

    resource_result = collect_swift_resources(ctx, target)
    if resource_result:
        module_name, resource_info = resource_result
        module_name = _normalize_module_name(module_name)
        resource_modules[module_name] = resource_info

    apple_bundle_result = collect_apple_bundle_resources(ctx, target)
    if apple_bundle_result:
        module_name, resource_info = apple_bundle_result
        module_name = _normalize_module_name(module_name)
        resource_modules[module_name] = resource_info

    cc_result = collect_cc_sources(ctx, target)
    if cc_result:
        module_name, cc_info = cc_result
        module_name = _normalize_module_name(module_name)
        cc_modules[module_name] = cc_info

    objc_result = collect_objc_sources(ctx, target)
    if objc_result:
        module_name, objc_info = objc_result
        module_name = _normalize_module_name(module_name)
        objc_modules[module_name] = objc_info

    target_files = target.files.to_list() if hasattr(target, "files") else []
    xcframework_name_to_files = _collect_xcframework_modules_from_files(target_files)
    attr_xcframework_name_to_files = _collect_xcframework_modules_from_rule_attrs(ctx)
    _merge_xcframework_maps(xcframework_name_to_files, attr_xcframework_name_to_files)
    for xcframework_name, xcframework_files in xcframework_name_to_files.items():
        xcframework_modules[xcframework_name] = xcframework_files

    # Get module name for dependency tracking
    module_name = None
    if hasattr(ctx.rule.attr, "module_name") and ctx.rule.attr.module_name:
        module_name = ctx.rule.attr.module_name
    elif hasattr(target, "label"):
        module_name = target.label.name
    if module_name:
        module_name = _normalize_module_name(module_name)

    # Track this module's direct dependencies
    direct_dep_modules = []

    for dep in dep_targets:
        if SourceFilesInfo in dep:
            dep_info = dep[SourceFilesInfo]

            for name in dep_info.module_sources.keys():
                if name not in direct_dep_modules:
                    direct_dep_modules.append(name)
            for name in dep_info.resource_modules.keys():
                if name not in direct_dep_modules:
                    direct_dep_modules.append(name)
            for name in dep_info.cc_modules.keys():
                if name not in direct_dep_modules:
                    direct_dep_modules.append(name)
            for name in dep_info.objc_modules.keys():
                if name not in direct_dep_modules:
                    direct_dep_modules.append(name)
            for name in dep_info.xcframework_modules.keys():
                if name not in direct_dep_modules:
                    direct_dep_modules.append(name)
        else:
            _add_xcframeworks_from_dep_files(dep, direct_dep_modules, xcframework_modules)

    if module_name and hasattr(ctx.rule.attr, "data"):
        data_files = []
        for data_dep in ctx.rule.attr.data:
            if SourceFilesInfo in data_dep:
                continue
            if hasattr(data_dep, "files"):
                data_dep_files = data_dep.files.to_list()
                data_files.extend(data_dep_files)

                xcframework_name_to_files = {}
                for f in data_dep_files:
                    root = _xcframework_root(f.short_path)
                    if not root:
                        continue
                    xcframework_name = _xcframework_name_from_root(root)
                    if xcframework_name not in xcframework_name_to_files:
                        xcframework_name_to_files[xcframework_name] = []
                    xcframework_name_to_files[xcframework_name].append(f)

                for xcframework_name, xcframework_files in xcframework_name_to_files.items():
                    if xcframework_name not in xcframework_modules:
                        xcframework_modules[xcframework_name] = []
                    xcframework_modules[xcframework_name].extend(xcframework_files)
                    if xcframework_name not in direct_dep_modules:
                        direct_dep_modules.append(xcframework_name)

        if data_files:
            seen = {}
            deduped_data_files = []
            for f in data_files:
                if f.path not in seen:
                    seen[f.path] = True
                    deduped_data_files.append(f)

            synthetic_resource_module = "{}Resources".format(module_name)
            resource_modules[synthetic_resource_module] = {
                "resources": deduped_data_files,
                "generated_source": None,
            }
            if synthetic_resource_module not in direct_dep_modules:
                direct_dep_modules.append(synthetic_resource_module)

    if module_name:
        module_deps[module_name] = direct_dep_modules

    # Collect from dependencies (transitive)
    for dep in dep_targets:
        if SourceFilesInfo in dep:
            dep_info = dep[SourceFilesInfo]
            sources.extend(dep_info.sources.to_list())
            for name, srcs in dep_info.module_sources.items():
                if name not in module_sources:
                    module_sources[name] = srcs
            for name, res in dep_info.resource_modules.items():
                if name not in resource_modules:
                    resource_modules[name] = res
            for name, deps in dep_info.module_deps.items():
                _merge_module_dep_lists(module_deps, name, deps)
            for name, cc_info in dep_info.cc_modules.items():
                if name not in cc_modules:
                    cc_modules[name] = cc_info
            for name, objc_info in dep_info.objc_modules.items():
                if name not in objc_modules:
                    objc_modules[name] = objc_info
            for name, xcframework_files in dep_info.xcframework_modules.items():
                # print("Found xcframework module '{}' in dep {}".format(name, dep.label))
                if name not in xcframework_modules:
                    xcframework_modules[name] = xcframework_files
        else:
            _add_xcframeworks_from_dep_files(dep, direct_dep_modules, xcframework_modules)

    return [SourceFilesInfo(
        sources = depset(sources),
        module_sources = module_sources,
        resource_modules = resource_modules,
        module_deps = module_deps,
        cc_modules = cc_modules,
        objc_modules = objc_modules,
        xcframework_modules = xcframework_modules,
    )]

source_collector_aspect = aspect(
    implementation = _source_collector_aspect_impl,
    attr_aspects = ["actual", "deps", "data"],
    doc = "Collects source files from swift_library, cc_library, and objc_library targets.",
)

def swift_previews_package_impl(ctx):
    """Implementation of the preview package generator rule.

    Exported for use by generated repository rules.

    Args:
        ctx: The rule context.

    Returns:
        A list containing DefaultInfo with the executable script and runfiles.
    """
    lib = ctx.attr.lib
    lib_module_name = lib.label.name

    dep_dirs = {}
    resource_modules = {}
    module_deps = {}
    cc_modules = {}
    objc_modules = {}
    all_sources = []
    all_resource_files = []
    all_cc_files = []
    all_objc_files = []
    xcframework_modules = {}
    all_xcframework_files = []
    main_module_sources = []

    if SourceFilesInfo in lib:
        info = lib[SourceFilesInfo]
        all_sources.extend(info.sources.to_list())

        # Collect Swift module sources
        for module_name, sources in info.module_sources.items():
            if module_name == lib_module_name:
                main_module_sources.extend(sources)
            if module_name == lib_module_name:
                continue
            if module_name not in dep_dirs:
                dep_dirs[module_name] = []
            dep_dirs[module_name].extend(sources)

        if not main_module_sources:
            dep_source_paths = {}
            for dep_sources in dep_dirs.values():
                for src in dep_sources:
                    dep_source_paths[src.path] = True
            main_module_sources = [
                src
                for src in all_sources
                if src.path.endswith(".swift") and src.path not in dep_source_paths
            ]

        for module_name, xcframework_files in info.xcframework_modules.items():
            root = None
            for f in xcframework_files:
                candidate = _xcframework_root(f.short_path)
                if candidate:
                    root = candidate
                    break
            if root and module_name not in xcframework_modules:
                xcframework_modules[module_name] = root
            all_xcframework_files.extend(xcframework_files)

        # Collect resource modules
        for module_name, res_info in info.resource_modules.items():
            for f in res_info.get("resources", []):
                root = _xcframework_root(f.short_path)
                if root:
                    xcframework_name = _xcframework_name_from_root(root)
                    if xcframework_name not in xcframework_modules:
                        xcframework_modules[xcframework_name] = root
                    all_xcframework_files.append(f)

            filtered_resources = [
                f
                for f in res_info.get("resources", [])
                if not _is_skipped_resource_file(f.short_path)
            ]
            generated_source = res_info.get("generated_source")

            if not filtered_resources and not generated_source:
                continue

            filtered_res_info = {
                "resources": filtered_resources,
                "generated_source": generated_source,
            }

            resource_modules[module_name] = filtered_res_info
            all_resource_files.extend(filtered_resources)
            if generated_source:
                all_resource_files.append(generated_source)

        # Collect module dependencies
        for module_name, deps in info.module_deps.items():
            if module_name != lib_module_name:
                module_deps[module_name] = deps

        # Collect C/C++ modules
        for module_name, cc_info in info.cc_modules.items():
            cc_modules[module_name] = cc_info
            all_cc_files.extend(cc_info.get("srcs", []))
            all_cc_files.extend(cc_info.get("hdrs", []))

        # Collect Objective-C modules
        for module_name, objc_info in info.objc_modules.items():
            objc_modules[module_name] = objc_info
            all_objc_files.extend(objc_info.get("srcs", []))
            all_objc_files.extend(objc_info.get("hdrs", []))
            all_objc_files.extend(objc_info.get("private_hdrs", []))

    # Build script
    script_lines = generate_base_script(ctx.attr.package_dir)

    # Copy Swift sources
    script_lines.extend(generate_copy_sources_script(dep_dirs))

    # Copy C/C++ modules (sources + headers)
    if cc_modules:
        script_lines.extend(generate_copy_cc_module_script(cc_modules))

    # Copy Objective-C modules (sources + headers)
    if objc_modules:
        script_lines.extend(generate_copy_objc_module_script(objc_modules))

    # Copy XCFramework dependencies
    if xcframework_modules:
        script_lines.extend(generate_copy_xcframework_script(xcframework_modules))

    # Handle resources if found
    if resource_modules:
        script_lines.extend(generate_copy_resources_script(
            resource_modules,
            main_module_name = lib_module_name,
            dep_modules = list(dep_dirs.keys()),
        ))

    package_swift = generate_package_swift(
        name = lib_module_name,
        dep_modules = list(dep_dirs.keys()),
        resource_modules = list(resource_modules.keys()),
        module_deps = module_deps,
        cc_modules = list(cc_modules.keys()),
        objc_modules = list(objc_modules.keys()),
        xcframework_modules = list(xcframework_modules.keys()),
        extra_excludes = ctx.attr.extra_excludes,
        main_target_path = _compute_main_target_path(main_module_sources, ctx.attr.package_dir),
        ios_version = ctx.attr.ios_version,
        macos_version = ctx.attr.macos_version,
        tvos_version = ctx.attr.tvos_version,
        watchos_version = ctx.attr.watchos_version,
        visionos_version = ctx.attr.visionos_version,
    )

    script_lines.extend(generate_package_write_script(package_swift))

    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(
        output = script,
        content = "\n".join(script_lines),
        is_executable = True,
    )

    # Collect runfiles
    seen_runfiles = {}
    runfiles_files = []
    for f in all_sources + all_resource_files + all_cc_files + all_objc_files + all_xcframework_files:
        if f.path not in seen_runfiles:
            seen_runfiles[f.path] = True
            runfiles_files.append(f)
    runfiles = ctx.runfiles(files = runfiles_files)

    return [DefaultInfo(
        executable = script,
        runfiles = runfiles,
    )]

# Base attributes shared by all rule variants
_BASE_ATTRS = {
    "lib": attr.label(
        mandatory = True,
        aspects = [source_collector_aspect],
        doc = "The swift_library target to generate previews for",
    ),
    "package_dir": attr.string(
        mandatory = True,
        doc = "Path to the package directory",
    ),
    "extra_excludes": attr.string_list(
        default = [],
        doc = "Additional directories/files to exclude from the main SPM target",
    ),
    "ios_version": attr.string(default = "15"),
    "macos_version": attr.string(default = ""),
    "tvos_version": attr.string(default = ""),
    "watchos_version": attr.string(default = ""),
    "visionos_version": attr.string(default = ""),
}

def create_swift_previews_rule(extra_attrs = {}):
    """Factory to create swift_previews_package rule variants.

    Args:
        extra_attrs: Additional attributes to add to the rule (e.g., _sr for SwiftResources)

    Returns:
        A rule that generates SPM Package.swift for Xcode SwiftUI previews.
    """
    attrs = dict(_BASE_ATTRS)
    attrs.update(extra_attrs)
    return rule(
        implementation = swift_previews_package_impl,
        attrs = attrs,
        executable = True,
        doc = "Generates an SPM Package.swift for Xcode SwiftUI previews.",
    )

def create_swift_previews_macro(rule_fn):
    """Factory to create swift_previews_package macro wrapper.

    Args:
        rule_fn: The rule function to wrap

    Returns:
        A macro that wraps the rule with native.package_name() for package_dir.
    """

    def swift_previews_package(
            name,
            lib,
            extra_excludes = [],
            ios_version = "18",
            macos_version = "",
            tvos_version = "",
            watchos_version = "",
            visionos_version = "",
            visibility = None):
        """Generate an SPM Package.swift for Xcode SwiftUI previews.

        Args:
            name: Target name (typically "previews")
            lib: The swift_library target to generate previews for
            extra_excludes: Additional directories/files to exclude from the main SPM target
            ios_version: iOS deployment target (default: "18")
            macos_version: macOS deployment target (empty to omit)
            tvos_version: tvOS deployment target (empty to omit)
            watchos_version: watchOS deployment target (empty to omit)
            visionos_version: visionOS deployment target (empty to omit)
            visibility: Bazel visibility
        """
        rule_fn(
            name = name,
            lib = lib,
            package_dir = native.package_name(),
            extra_excludes = extra_excludes,
            ios_version = ios_version,
            macos_version = macos_version,
            tvos_version = tvos_version,
            watchos_version = watchos_version,
            visionos_version = visionos_version,
            visibility = visibility,
        )

    return swift_previews_package

swift_previews_package_rule = create_swift_previews_rule()
swift_previews_package = create_swift_previews_macro(swift_previews_package_rule)
