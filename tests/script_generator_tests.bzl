# Copyright 2025 Jeff Hodsdon
# SPDX-License-Identifier: Apache-2.0

"""Unit tests for script_generator.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//internal:script_generator.bzl",
    "generate_base_script",
    "generate_copy_objc_module_script_from_paths",
    "generate_copy_xcframework_script_from_paths",
    "generate_copy_resources_script_from_paths",
    "generate_copy_sources_script_from_paths",
    "generate_package_write_script",
)

# =============================================================================
# Test: generate_base_script
# =============================================================================

def _base_script_test_impl(ctx):
    env = unittest.begin(ctx)

    result = generate_base_script("MyApp/Views")
    script = "\n".join(result)

    # Check shebang and set -e
    asserts.true(env, "#!/bin/bash" in script)
    asserts.true(env, "set -e" in script)

    # Check workspace directory check
    asserts.true(env, "BUILD_WORKSPACE_DIRECTORY" in script)

    # Check package dir setup
    asserts.true(env, 'PACKAGE_DIR="$BUILD_WORKSPACE_DIRECTORY/MyApp/Views"' in script)
    asserts.true(env, 'DEPS_DIR="$PACKAGE_DIR/.deps"' in script)

    # Check cleanup
    asserts.true(env, 'rm -rf "$DEPS_DIR"' in script)
    asserts.true(env, 'mkdir -p "$DEPS_DIR"' in script)

    return unittest.end(env)

_base_script_test = unittest.make(_base_script_test_impl)

# =============================================================================
# Test: generate_copy_sources_script_from_paths
# =============================================================================

def _copy_sources_test_impl(ctx):
    env = unittest.begin(ctx)

    result = generate_copy_sources_script_from_paths({
        "Core": ["path/to/Core.swift", "path/to/Utils.swift"],
        "Network": ["network/API.swift"],
    })
    script = "\n".join(result)

    # Check module directories are created
    asserts.true(env, 'mkdir -p "$DEPS_DIR/Core"' in script)
    asserts.true(env, 'mkdir -p "$DEPS_DIR/Network"' in script)

    # Check files are copied
    asserts.true(env, 'cp "$RUNFILES_DIR/_main/path/to/Core.swift" "$DEPS_DIR/Core/"' in script)
    asserts.true(env, 'cp "$RUNFILES_DIR/_main/path/to/Utils.swift" "$DEPS_DIR/Core/"' in script)
    asserts.true(env, 'cp "$RUNFILES_DIR/_main/network/API.swift" "$DEPS_DIR/Network/"' in script)

    return unittest.end(env)

_copy_sources_test = unittest.make(_copy_sources_test_impl)

# =============================================================================
# Test: generate_copy_sources_script_from_paths empty
# =============================================================================

def _copy_sources_empty_test_impl(ctx):
    env = unittest.begin(ctx)

    result = generate_copy_sources_script_from_paths({})

    asserts.equals(env, [], result)

    return unittest.end(env)

_copy_sources_empty_test = unittest.make(_copy_sources_empty_test_impl)

# =============================================================================
# Test: generate_copy_resources_script_from_paths
# =============================================================================

def _copy_resources_test_impl(ctx):
    env = unittest.begin(ctx)

    result = generate_copy_resources_script_from_paths({
        "Resources": {
            "resources": ["res/colors.json", "res/icon.png"],
            "generated_source": "Resources.swift",
        },
    })
    script = "\n".join(result)

    # Check Resources directory structure
    asserts.true(env, 'mkdir -p "$DEPS_DIR/Resources/Resources"' in script)

    # Check files are copied to Resources subdirectory
    asserts.true(env, 'cp -R "$RUNFILES_DIR/_main/res/colors.json" "$DEPS_DIR/Resources/Resources/"' in script)
    asserts.true(env, 'cp -R "$RUNFILES_DIR/_main/res/icon.png" "$DEPS_DIR/Resources/Resources/"' in script)

    # Check generated source is copied to module root
    asserts.true(env, 'cp "$RUNFILES_DIR/_main/Resources.swift" "$DEPS_DIR/Resources/"' in script)

    return unittest.end(env)

_copy_resources_test = unittest.make(_copy_resources_test_impl)

# =============================================================================
# Test: generate_copy_resources_script_from_paths without generated_source
# =============================================================================

def _copy_resources_no_source_test_impl(ctx):
    env = unittest.begin(ctx)

    # Test with generated_source = None (fallback case)
    result = generate_copy_resources_script_from_paths({
        "Resources": {
            "resources": ["fonts/Font.ttf"],
            "generated_source": None,
        },
    })
    script = "\n".join(result)

    # Check resources are still copied
    asserts.true(env, 'mkdir -p "$DEPS_DIR/Resources/Resources"' in script)
    asserts.true(env, 'cp -R "$RUNFILES_DIR/_main/fonts/Font.ttf" "$DEPS_DIR/Resources/Resources/"' in script)

    # No generated source copy should be present
    asserts.false(env, "Resources.swift" in script)

    return unittest.end(env)

_copy_resources_no_source_test = unittest.make(_copy_resources_no_source_test_impl)

def _copy_resources_with_owner_test_impl(ctx):
    env = unittest.begin(ctx)

    result = generate_copy_resources_script_from_paths(
        {
            "AsphaltAlohaResources": {
                "resources": ["res/colors.json"],
                "generated_source": None,
            },
        },
        main_module_name = "AlohaUIViews",
        dep_modules = ["AsphaltAloha", "AlohaAssets"],
    )
    script = "\n".join(result)

    asserts.true(env, 'mkdir -p "$DEPS_DIR/AsphaltAloha/AsphaltAlohaResources/Resources"' in script)
    asserts.true(env, 'cp -R "$RUNFILES_DIR/_main/res/colors.json" "$DEPS_DIR/AsphaltAloha/AsphaltAlohaResources/Resources/"' in script)

    return unittest.end(env)

_copy_resources_with_owner_test = unittest.make(_copy_resources_with_owner_test_impl)

def _copy_resources_skips_info_plist_test_impl(ctx):
    env = unittest.begin(ctx)

    result = generate_copy_resources_script_from_paths({
        "BundleResources": {
            "resources": ["res/Info.plist", "res/colors.json"],
            "generated_source": None,
        },
    })
    script = "\n".join(result)

    asserts.false(env, 'Info.plist" "$DEPS_DIR/BundleResources/Resources/"' in script)
    asserts.true(env, 'cp -R "$RUNFILES_DIR/_main/res/colors.json" "$DEPS_DIR/BundleResources/Resources/"' in script)

    return unittest.end(env)

_copy_resources_skips_info_plist_test = unittest.make(_copy_resources_skips_info_plist_test_impl)

def _copy_resources_preserves_special_dirs_test_impl(ctx):
    env = unittest.begin(ctx)

    result = generate_copy_resources_script_from_paths({
        "BundleResources": {
            "resources": [
                "res/Assets.xcassets/Contents.json",
                "res/Assets.xcassets/AppIcon.appiconset/icon-1024.png",
                "res/en.lproj/Localizable.strings",
                "res/en.lproj/InfoPlist.strings",
            ],
            "generated_source": None,
        },
    })

    xcassets_count = 0
    lproj_count = 0
    for line in result:
        if 'cp -R "$RUNFILES_DIR/_main/res/Assets.xcassets" "$DEPS_DIR/BundleResources/Resources/"' == line:
            xcassets_count += 1
        if 'cp -R "$RUNFILES_DIR/_main/res/en.lproj" "$DEPS_DIR/BundleResources/Resources/"' == line:
            lproj_count += 1

    asserts.equals(env, 1, xcassets_count)
    asserts.equals(env, 1, lproj_count)

    return unittest.end(env)

_copy_resources_preserves_special_dirs_test = unittest.make(_copy_resources_preserves_special_dirs_test_impl)

def _copy_resources_skips_bundle_entries_test_impl(ctx):
    env = unittest.begin(ctx)

    result = generate_copy_resources_script_from_paths({
        "BundleResources": {
            "resources": [
                "res/MyFeature.bundle",
                "res/MyFeature.bundle/Info.plist",
                "res/colors.json",
            ],
            "generated_source": None,
        },
    })
    script = "\n".join(result)

    asserts.false(env, "MyFeature.bundle" in script)
    asserts.true(env, 'cp -R "$RUNFILES_DIR/_main/res/colors.json" "$DEPS_DIR/BundleResources/Resources/"' in script)

    return unittest.end(env)

_copy_resources_skips_bundle_entries_test = unittest.make(_copy_resources_skips_bundle_entries_test_impl)

def _copy_resources_bundle_only_module_skipped_test_impl(ctx):
    env = unittest.begin(ctx)

    result = generate_copy_resources_script_from_paths({
        "BundleResources": {
            "resources": [
                "res/MyFeature.bundle",
                "res/MyFeature.bundle/Info.plist",
            ],
            "generated_source": None,
        },
    })

    asserts.equals(env, [], result)

    return unittest.end(env)

_copy_resources_bundle_only_module_skipped_test = unittest.make(_copy_resources_bundle_only_module_skipped_test_impl)

def _copy_xcframeworks_test_impl(ctx):
    env = unittest.begin(ctx)

    result = generate_copy_xcframework_script_from_paths({
        "TrueTime": "Frameworks/TrueTime.xcframework",
        "GRDB": "third_party/GRDB.xcframework",
        "AppsFlyerLib": "../rules_swift_package_manager++swift_deps+swiftpkg_appsflyerframework/remote/archive/AppsFlyerLib-Static-SPM.xcframework",
    })
    script = "\n".join(result)

    asserts.true(env, 'mkdir -p "$DEPS_DIR/TrueTime"' in script)
    asserts.true(env, 'SRC_XCFRAMEWORK="$BUILD_WORKSPACE_DIRECTORY/Frameworks/TrueTime.xcframework"' in script)
    asserts.true(env, 'if [ ! -d "$SRC_XCFRAMEWORK" ]; then SRC_XCFRAMEWORK="$RUNFILES_DIR/_main/Frameworks/TrueTime.xcframework"; fi' in script)
    asserts.true(env, 'if [ ! -d "$SRC_XCFRAMEWORK" ]; then SRC_XCFRAMEWORK="$RUNFILES_DIR/Frameworks/TrueTime.xcframework"; fi' in script)
    asserts.true(env, 'if [ ! -d "$SRC_XCFRAMEWORK" ]; then SRC_XCFRAMEWORK="$RUNFILES_DIR/_main/external/Frameworks/TrueTime.xcframework"; fi' in script)
    asserts.true(env, 'if [ ! -d "$SRC_XCFRAMEWORK" ]; then SRC_XCFRAMEWORK="$RUNFILES_DIR/external/Frameworks/TrueTime.xcframework"; fi' in script)
    asserts.true(env, '  _LINK="$(readlink "$SRC_XCFRAMEWORK/Info.plist" 2>/dev/null || true)"' in script)
    asserts.true(env, 'echo "Using XCFramework source for TrueTime: $SRC_XCFRAMEWORK"' in script)
    asserts.true(env, 'rm -rf "$DEPS_DIR/TrueTime/TrueTime.xcframework" && ditto "$SRC_XCFRAMEWORK" "$DEPS_DIR/TrueTime/TrueTime.xcframework"' in script)
    asserts.true(env, 'mkdir -p "$DEPS_DIR/GRDB"' in script)
    asserts.true(env, 'SRC_XCFRAMEWORK="$BUILD_WORKSPACE_DIRECTORY/third_party/GRDB.xcframework"' in script)
    asserts.true(env, 'if [ ! -d "$SRC_XCFRAMEWORK" ]; then SRC_XCFRAMEWORK="$RUNFILES_DIR/_main/third_party/GRDB.xcframework"; fi' in script)
    asserts.true(env, 'if [ ! -d "$SRC_XCFRAMEWORK" ]; then SRC_XCFRAMEWORK="$RUNFILES_DIR/third_party/GRDB.xcframework"; fi' in script)
    asserts.true(env, 'if [ ! -d "$SRC_XCFRAMEWORK" ]; then SRC_XCFRAMEWORK="$RUNFILES_DIR/_main/external/third_party/GRDB.xcframework"; fi' in script)
    asserts.true(env, 'if [ ! -d "$SRC_XCFRAMEWORK" ]; then SRC_XCFRAMEWORK="$RUNFILES_DIR/external/third_party/GRDB.xcframework"; fi' in script)
    asserts.true(env, '  _LINK="$(readlink "$SRC_XCFRAMEWORK/Info.plist" 2>/dev/null || true)"' in script)
    asserts.true(env, 'echo "Using XCFramework source for GRDB: $SRC_XCFRAMEWORK"' in script)
    asserts.true(env, 'rm -rf "$DEPS_DIR/GRDB/GRDB.xcframework" && ditto "$SRC_XCFRAMEWORK" "$DEPS_DIR/GRDB/GRDB.xcframework"' in script)

    # External xcframework with ../ prefix (bzlmod SPM deps)
    asserts.true(env, 'mkdir -p "$DEPS_DIR/AppsFlyerLib"' in script)
    asserts.true(env, 'if [ ! -d "$SRC_XCFRAMEWORK" ]; then SRC_XCFRAMEWORK="$RUNFILES_DIR/rules_swift_package_manager++swift_deps+swiftpkg_appsflyerframework/remote/archive/AppsFlyerLib-Static-SPM.xcframework"; fi' in script)
    asserts.true(env, 'rm -rf "$DEPS_DIR/AppsFlyerLib/AppsFlyerLib.xcframework" && ditto "$SRC_XCFRAMEWORK" "$DEPS_DIR/AppsFlyerLib/AppsFlyerLib.xcframework"' in script)

    return unittest.end(env)

_copy_xcframeworks_test = unittest.make(_copy_xcframeworks_test_impl)

def _copy_objc_modules_with_private_headers_test_impl(ctx):
    env = unittest.begin(ctx)

    result = generate_copy_objc_module_script_from_paths({
        "ObjCBridge": {
            "srcs": ["objc/SystemBridge.m"],
            "hdrs": ["objc/PublicHeader.h"],
            "private_hdrs": ["objc/private/PrivateHeader.h", "objc/minizip/mz_compat.h"],
        },
        "SSZipArchive": {
            "srcs": ["Pods/SSZipArchive/SSZipArchive/SSZipArchive.m"],
            "hdrs": ["Pods/SSZipArchive/SSZipArchive/SSZipArchive.h"],
            "private_hdrs": ["Pods/SSZipArchive/SSZipArchive/minizip/mz_compat.h"],
        },
    })
    script = "\n".join(result)

    asserts.true(env, 'cp "$RUNFILES_DIR/_main/objc/SystemBridge.m" "$DEPS_DIR/ObjCBridge/"' in script)
    asserts.true(env, 'cp "$RUNFILES_DIR/_main/objc/private/PrivateHeader.h" "$DEPS_DIR/ObjCBridge/PrivateHeader.h"' in script)
    asserts.true(env, 'cp "$RUNFILES_DIR/_main/objc/minizip/mz_compat.h" "$DEPS_DIR/ObjCBridge/mz_compat.h"' in script)
    asserts.true(env, 'cp "$RUNFILES_DIR/_main/objc/PublicHeader.h" "$DEPS_DIR/ObjCBridge/include/"' in script)

    asserts.true(env, 'mkdir -p "$DEPS_DIR/SSZipArchive/$(dirname "minizip/mz_compat.h")"' in script)
    asserts.true(env, 'cp "$RUNFILES_DIR/_main/Pods/SSZipArchive/SSZipArchive/minizip/mz_compat.h" "$DEPS_DIR/SSZipArchive/minizip/mz_compat.h"' in script)

    return unittest.end(env)

_copy_objc_modules_with_private_headers_test = unittest.make(_copy_objc_modules_with_private_headers_test_impl)

# =============================================================================
# Test: generate_package_write_script
# =============================================================================

def _package_write_script_test_impl(ctx):
    env = unittest.begin(ctx)

    package_content = """// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Test")"""

    result = generate_package_write_script(package_content)
    script = "\n".join(result)

    # Check heredoc structure
    asserts.true(env, 'cat > "$PACKAGE_DIR/Package.swift"' in script)
    asserts.true(env, "PACKAGE_EOF" in script)

    # Check content is included
    asserts.true(env, package_content in script)

    # Check success message
    asserts.true(env, "Preview package generated successfully" in script)

    return unittest.end(env)

_package_write_script_test = unittest.make(_package_write_script_test_impl)

# =============================================================================
# Test suite
# =============================================================================

def script_generator_test_suite(name):
    """Create the test suite for script_generator.bzl.

    Args:
        name: The name of the test suite
    """
    unittest.suite(
        name,
        _base_script_test,
        _copy_sources_test,
        _copy_sources_empty_test,
        _copy_resources_test,
        _copy_resources_no_source_test,
        _copy_resources_with_owner_test,
        _copy_resources_skips_info_plist_test,
        _copy_resources_preserves_special_dirs_test,
        _copy_resources_skips_bundle_entries_test,
        _copy_resources_bundle_only_module_skipped_test,
        _copy_xcframeworks_test,
        _copy_objc_modules_with_private_headers_test,
        _package_write_script_test,
    )
