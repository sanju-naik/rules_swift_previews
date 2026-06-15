# Copyright 2025 Jeff Hodsdon
# SPDX-License-Identifier: Apache-2.0

"""Unit tests for package_generator.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//internal:package_generator.bzl", "generate_package_swift")

# =============================================================================
# Test: Basic package generation
# =============================================================================

def _basic_package_test_impl(ctx):
    env = unittest.begin(ctx)

    result = generate_package_swift(
        name = "MyApp",
        dep_modules = [],
        resource_modules = [],
    )

    # Check header
    asserts.true(env, "// swift-tools-version: 6.0" in result)
    asserts.true(env, 'name: "MyApp"' in result)
    asserts.true(env, '.iOS("18.0")' in result)

    # Check main target structure
    asserts.true(env, ".target(" in result)
    asserts.true(env, 'path: "."' in result)

    # Default exclude list (users add more via extra_excludes)
    asserts.true(env, '"BUILD.bazel"' in result)
    asserts.true(env, '".deps"' in result)
    asserts.true(env, '"Package.swift"' in result)
    asserts.true(env, '"MODULE.bazel"' in result)

    return unittest.end(env)

_basic_package_test = unittest.make(_basic_package_test_impl)

# =============================================================================
# Test: Package with dependencies
# =============================================================================

def _package_with_deps_test_impl(ctx):
    env = unittest.begin(ctx)

    result = generate_package_swift(
        name = "Views",
        dep_modules = ["DesignSystem", "Theme"],
        resource_modules = [],
        module_deps = {
            "Theme": ["DesignSystem"],
        },
    )

    # Check dependency targets are created
    asserts.true(env, 'name: "DesignSystem"' in result)
    asserts.true(env, 'name: "Theme"' in result)
    asserts.true(env, 'path: ".deps/DesignSystem"' in result)
    asserts.true(env, 'path: ".deps/Theme"' in result)

    # Check Theme has DesignSystem as dependency
    asserts.true(env, 'dependencies: ["DesignSystem"]' in result)

    # Check main target has both deps
    asserts.true(env, 'dependencies: ["DesignSystem", "Theme"]' in result)

    return unittest.end(env)

_package_with_deps_test = unittest.make(_package_with_deps_test_impl)

# =============================================================================
# Test: Package with resource modules
# =============================================================================

def _package_with_resources_test_impl(ctx):
    env = unittest.begin(ctx)

    result = generate_package_swift(
        name = "Views",
        dep_modules = ["Core"],
        resource_modules = ["Resources"],
    )

    # Check resource target has correct structure
    asserts.true(env, 'name: "Resources"' in result)
    asserts.true(env, 'path: ".deps/Resources"' in result)
    asserts.true(env, 'resources: [.process("Resources")]' in result)

    # Check main target includes resource module
    asserts.true(env, '"Resources"' in result)

    return unittest.end(env)

_package_with_resources_test = unittest.make(_package_with_resources_test_impl)

# =============================================================================
# Test: Custom platform versions
# =============================================================================

def _custom_platforms_test_impl(ctx):
    env = unittest.begin(ctx)

    result = generate_package_swift(
        name = "MyLib",
        dep_modules = [],
        resource_modules = [],
        ios_version = "16",
        macos_version = "14",
        tvos_version = "",
        watchos_version = "",
        visionos_version = "1",
    )

    asserts.true(env, '.iOS("16.0")' in result)
    asserts.true(env, '.macOS("14.0")' in result)
    asserts.true(env, '.visionOS("1.0")' in result)
    asserts.false(env, ".tvOS" in result)
    asserts.false(env, ".watchOS" in result)

    return unittest.end(env)

_custom_platforms_test = unittest.make(_custom_platforms_test_impl)

# =============================================================================
# Test: Resource modules filtered from dep_modules
# =============================================================================

def _resource_filtering_test_impl(ctx):
    env = unittest.begin(ctx)

    # If a module is in both dep_modules and resource_modules,
    # it should only appear as a resource module
    result = generate_package_swift(
        name = "Views",
        dep_modules = ["Core", "Resources"],
        resource_modules = ["Resources"],
    )

    # Count occurrences of target definitions
    # Resources should appear once (as resource target), not twice
    lines = result.split("\n")
    resources_target_count = 0
    for line in lines:
        if 'name: "Resources"' in line:
            resources_target_count += 1

    asserts.equals(env, 1, resources_target_count)

    return unittest.end(env)

_resource_filtering_test = unittest.make(_resource_filtering_test_impl)

# =============================================================================
# Test: Module dependencies exclude self-references
# =============================================================================

def _no_self_deps_test_impl(ctx):
    env = unittest.begin(ctx)

    result = generate_package_swift(
        name = "Views",
        dep_modules = ["DesignSystem"],
        resource_modules = [],
        module_deps = {
            "DesignSystem": ["DesignSystem"],  # Self-reference should be filtered
        },
    )

    # DesignSystem should have empty deps, not reference itself
    asserts.true(env, 'name: "DesignSystem"' in result)
    asserts.true(env, 'dependencies: []' in result)

    return unittest.end(env)

_no_self_deps_test = unittest.make(_no_self_deps_test_impl)

# =============================================================================
# Test: Module dependencies filter to available modules only
# =============================================================================

def _deps_filter_unavailable_test_impl(ctx):
    env = unittest.begin(ctx)

    result = generate_package_swift(
        name = "Views",
        dep_modules = ["Core"],
        resource_modules = [],
        module_deps = {
            "Core": ["NonExistent", "AlsoNotThere"],
        },
    )

    # Core should have empty deps since referenced modules don't exist
    asserts.true(env, 'name: "Core"' in result)
    asserts.true(env, 'dependencies: []' in result)

    return unittest.end(env)

_deps_filter_unavailable_test = unittest.make(_deps_filter_unavailable_test_impl)

# =============================================================================
# Test: Strip trailing Views suffix from package name
# =============================================================================

def _strip_views_suffix_test_impl(ctx):
    env = unittest.begin(ctx)

    result = generate_package_swift(
        name = "MyAppViews",
        dep_modules = [],
        resource_modules = [],
    )

    asserts.true(env, 'name: "MyApp"' in result)
    asserts.true(env, '.library(name: "MyApp", targets: ["MyApp"])' in result)
    asserts.false(env, 'name: "MyAppViews"' in result)

    return unittest.end(env)

_strip_views_suffix_test = unittest.make(_strip_views_suffix_test_impl)

# =============================================================================
# Test: Main module resources are folded into main target
# =============================================================================

def _main_resources_folded_test_impl(ctx):
    env = unittest.begin(ctx)

    result = generate_package_swift(
        name = "AsphaltAlohaViews",
        dep_modules = ["Core", "AsphaltAlohaResources", "SharedResources"],
        resource_modules = ["AsphaltAlohaResources", "SharedResources"],
    )

    asserts.true(env, 'name: "AsphaltAloha"' in result)
    asserts.true(env, 'resources: [.process(".deps/AsphaltAlohaResources/Resources")]' in result)

    # Still emitted as standalone target
    asserts.true(env, 'path: ".deps/SharedResources"' in result)

    # Main resource module is not emitted as separate target
    asserts.false(env, 'path: ".deps/AsphaltAlohaResources"' in result)

    return unittest.end(env)

_main_resources_folded_test = unittest.make(_main_resources_folded_test_impl)

# =============================================================================
# Test: Dependency module resources are folded into dependency target
# =============================================================================

def _dependency_resources_folded_test_impl(ctx):
    env = unittest.begin(ctx)

    result = generate_package_swift(
        name = "AlohaUIViews",
        dep_modules = ["AsphaltAloha", "AsphaltAlohaResources", "AlohaAssets", "AlohaAssetsResources"],
        resource_modules = ["AsphaltAlohaResources", "AlohaAssetsResources"],
        module_deps = {
            "AsphaltAloha": ["AlohaAssets", "AlohaAssetsResources", "AsphaltAlohaResources"],
            "AlohaAssets": ["AlohaAssetsResources"],
        },
    )

    # Resource modules should be folded and not emitted as standalone targets
    asserts.false(env, 'path: ".deps/AsphaltAlohaResources"' in result)
    asserts.false(env, 'path: ".deps/AlohaAssetsResources"' in result)

    # Dependency targets should include folded resources
    asserts.true(env, 'name: "AsphaltAloha"' in result)
    asserts.true(env, '.process("AsphaltAlohaResources/Resources")' in result)
    asserts.true(env, 'name: "AlohaAssets"' in result)
    asserts.true(env, '.process("AlohaAssetsResources/Resources")' in result)

    # Main target should no longer depend directly on folded resource modules
    asserts.false(env, '"AsphaltAlohaResources"],' in result)
    asserts.false(env, '"AlohaAssetsResources"],' in result)

    return unittest.end(env)

_dependency_resources_folded_test = unittest.make(_dependency_resources_folded_test_impl)

def _main_target_path_test_impl(ctx):
    env = unittest.begin(ctx)

    result = generate_package_swift(
        name = "CrossSellWidgetViews",
        dep_modules = [],
        resource_modules = [],
        main_target_path = "Sources/CrossSellWidget",
    )

    asserts.true(env, 'name: "CrossSellWidget"' in result)
    asserts.true(env, 'path: "Sources/CrossSellWidget"' in result)

    return unittest.end(env)

_main_target_path_test = unittest.make(_main_target_path_test_impl)

# =============================================================================
# Test: scattered main sources emit path "." + explicit sources list
# =============================================================================

def _main_target_scattered_sources_test_impl(ctx):
    env = unittest.begin(ctx)

    result = generate_package_swift(
        name = "GoFoodWidgetViews",
        dep_modules = [],
        resource_modules = [],
        main_target_path = ".",
        main_target_sources = [
            "Analytics/FoodWidgetAnalytics/EventName.swift",
            "GoFoodWidget/Order/OrderStatusView.swift",
            "Models/FoodCommonModels/FoodError.swift",
        ],
    )

    asserts.true(env, 'path: ".",' in result)
    asserts.true(
        env,
        'sources: ["Analytics/FoodWidgetAnalytics/EventName.swift", ' +
        '"GoFoodWidget/Order/OrderStatusView.swift", ' +
        '"Models/FoodCommonModels/FoodError.swift"]' in result,
    )

    # `exclude` is still emitted alongside `sources`: SwiftPM auto-discovers
    # resources across the whole path regardless of the sources list, so exclude
    # is required to keep sibling resources out.
    asserts.true(env, "exclude:" in result)

    return unittest.end(env)

_main_target_scattered_sources_test = unittest.make(_main_target_scattered_sources_test_impl)

# =============================================================================
# Test: extra_excludes are relativized to the main target path; globs dropped
# =============================================================================

def _extra_excludes_relativized_test_impl(ctx):
    env = unittest.begin(ctx)

    result = generate_package_swift(
        name = "GoMartNewViews",
        dep_modules = [],
        resource_modules = [],
        main_target_path = "GoMartNew/src",
        extra_excludes = [
            "GoMartNew/src/Classes/Common/Models/Brand.swift",
            "GoMartNew/src/**/*.{plist}",
            "AlreadyRelative.swift",
        ],
    )

    # Package-relative entry is stripped to target-relative.
    asserts.true(env, '"Classes/Common/Models/Brand.swift"' in result)
    # The un-prefixed entry passes through untouched.
    asserts.true(env, '"AlreadyRelative.swift"' in result)
    # Glob entries cannot be expressed in SwiftPM exclude and are dropped.
    asserts.false(env, "plist" in result)
    # The un-stripped package-relative form must not leak through.
    asserts.false(env, '"GoMartNew/src/Classes/Common/Models/Brand.swift"' in result)

    return unittest.end(env)

_extra_excludes_relativized_test = unittest.make(_extra_excludes_relativized_test_impl)

# =============================================================================
# Test: XCFramework dependencies generate binary targets
# =============================================================================

def _xcframework_binary_targets_test_impl(ctx):
    env = unittest.begin(ctx)

    result = generate_package_swift(
        name = "AlohaUIViews",
        dep_modules = ["AsphaltAloha"],
        resource_modules = [],
        module_deps = {
            "AsphaltAloha": ["TrueTime", "GRDB"],
        },
        xcframework_modules = ["TrueTime", "GRDB"],
    )

    asserts.true(env, '.binaryTarget(' in result)
    asserts.true(env, 'name: "TrueTime"' in result)
    asserts.true(env, 'path: ".deps/TrueTime/TrueTime.xcframework"' in result)
    asserts.true(env, 'name: "GRDB"' in result)
    asserts.true(env, 'path: ".deps/GRDB/GRDB.xcframework"' in result)

    # Swift target deps should include XCFramework binary targets
    asserts.true(env, 'name: "AsphaltAloha"' in result)
    asserts.true(env, 'dependencies: ["TrueTime", "GRDB"]' in result)

    return unittest.end(env)

_xcframework_binary_targets_test = unittest.make(_xcframework_binary_targets_test_impl)

# =============================================================================
# Test: exclude_modules drops targets/binaryTargets and strips dependencies
# =============================================================================

def _exclude_modules_test_impl(ctx):
    env = unittest.begin(ctx)

    result = generate_package_swift(
        name = "AppViews",
        dep_modules = ["FeatureKit", "CourierCommonClient"],
        resource_modules = [],
        module_deps = {
            "FeatureKit": ["CourierCommonClient"],
            "CourierCommonClient": ["CourierProtos"],
        },
        xcframework_modules = ["CourierProtos"],
        exclude_modules = ["CourierProtos"],
    )

    # No target or binaryTarget is emitted for the excluded module.
    asserts.false(env, 'name: "CourierProtos"' in result)
    asserts.false(env, '.deps/CourierProtos' in result)

    # The excluded module is stripped from every other target's dependencies.
    asserts.false(env, '"CourierProtos"' in result)

    # Non-excluded targets are still present and still wired together.
    asserts.true(env, 'name: "FeatureKit"' in result)
    asserts.true(env, 'name: "CourierCommonClient"' in result)
    asserts.true(env, 'dependencies: ["CourierCommonClient"]' in result)
    asserts.true(env, 'dependencies: []' in result)

    return unittest.end(env)

_exclude_modules_test = unittest.make(_exclude_modules_test_impl)

# =============================================================================
# Test suite
# =============================================================================

def package_generator_test_suite(name):
    """Create the test suite for package_generator.bzl.

    Args:
        name: The name of the test suite
    """
    unittest.suite(
        name,
        _basic_package_test,
        _package_with_deps_test,
        _package_with_resources_test,
        _custom_platforms_test,
        _resource_filtering_test,
        _no_self_deps_test,
        _deps_filter_unavailable_test,
        _strip_views_suffix_test,
        _main_resources_folded_test,
        _dependency_resources_folded_test,
        _main_target_path_test,
        _main_target_scattered_sources_test,
        _extra_excludes_relativized_test,
        _xcframework_binary_targets_test,
        _exclude_modules_test,
    )
