# Copyright 2025 Jeff Hodsdon
# SPDX-License-Identifier: Apache-2.0

"""Shell script generation utilities for rules_swift_previews.

This module provides both pure string-based functions (for testability) and
wrapper functions that work with Bazel File objects.
"""

# =============================================================================
# Pure string functions (easily unit testable)
# =============================================================================

def generate_copy_sources_script_from_paths(dep_dirs):
    """Generate script lines to copy dependency sources to .deps/.

    Pure function that takes string paths instead of File objects.

    Args:
        dep_dirs: dict mapping module_name -> list of source short_paths (strings)

    Returns:
        List of shell script lines
    """
    lines = []
    for module_name, source_paths in dep_dirs.items():
        lines.append("# Copy {module} sources".format(module = module_name))
        lines.append('mkdir -p "$DEPS_DIR/{module}"'.format(module = module_name))
        for src_path in source_paths:
            lines.append('cp "$RUNFILES_DIR/_main/{src}" "$DEPS_DIR/{module}/"'.format(
                src = src_path,
                module = module_name,
            ))
        lines.append("")
    return lines

def _resource_owner_for_module(res_name, normalized_main_name, original_main_name, swift_modules):
    owner = None
    if res_name.endswith("Resources") and len(res_name) > len("Resources"):
        owner_candidate = res_name[:-len("Resources")]
        if owner_candidate == original_main_name or owner_candidate == normalized_main_name:
            owner = normalized_main_name
        elif owner_candidate in swift_modules:
            owner = owner_candidate
    elif res_name in swift_modules and not res_name.endswith("Resources"):
        owner = res_name
    return owner

def _directory_copy_root(res_path, suffix):
    marker = ".{}".format(suffix)
    idx = res_path.find(marker)
    if idx == -1:
        return None
    return res_path[:idx + len(marker)]

def _resource_copy_source(res_path):
    xcassets_root = _directory_copy_root(res_path, "xcassets")
    if xcassets_root:
        return xcassets_root

    lproj_root = _directory_copy_root(res_path, "lproj")
    if lproj_root:
        return lproj_root

    return res_path

def _is_skipped_resource_path(res_path):
    if res_path.endswith("/Info.plist") or res_path == "Info.plist":
        return True
    if res_path.endswith(".bundle") or ".bundle/" in res_path:
        return True
    return False

def generate_copy_resources_script_from_paths(resource_modules, main_module_name = "", dep_modules = []):
    """Generate script lines to copy resource files and generated source to .deps/<module>/.

    Pure function that takes string paths instead of File objects.

    Args:
        resource_modules: dict mapping module_name -> {resources: [paths], generated_source: path}

    Returns:
        List of shell script lines
    """
    normalized_main_name = main_module_name[:-5] if main_module_name.endswith("Views") and len(main_module_name) > 5 else main_module_name
    swift_modules = [normalized_main_name] + dep_modules

    lines = []
    for res_name, res_info in resource_modules.items():
        copyable_resources = []
        for res_path in res_info.get("resources", []):
            if not _is_skipped_resource_path(res_path):
                copyable_resources.append(res_path)

        generated_source = res_info.get("generated_source")
        if not copyable_resources and not generated_source:
            continue

        owner = _resource_owner_for_module(res_name, normalized_main_name, main_module_name, swift_modules)
        target_root = "$DEPS_DIR/{name}".format(name = res_name)
        if owner:
            target_root = "$DEPS_DIR/{owner}/{name}".format(owner = owner, name = res_name)

        lines.append("# Copy {name} resources and generated source".format(name = res_name))
        lines.append('mkdir -p "{root}/Resources"'.format(root = target_root))

        # Copy resource files
        copied_sources = {}
        for res_path in copyable_resources:
            copy_source = _resource_copy_source(res_path)
            if copy_source in copied_sources:
                continue
            copied_sources[copy_source] = True
            lines.append('cp -R "$RUNFILES_DIR/_main/{src}" "{root}/Resources/"'.format(
                src = copy_source,
                root = target_root,
            ))

        # Copy generated Swift source (respects force_unwrap and all other options from original build)
        if generated_source:
            lines.append('cp "$RUNFILES_DIR/_main/{src}" "{root}/"'.format(
                src = generated_source,
                root = target_root,
            ))

        lines.append("")
    return lines

def generate_copy_cc_module_script_from_paths(cc_modules, module_map_modules = []):
    """Generate script lines to copy C/C++ sources and headers to .deps/.

    Pure function that takes string paths instead of File objects.
    Sources go to .deps/<module>/, headers go to .deps/<module>/include/.

    Args:
        cc_modules: dict mapping module_name -> {srcs: [paths], hdrs: [paths]}
        module_map_modules: module names that should get an umbrella-directory
            module.modulemap (to expose private headers to Swift).

    Returns:
        List of shell script lines
    """
    lines = []
    for module_name, file_info in cc_modules.items():
        src_paths = file_info.get("srcs", [])
        hdr_paths = file_info.get("hdrs", [])

        lines.append("# Copy {module} C/C++ module".format(module = module_name))
        lines.append('mkdir -p "$DEPS_DIR/{module}"'.format(module = module_name))

        # Copy source files to module root
        for src_path in src_paths:
            lines.append('cp "$RUNFILES_DIR/_main/{src}" "$DEPS_DIR/{module}/"'.format(
                src = src_path,
                module = module_name,
            ))

        # Copy headers to include/ subdirectory
        if hdr_paths:
            lines.append('mkdir -p "$DEPS_DIR/{module}/include"'.format(module = module_name))
            for hdr_path in hdr_paths:
                lines.append('cp "$RUNFILES_DIR/_main/{hdr}" "$DEPS_DIR/{module}/include/"'.format(
                    hdr = hdr_path,
                    module = module_name,
                ))
            if module_name in module_map_modules:
                lines.extend(_emit_umbrella_header_patch_lines(module_name, hdr_paths))

        lines.append("")
    return lines

def _emit_umbrella_header_patch_lines(module_name, hdr_paths):
    """Shell lines that make a module's private headers visible to Swift.

    SwiftPM auto-generates a module map that uses the header matching the module
    name (e.g. FBLPromises.h) as an umbrella *header*. Only what that umbrella
    imports ends up in the module, so sibling private/testing headers in the same
    include/ dir are invisible to Swift consumers (e.g. Promises needs the
    FBLPromisePrivate.h extension on FBLPromise).

    Rather than ship a competing module.modulemap (which clang rejects with
    "umbrella ... already covers this directory" alongside SwiftPM's generated
    map), we append `#import` directives for the sibling headers to the umbrella
    header itself. #import is idempotent, so re-importing already-included public
    headers is harmless, and the previously-excluded headers become part of the
    module via the umbrella SwiftPM already generates.
    """
    umbrella = module_name + ".h"
    siblings = []
    seen = {}
    for hdr_path in hdr_paths:
        basename = hdr_path.split("/")[-1]
        if basename == umbrella or basename in seen:
            continue
        seen[basename] = True
        siblings.append(basename)

    if not siblings:
        return []

    siblings = sorted(siblings)
    lines = [
        "# Expose sibling headers (incl. private) to Swift consumers of {module}".format(module = module_name),
        'RSP_UMBRELLA="$DEPS_DIR/{module}/include/{umbrella}"'.format(module = module_name, umbrella = umbrella),
        'if [ -f "$RSP_UMBRELLA" ]; then',
        '  cat >> "$RSP_UMBRELLA" <<\'RSP_UMBRELLA_EOF\'',
        "",
        "// rules_swift_previews: import sibling headers so private/testing",
        "// declarations are part of the module and visible to Swift.",
    ]
    for basename in siblings:
        lines.append('#import "{basename}"'.format(basename = basename))
    lines.extend([
        "RSP_UMBRELLA_EOF",
        "fi",
    ])
    return lines

def generate_copy_objc_module_script_from_paths(objc_modules, module_map_modules = []):
    """Generate script lines to copy Objective-C sources and headers to .deps/.

    Pure function that takes string paths instead of File objects.
    Sources go to .deps/<module>/, headers go to .deps/<module>/include/.

    Args:
        objc_modules: dict mapping module_name -> {srcs: [paths], hdrs: [paths]}
        module_map_modules: module names that should get an umbrella-directory
            module.modulemap (to expose private headers to Swift).

    Returns:
        List of shell script lines
    """
    def private_header_dest_path(module_name, hdr_path):
        if module_name != "SSZipArchive":
            parts = hdr_path.split("/")
            return parts[-1]

        parts = hdr_path.split("/")
        if len(parts) <= 1:
            return hdr_path

        # Prefer trimming up to the last segment matching module name.
        last_module_idx = -1
        for i, part in enumerate(parts[:-1]):
            if part == module_name:
                last_module_idx = i

        if last_module_idx != -1 and last_module_idx < len(parts) - 1:
            return "/".join(parts[last_module_idx + 1:])

        # Fallback: drop first leading directory.
        return "/".join(parts[1:])

    lines = []
    for module_name, file_info in objc_modules.items():
        src_paths = file_info.get("srcs", [])
        hdr_paths = file_info.get("hdrs", [])
        private_hdr_paths = file_info.get("private_hdrs", [])

        lines.append("# Copy {module} Objective-C module".format(module = module_name))
        lines.append('mkdir -p "$DEPS_DIR/{module}"'.format(module = module_name))

        # Copy source files to module root
        for src_path in src_paths:
            lines.append('cp "$RUNFILES_DIR/_main/{src}" "$DEPS_DIR/{module}/"'.format(
                src = src_path,
                module = module_name,
            ))

        for hdr_path in private_hdr_paths:
            dest_hdr_path = private_header_dest_path(module_name, hdr_path)
            if "/" in dest_hdr_path:
                lines.append('mkdir -p "$DEPS_DIR/{module}/$(dirname "{hdr}")"'.format(
                    hdr = dest_hdr_path,
                    module = module_name,
                ))
            lines.append('cp "$RUNFILES_DIR/_main/{src}" "$DEPS_DIR/{module}/{dest}"'.format(
                src = hdr_path,
                dest = dest_hdr_path,
                module = module_name,
            ))

        # Copy headers to include/ subdirectory
        if hdr_paths:
            lines.append('mkdir -p "$DEPS_DIR/{module}/include"'.format(module = module_name))
            for hdr_path in hdr_paths:
                lines.append('cp "$RUNFILES_DIR/_main/{hdr}" "$DEPS_DIR/{module}/include/"'.format(
                    hdr = hdr_path,
                    module = module_name,
                ))
            if module_name in module_map_modules:
                lines.extend(_emit_umbrella_header_patch_lines(module_name, hdr_paths))

        lines.append("")
    return lines

def generate_copy_xcframework_script_from_paths(xcframework_modules):
    """Generate script lines to copy XCFramework directories to .deps/.

    Args:
        xcframework_modules: dict mapping module_name -> xcframework root short_path

    Returns:
        List of shell script lines
    """
    def _trim_parent_segments(path):
        trimmed = path
        for _i in range(8):
            if trimmed.startswith("../"):
                trimmed = trimmed[3:]
        return trimmed

    lines = []
    for module_name, xcframework_path in xcframework_modules.items():
        normalized_path = _trim_parent_segments(xcframework_path)
        lines.append("# Copy {module} xcframework".format(module = module_name))
        lines.append('mkdir -p "$DEPS_DIR/{module}"'.format(module = module_name))
        lines.append('SRC_XCFRAMEWORK="$BUILD_WORKSPACE_DIRECTORY/{src}"'.format(src = xcframework_path))
        lines.append('if [ ! -d "$SRC_XCFRAMEWORK" ]; then SRC_XCFRAMEWORK="$RUNFILES_DIR/_main/{src}"; fi'.format(src = xcframework_path))
        lines.append('if [ ! -d "$SRC_XCFRAMEWORK" ]; then SRC_XCFRAMEWORK="$RUNFILES_DIR/{src}"; fi'.format(src = xcframework_path))
        lines.append('if [ ! -d "$SRC_XCFRAMEWORK" ]; then SRC_XCFRAMEWORK="$RUNFILES_DIR/_main/external/{src}"; fi'.format(src = normalized_path))
        lines.append('if [ ! -d "$SRC_XCFRAMEWORK" ]; then SRC_XCFRAMEWORK="$RUNFILES_DIR/external/{src}"; fi'.format(src = normalized_path))
        lines.append('if [ ! -d "$SRC_XCFRAMEWORK" ]; then SRC_XCFRAMEWORK="$RUNFILES_DIR/{src}"; fi'.format(src = normalized_path))
        lines.append('if [ -n "$SRC_XCFRAMEWORK" ] && [ -d "$SRC_XCFRAMEWORK" ]; then')
        lines.append('  _LINK="$(readlink "$SRC_XCFRAMEWORK/Info.plist" 2>/dev/null || true)"')
        lines.append('  if [ -n "$_LINK" ]; then')
        lines.append('    _RESOLVED="$(cd "$SRC_XCFRAMEWORK" && cd "$(dirname "$_LINK")" 2>/dev/null && pwd -P)"')
        lines.append('    if [ -n "$_RESOLVED" ] && [ -d "$_RESOLVED" ]; then SRC_XCFRAMEWORK="$_RESOLVED"; fi')
        lines.append('  fi')
        lines.append('fi')
        lines.append('if [ -z "$SRC_XCFRAMEWORK" ] || [ ! -d "$SRC_XCFRAMEWORK" ]; then echo "Warning: XCFramework not found for {module}: {src}"; else echo "Using XCFramework source for {module}: $SRC_XCFRAMEWORK"; rm -rf "$DEPS_DIR/{module}/{module}.xcframework" && ditto "$SRC_XCFRAMEWORK" "$DEPS_DIR/{module}/{module}.xcframework"; fi'.format(
            module = module_name,
            src = xcframework_path,
        ))
        lines.append("")
    return lines

# =============================================================================
# File object wrappers (used by rule implementation)
# =============================================================================

def generate_copy_sources_script(dep_dirs):
    """Generate script lines to copy dependency sources to .deps/.

    Args:
        dep_dirs: dict mapping module_name -> list of source File objects

    Returns:
        List of shell script lines
    """
    path_dict = {
        module_name: [src.short_path for src in sources]
        for module_name, sources in dep_dirs.items()
    }
    return generate_copy_sources_script_from_paths(path_dict)

def generate_copy_resources_script(resource_modules, main_module_name = "", dep_modules = []):
    """Generate script lines to copy resource files and generated source to .deps/<module>/.

    Args:
        resource_modules: dict mapping module_name -> {resources: [File], generated_source: File}

    Returns:
        List of shell script lines
    """
    path_dict = {}
    for res_name, res_info in resource_modules.items():
        path_dict[res_name] = {
            "resources": [f.short_path for f in res_info.get("resources", [])],
            "generated_source": res_info["generated_source"].short_path if res_info.get("generated_source") else None,
        }
    return generate_copy_resources_script_from_paths(
        path_dict,
        main_module_name = main_module_name,
        dep_modules = dep_modules,
    )

def generate_copy_cc_module_script(cc_modules, module_map_modules = []):
    """Generate script lines to copy C/C++ sources and headers to .deps/.

    Args:
        cc_modules: dict mapping module_name -> {srcs: [File], hdrs: [File]}
        module_map_modules: module names that should get an umbrella-directory
            module.modulemap (to expose private headers to Swift).

    Returns:
        List of shell script lines
    """
    path_dict = {}
    for module_name, file_info in cc_modules.items():
        path_dict[module_name] = {
            "srcs": [f.short_path for f in file_info.get("srcs", [])],
            "hdrs": [f.short_path for f in file_info.get("hdrs", [])],
        }
    return generate_copy_cc_module_script_from_paths(path_dict, module_map_modules)

def generate_copy_objc_module_script(objc_modules, module_map_modules = []):
    """Generate script lines to copy Objective-C sources and headers to .deps/.

    Args:
        objc_modules: dict mapping module_name -> {srcs: [File], hdrs: [File]}
        module_map_modules: module names that should get an umbrella-directory
            module.modulemap (to expose private headers to Swift).

    Returns:
        List of shell script lines
    """
    path_dict = {}
    for module_name, file_info in objc_modules.items():
        path_dict[module_name] = {
            "srcs": [f.short_path for f in file_info.get("srcs", [])],
            "hdrs": [f.short_path for f in file_info.get("hdrs", [])],
            "private_hdrs": [f.short_path for f in file_info.get("private_hdrs", [])],
        }
    return generate_copy_objc_module_script_from_paths(path_dict, module_map_modules)

def generate_copy_xcframework_script(xcframework_modules):
    """Generate script lines to copy XCFramework directories to .deps/.

    Args:
        xcframework_modules: dict mapping module_name -> xcframework root short_path

    Returns:
        List of shell script lines
    """
    return generate_copy_xcframework_script_from_paths(xcframework_modules)

def generate_collect_binary_xcframeworks_script(binary_module_names, xcfw_package_dir):
    """Generate lines to unzip Bazel-built xcframeworks into .deps/.

    The xcframework zips are produced by the `previews_gen` target into a
    separate Bazel output base (so the outer `bazel run` lock is not contended).
    We locate that output base's bazel-bin and unzip each module's archive into
    `.deps/<name>/<bundle>.xcframework`, preserving internals (and signatures).

    Args:
        binary_module_names: list of module names (Bazel target / SwiftPM names).
        xcfw_package_dir: workspace-relative package path holding the generated
            apple_static_xcframework targets.

    Returns:
        List of shell script lines.
    """
    if not binary_module_names:
        return []

    lines = [
        "# Collect Bazel-built ObjC/C xcframeworks into .deps/",
        'XCFW_OB="${RSP_XCFW_OUTPUT_BASE:-${TMPDIR:-/tmp}/rsp_xcfw_output_base}"',
        'XCFW_BIN="$(cd "$BUILD_WORKSPACE_DIRECTORY" && bazel --output_base="$XCFW_OB" info bazel-bin 2>/dev/null || true)"',
        'if [ -z "$XCFW_BIN" ]; then',
        '  echo "Error: could not locate xcframework build output. Run the *_gen target first." >&2',
        "  exit 1",
        "fi",
    ]
    for name in binary_module_names:
        zip_path = '$XCFW_BIN/{pkg}/{name}.xcframework.zip'.format(pkg = xcfw_package_dir, name = name)
        dest = '$DEPS_DIR/{name}'.format(name = name)
        lines.extend([
            'if [ ! -f "{zip}" ]; then'.format(zip = zip_path),
            '  echo "Error: missing {name}.xcframework.zip; re-run the *_gen target." >&2'.format(name = name),
            "  exit 1",
            "fi",
            'rm -rf "{dest}" && mkdir -p "{dest}"'.format(dest = dest),
            'unzip -q -o "{zip}" -d "{dest}"'.format(zip = zip_path, dest = dest),
        ])
    lines.append('echo "Collected {n} xcframework(s) into .deps/"'.format(n = len(binary_module_names)))
    lines.append("")
    return lines

def generate_base_script(package_dir):
    """Generate the base shell script setup lines.

    Args:
        package_dir: Path to the package directory

    Returns:
        List of shell script lines
    """
    return [
        "#!/bin/bash",
        "set -e",
        "",
        "# BUILD_WORKSPACE_DIRECTORY is set by Bazel during 'bazel run'",
        'if [ -z "$BUILD_WORKSPACE_DIRECTORY" ]; then',
        '  echo "Error: This script must be run via bazel run"',
        "  exit 1",
        "fi",
        "",
        "# Get runfiles directory",
        'RUNFILES_DIR="${BASH_SOURCE[0]}.runfiles"',
        'if [ ! -d "$RUNFILES_DIR" ]; then',
        '  RUNFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"',
        "fi",
        "",
        "# Package directory is the Views directory itself",
        'PACKAGE_DIR="$BUILD_WORKSPACE_DIRECTORY/{package_dir}"'.format(package_dir = package_dir),
        'DEPS_DIR="$PACKAGE_DIR/.deps"',
        "",
        'echo "Generating preview package at $PACKAGE_DIR"',
        "",
        "# Clean and create deps directory",
        'rm -rf "$DEPS_DIR"',
        'mkdir -p "$DEPS_DIR"',
        "",
    ]

def generate_package_write_script(package_swift_content):
    """Generate script lines to write Package.swift.

    Args:
        package_swift_content: The Package.swift file content

    Returns:
        List of shell script lines
    """
    return [
        "# Write Package.swift",
        'cat > "$PACKAGE_DIR/Package.swift" << \'PACKAGE_EOF\'',
        package_swift_content,
        "PACKAGE_EOF",
        "",
        'echo "Preview package generated successfully!"',
        'echo "Open with: open $PACKAGE_DIR"',
    ]
