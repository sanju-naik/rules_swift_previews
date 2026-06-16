# `rules_swift_previews` — Technical Deep Dive

Audience: engineers who maintain and extend this ruleset.

This document describes how `rules_swift_previews` turns a Bazel `swift_library`
graph into a SwiftPM `Package.swift` that Xcode can open and render SwiftUI
previews against. It is written against the actual source under `internal/`;
file, symbol, and attribute names are quoted directly. Where this document and
intuition disagree, the code wins.

---

## 1. Purpose and high-level architecture

Bazel-built iOS apps cannot use Xcode's SwiftUI preview canvas directly: Xcode
previews are built by SwiftPM/Xcode's own toolchain, not by Bazel. This ruleset
bridges the gap by **materializing a self-contained SwiftPM package** next to a
module's sources. An aspect walks the `swift_library` dependency graph, collects
everything needed to compile the module (Swift sources, ObjC/C sources, resource
bundles, prebuilt `.xcframework`s), and a rule emits:

1. a shell script that copies all of those inputs into a local `.deps/` tree, and
2. a generated `Package.swift` whose targets / `.binaryTarget`s reference that
   `.deps/` tree.

Open the package in Xcode and the preview canvas builds the module the SwiftPM
way.

The system runs in **two phases**, exposed as two `executable` rules:

- **Phase A — binarization (`swift_previews_gen`, conventionally `previews_gen`).**
  Problematic ObjC/C Pod & SPM dependencies are compiled into prebuilt static
  `.xcframework`s via rules_apple's `apple_static_xcframework`. This is necessary
  because faithfully recompiling Pods/SPM ObjC code through SwiftPM (Bazel-relative
  `#import` paths, module maps, mixed-language targets) is brittle. See
  `internal/xcframework_generator.bzl`.

- **Phase B — packaging (`swift_previews_package`, conventionally `previews`).**
  Emits `Package.swift` + the copy script. Source-compilable modules become
  `.target`s; binarized modules (and other `.xcframework`s found in the graph)
  become `.binaryTarget`s. See `internal/core.bzl`, `internal/package_generator.bzl`,
  and `internal/script_generator.bzl`.

```
                         swift_library (the "lib" attr)
                                   │
                  source_collector_aspect walks deps/actual/data
                                   │
            ┌──────────────────────┴───────────────────────┐
            │             SourceFilesInfo                    │
            │  sources, module_sources, resource_modules,    │
            │  module_deps, cc_modules, objc_modules,        │
            │  xcframework_modules, binary_xcfw_modules,      │
            │  swift6_modules                                 │
            └──────────────────────┬───────────────────────┘
                                   │
        ┌──────────────────────────┴──────────────────────────┐
        │                                                       │
  Phase A: previews_gen                              Phase B: previews
  (swift_previews_gen_impl)                       (swift_previews_package_impl)
        │                                                       │
  emits a temp BUILD of                          emits a shell script that:
  apple_static_xcframework                         • copies dep Swift/ObjC/C
  targets, then                                      sources into .deps/<mod>/
  `bazel build --nocheck_visibility`               • copies .xcframeworks
  in a separate --output_base                       • unzips Phase-A xcframeworks
        │                                            • copies resources
        ▼                                            • writes Package.swift
  *.xcframework.zip in                                       │
  bazel-bin/<xcfw_pkg>/                                       ▼
        └──────────────► unzipped into ──────────►  Views/Package.swift + .deps/
                                                              │
                                                              ▼
                                                   open in Xcode → preview
```

---

## 2. The aspect: `source_collector_aspect`

Defined at the bottom of `internal/core.bzl`:

```594:598:internal/core.bzl
source_collector_aspect = aspect(
    implementation = _source_collector_aspect_impl,
    attr_aspects = ["actual", "deps", "data"],
    doc = "Collects source files from swift_library, cc_library, and objc_library targets.",
)
```

It propagates along `deps`, `actual` (alias targets), and `data` edges, and on
every visited target produces a single `SourceFilesInfo` provider
(`internal/providers.bzl`) carrying nine fields:

| Field | Contents |
|---|---|
| `sources` | `depset` of all Swift source `File`s in the subgraph |
| `module_sources` | `dict` module name → its Swift source `File`s |
| `resource_modules` | `dict` module name → `{resources: [...], generated_source: File}` |
| `module_deps` | `dict` module name → list of its direct dependency module names |
| `cc_modules` | `dict` module name → `{srcs, hdrs}` (from `cc_library`) |
| `objc_modules` | `dict` module name → `{srcs, hdrs, private_hdrs}` (from `objc_library`) |
| `xcframework_modules` | `dict` module name → list of `.xcframework` `File`s |
| `binary_xcfw_modules` | `dict` module name → binarization metadata `{target, hdrs, avoid_deps}` |
| `swift6_modules` | `dict` module name → `True` for targets built with `-swift-version 6` |

### 2.1 Per-language collection

Collection is delegated to small, single-purpose collectors:

- **Swift** (`internal/swift_collector.bzl`, `collect_swift_sources`): reads
  `ctx.rule.attr.srcs`, keeps `.swift` files, uses `module_name` (or the target
  label name) as the module key. The same file also has `collect_swift_resources`
  (for the `swift_resources` rule kind, which carries `files/fonts/images/
  xcassets/strings` and a `generated_source`) and `collect_apple_bundle_resources`
  (for `apple_resource_bundle`, reading `resources/structured_resources/
  infoplists/files`).
- **C/C++** (`internal/cc_collector.bzl`, `collect_cc_sources`): only fires for
  `ctx.rule.kind == "cc_library"`, splitting `.c/.cc/.cpp/...` srcs and
  `.h/.hpp/.inc/...` hdrs. The module name is the label name (it cannot read
  `module_name` from `swift_interop_hint`, since `SwiftInteropInfo` is private).
- **Objective-C** (`internal/objc_collector.bzl`, `collect_objc_sources`): only
  fires for `objc_library`. `.m/.mm` go to `srcs`; `.h/.hh/.hpp` in `srcs` and
  `textual_hdrs` become `private_hdrs`; `hdrs` become public `hdrs`. Public
  headers are subtracted from private ones so a header is never both.

### 2.2 Module-name normalization

External Bazel/SPM packages decorate module names with suffixes; the aspect
strips them so SwiftPM target names match `import` statements:

```38:42:internal/core.bzl
def _normalize_module_name(name):
    for suffix in (".rspm_objcxx", ".rspm_objc", ".rspm_c", ".rspm"):
        if name.endswith(suffix):
            return name[:-len(suffix)]
    return name
```

### 2.3 Two traversal regimes: first-party vs external

`_source_collector_aspect_impl` branches on whether the target is external:

```322:328:internal/core.bzl
    # Skip most external dependencies, but collect XCFrameworks and own Swift sources
    label = target.label
    if label.workspace_name != "" or label.package.startswith("external"):
        target_files = target.files.to_list() if hasattr(target, "files") else []
        external_xcframeworks = _collect_xcframework_modules_from_files(target_files)
        attr_xcframeworks = _collect_xcframework_modules_from_rule_attrs(ctx)
        _merge_xcframework_maps(external_xcframeworks, attr_xcframeworks)
```

For external targets it still collects that target's own Swift/ObjC/C sources,
its `.xcframework`s, and merges its deps' `SourceFilesInfo`, but treats them as a
flatter "external" bundle. First-party targets get the full transitive merge
(sections starting around line 419) including resource modules and the synthetic
`data`-attribute resource module.

### 2.4 XCFramework discovery

`.xcframework`s are discovered two ways: by scanning a target's output `File`s
(`_collect_xcframework_modules_from_files`) and by scanning a curated list of
rule attributes (`_collect_xcframework_modules_from_rule_attrs`, which looks at
`actual/data/deps/srcs/framework_imports/frameworks/xcframework_imports/
libraries`). `_xcframework_root` finds the `.xcframework` directory root inside a
file path (handling `.xcframework.zip`), and `_xcframework_name_from_root`
derives the module name, stripping `-Static-SPM` / `-Dynamic-SPM` suffixes.

### 2.5 Resources from the `data` attribute

Recent work (commit `88f5acc`) lets the aspect pull resources from a
`swift_library`'s `data` attribute. When the current module has `data`, the
aspect collects those files into a **synthetic resource module** named
`<Module>Resources`:

```540:546:internal/core.bzl
            synthetic_resource_module = "{}Resources".format(module_name)
            resource_modules[synthetic_resource_module] = {
                "resources": deduped_data_files,
                "generated_source": None,
            }
            if synthetic_resource_module not in direct_dep_modules:
                direct_dep_modules.append(synthetic_resource_module)
```

(`GoMartNew` uses this: its `swift_library` has `data = ["GoMartNewResources"]`.)

### 2.6 Binarization metadata

For external/Pods ObjC/C targets, the aspect records what Phase A needs to build
an `apple_static_xcframework`. `_is_binarizable_objc_cc` decides eligibility (an
`objc_library`/`cc_library` that is either external — `workspace_name != ""` — or
under `//Pods`), and `_collect_binary_xcfw_metadata` captures the wrap target
label, the public `.h` headers (deduplicated by basename, because static
frameworks flatten headers into one `Headers/` dir), and the direct `deps` as
`avoid_deps`:

```141:145:internal/core.bzl
    return module_name, {
        "target": str(target.label),
        "hdrs": hdrs,
        "avoid_deps": avoid_deps,
    }
```

Critically the aspect collects *both* the source view and the binary metadata for
every binarizable module. The **consuming rule** decides per-module whether to
actually binarize (via `keep_as_source`); the aspect stays policy-free.

### 2.7 Swift 6 detection

`_detect_swift6` scans `copts` for `-swift-version 6` (in either `-swift-version
6` or `-swift-version=6` form). Detected modules are recorded in `swift6_modules`
and surfaced as *candidates*, not forced (see §4.6).

---

## 3. Phase A — `swift_previews_gen` (binarization)

`swift_previews_gen_impl` (around line 1040 of `internal/core.bzl`) reads the
`binary_xcfw_modules` the aspect collected from `lib`, removes any in
`keep_as_source` and any in `binary_module_renames`, and adds explicitly
requested `extra_binary_libs`. It then asks `generate_xcframework_build_content`
(`internal/xcframework_generator.bzl`) to emit a temporary `BUILD.bazel` full of
`apple_static_xcframework` targets, one per binarized module:

```92:102:internal/xcframework_generator.bzl
    lines = [
        "apple_static_xcframework(",
        '    name = "{}",'.format(module_name),
        '    bundle_name = "{}",'.format(bundle_name),
        "    deps = [{}],".format('"{}"'.format(target_label)),
        "    public_hdrs = {},".format(_format_str_list(public_hdrs, 4)),
        "    avoid_deps = {},".format(_format_str_list(avoid_deps, 4)),
        '    minimum_os_versions = {{"ios": "{}"}},'.format(ios_version),
        "    ios = {},".format(_format_arch_dict(ios_variants, 4)),
        ")",
    ]
```

Key details:

- **`bundle_name` is sanitized** to a valid C identifier (`-` and `.` → `_`),
  e.g. `GoogleUtilities-Environment` → `GoogleUtilities_Environment`, while the
  Bazel target / SwiftPM target name keeps the original so dependency arrays
  resolve.
- **`avoid_deps` is essential**: without it each xcframework would statically
  embed its transitive deps, producing duplicate symbols when many xcframeworks
  link into one preview binary.
- Only the **simulator arm64** slice is built by default (`ios_variants =
  {"simulator": ["arm64"]}`); `include_device_slice` adds device arm64. Previews
  only need the simulator.

The generated `previews_gen` script writes that BUILD to
`xcframework_package_dir` (default `<package>/previews_xcfw`) and runs:

```1118:1121:internal/core.bzl
            'bazel --output_base="$OB" build --nocheck_visibility \\\n  {targets}'.format(
                targets = build_targets,
            ),
```

It uses a **separate `--output_base`** (`RSP_XCFW_OUTPUT_BASE`, default under
`$TMPDIR`) so the inner build does not contend with the outer `bazel run`'s
server lock, and `--nocheck_visibility` because swiftpkg/Pods internal targets
are package-private. Output lands as `*.xcframework.zip` under that output base's
`bazel-bin/<xcfw_pkg>/`.

---

## 4. Phase B — `swift_previews_package` (packaging)

`swift_previews_package_impl` (line ~600 of `internal/core.bzl`) consumes the
`SourceFilesInfo` from `lib`, builds the copy script, generates `Package.swift`,
and returns a `DefaultInfo` with the script as the executable plus all collected
files as runfiles.

### 4.1 Sorting collected modules

The main module (whose name equals `lib.label.name`) is separated from
dependency modules; its sources go to `main_module_sources`, dep modules go to
`dep_dirs`. There is a fallback for the case where the main module has no
sources of its own:

```664:673:internal/core.bzl
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
```

### 4.2 Deciding what to binarize: `keep_as_source` / `binary_set`

```723:728:internal/core.bzl
        keep_as_source = {m: True for m in ctx.attr.keep_as_source}
        binary_set = {
            m: True
            for m in info.binary_xcfw_modules.keys()
            if m not in keep_as_source
        }
```

A module in `binary_set` is dropped from the source-compiled `cc_modules` /
`objc_modules` collections and instead emitted as a `.binaryTarget`. Modules in
`keep_as_source` stay source-compiled and additionally get an umbrella-header
patch (see §5.3). `extra_binary_libs` and `binary_module_renames` further adjust
this set (wrapper modules in `binary_module_renames` are dropped entirely; the
rename is applied to dependency arrays during package generation).

### 4.3 Generating `Package.swift`

`generate_package_swift` (`internal/package_generator.bzl`) emits the manifest.
Highlights:

- **tools-version 6.0** is pinned (`// swift-tools-version: 6.0`) so per-target
  `.swiftLanguageMode(.v6)` is available, but the package default is pinned back
  to `.v5` via `swiftLanguageModes: [.v5]` at the bottom. Blanket v6 would
  surface strict-concurrency / `@retroactive` errors in modules that compile fine
  in v5.
- **`.binaryTarget`s** are emitted first — both the plain `xcframework_modules`
  (path `.deps/<module>/<module>.xcframework`) and the Phase-A
  `binary_xcfw_modules` (path `.deps/<module>/<sanitized-bundle>.xcframework`).
- **C/C++ and ObjC `.target`s** get `path: ".deps/<module>"` and
  `publicHeadersPath: "include"`.
- **Swift dep `.target`s** get `path: ".deps/<module>"`, `exclude:
  ["Package.swift"]`, an optional `resources:` array when they own a resource
  module, and an optional `swiftSettings: [.swiftLanguageMode(.v6)]` when opted
  in.
- **Dependency arrays are filtered** against the set of modules that actually
  exist in the package (`all_modules`); references to excluded/renamed modules are
  rewritten via `binary_module_renames` and `merged_resource_to_owner`, and
  self-edges are dropped.

### 4.4 The main target: scattered sources + `exclude`

The main target's `path` is computed by `_compute_main_target_path`, the common
parent directory of the main module's sources. If sources are scattered across
several top-level directories, this collapses to `"."` (the package root). A bare
`path: "."` would make SwiftPM scan the entire root (including `.deps` and
sibling dirs), so the rule instead emits an explicit per-file `sources:` list
(`_package_relative_swift_sources`):

```196:209:internal/core.bzl
def _compute_main_target_path(main_sources, package_dir):
    if not main_sources:
        return "."
    ...
    return _common_dir(rel_dirs)
```

`exclude:` is **always** emitted alongside `sources:`, because `sources:` only
restricts which *source files* compile — SwiftPM still auto-discovers *resources*
across the whole `path`. The base excludes are `BUILD.bazel`, `.deps`,
`Package.swift`, `MODULE.bazel`, `MODULE.bazel.lock`; `extra_excludes` are
appended after stripping the main-target-path prefix and dropping any entry with
glob metacharacters (`*?{`), since SwiftPM `exclude` has no wildcard support.

### 4.5 Resource ownership

Resource modules named `<Owner>Resources` are attached to their owning Swift
target as a `resources: [.process("<Mod>/Resources")]` entry (or
`.process(".deps/<Mod>/Resources")` for the main module); otherwise they become
standalone resource `.target`s. `Info.plist`, `.bundle`, and `.xcframework`
entries are filtered out (`_is_skipped_resource_file`).

### 4.6 Swift 6 opt-in

`swift6_modules` (caller-specified) get `.swiftLanguageMode(.v6)`. Modules the
aspect *detected* as Swift-6 (`detected_swift6_modules`) are not forced; instead
they are listed in a header comment as candidates:

```164:167:internal/package_generator.bzl
        lines.append(
            "// Bazel Swift-6 module candidates (add to swift6_modules to enable .v6): " +
            ", ".join(sorted(candidates)),
        )
```

(See the top of `LaunchpadHost/GoMartNew/Package.swift` for a real candidate
list, and `CVSDK` / `GotoLoginSDK` opted in.)

---

## 5. The copy script (`internal/script_generator.bzl`)

`swift_previews_package_impl` assembles the script from helper functions; the
script runs at `bazel run` time (it requires `BUILD_WORKSPACE_DIRECTORY`).
`generate_base_script` sets up `PACKAGE_DIR`, wipes and recreates
`DEPS_DIR="$PACKAGE_DIR/.deps"`, and reads files from the runfiles tree.

### 5.1 Copying Swift dep sources + the exclude/replace guards

`generate_copy_sources_script` copies each dep module's `.swift` files into
`.deps/<module>/`. Two transformations happen here:

- **`replace_sources`**: if a source's basename is in the replace map, the
  original is skipped and the replacement `.swift` is copied under the original
  basename.
- **`exclude_modules` import guard**: file contents are unavailable at analysis
  time, so each copy is wrapped in a runtime `grep` for a top-level `import` of
  any excluded module; matching files are skipped:

```60:71:internal/script_generator.bzl
            if import_pattern and src_path.endswith(".swift"):
                lines.append("if grep -qE '{pattern}' \"$RUNFILES_DIR/_main/{src}\"; then".format(
                    pattern = import_pattern,
                    src = src_path,
                ))
                lines.append('  echo "Skipping {src} (imports excluded module)"'.format(src = src_path))
                lines.append("else")
                lines.append('  cp "$RUNFILES_DIR/_main/{src}" "$DEPS_DIR/{module}/"'.format(...))
                lines.append("fi")
```

The pattern (`_excluded_import_grep_pattern`) is anchored at line start, allows
leading whitespace and `@_implementationOnly` / `@_exported` attributes, and
matches `import Foo`, `import struct Foo.Bar`, etc. — so commented-out imports do
not match.

### 5.2 Copying resources

`generate_copy_resources_script` copies resource dirs with `cp -R`/`ditto`,
collapsing `.xcassets` and `.lproj` to their directory root
(`_resource_copy_source`) and skipping `Info.plist`/`.bundle`. Owned resources go
under `.deps/<owner>/<resModule>/Resources`; standalone ones under
`.deps/<resModule>/Resources`.

### 5.3 Copying ObjC/C modules + umbrella-header patching

`generate_copy_objc_module_script` / `generate_copy_cc_module_script` copy `.m/
.mm/.c/...` to the module root and headers to `include/`. For modules in
`keep_as_source` (`module_map_modules`), `_emit_umbrella_header_patch_lines`
appends `#import "<sibling>.h"` directives to the SwiftPM-generated umbrella
header so **private/testing headers in the same `include/` become visible to
Swift** (e.g. `FBLPromises` needs `FBLPromisePrivate.h`). This avoids shipping a
competing `module.modulemap`, which clang rejects alongside SwiftPM's generated
map. (`SSZipArchive` gets bespoke private-header path handling.)

### 5.4 Copying `.xcframework`s and collecting Phase-A output

`generate_copy_xcframework_script` probes a list of candidate source locations
(`BUILD_WORKSPACE_DIRECTORY`, several `RUNFILES_DIR` variants, `external/…`),
resolves any `Info.plist` symlink, and `ditto`s the framework into
`.deps/<module>/<module>.xcframework`.

`generate_collect_binary_xcframeworks_script` locates the Phase-A output base's
`bazel-bin` and `unzip`s each `<name>.xcframework.zip` into `.deps/<name>/` —
this is the join point between Phase A and Phase B, and it `exit 1`s with a clear
message if the `_gen` target was not run first.

Finally `generate_package_write_script` writes `Package.swift` via a heredoc.

---

## 6. `swift_previews_package` / `swift_previews_gen` attributes

Defined in `_BASE_ATTRS` and `_GEN_ATTRS` in `internal/core.bzl`. The public
macros are created via `create_swift_previews_macro` /
`create_swift_previews_gen_macro`, which inject `package_dir =
native.package_name()` automatically.

### `swift_previews_package` (macro)

| Attribute | Type | Default | Purpose |
|---|---|---|---|
| `name` | string | required | Target name (conventionally `previews`) |
| `lib` | label | required | The `swift_library` to preview (aspect applied here) |
| `ios_version` | string | `"18"` (macro) / `"15"` (rule attr) | iOS deployment target |
| `macos_version` / `tvos_version` / `watchos_version` / `visionos_version` | string | `""` | Other platforms (empty = omit) |
| `extra_excludes` | string_list | `[]` | Extra `exclude:` entries for the main SPM target (typically the `swift_library` glob `exclude`; non-glob only) |
| `exclude_sources` | string_list | `[]` | Source basenames/suffixes to omit entirely (e.g. `"+Testing.swift"`) |
| `exclude_modules` | string_list | `[]` | Modules to fully drop — no target/binaryTarget, stripped from every dep array, dep sources importing them skipped at copy time |
| `replace_sources` | dict | `{}` | Map `dep-source-basename → replacement .swift label`; original skipped, replacement copied in its place |
| `keep_as_source` | string_list | `[]` | Binarizable modules to keep source-compiled (gets umbrella-header patch) |
| `swift6_modules` | string_list | `[]` | Modules to compile with `.swiftLanguageMode(.v6)` |
| `extra_binary_libs` | label_list | `[]` | ObjC/C libs to binarize explicitly (aspect applied) — for modules behind a platform `select()` |
| `binary_module_renames` | string_dict | `{}` | Map wrapper module name → real module name |

> Note on `replace_sources`: the **macro** takes `{basename: label}` and inverts
> it to the `{label: basename}` shape the rule's `label_keyed_string_dict`
> expects (`internal/core.bzl` line ~1018).

### `swift_previews_gen` (macro)

| Attribute | Type | Default | Purpose |
|---|---|---|---|
| `name` | string | required | Conventionally `previews_gen` |
| `lib` | label | required | Same `swift_library` as the `previews` target |
| `ios_version` | string | `"15"` | Minimum OS for the generated xcframeworks |
| `xcframework_package_dir` | string | `<package>/previews_xcfw` | Where the temp BUILD is written |
| `include_device_slice` | bool | `False` | Also build device arm64 (previews only need simulator) |
| `keep_as_source` | string_list | `[]` | Must mirror the `previews` target |
| `extra_binary_libs` | label_list | `[]` | Must mirror the `previews` target |
| `binary_module_renames` | string_dict | `{}` | Must mirror the `previews` target |

`keep_as_source`, `extra_binary_libs`, and `binary_module_renames` must be kept
**in sync** between the two targets, or Phase A will build a different set of
xcframeworks than Phase B expects.

---

## 7. Complexities for real modules (why this is hard)

SwiftUI Previews do not run in a normal process. Xcode executes the preview in a
restricted JIT host (`XCPreviewAgent`) that dynamically loads the compiled
package. Several dependency shapes that are perfectly fine in a normal Bazel link
fail in that environment. The ruleset's collected feature set is essentially a
catalogue of those failures and their mitigations.

- **ObjC/C++ `+load` methods and static initializers.** Static archives whose
  `+load` runs side effects at image-load time can crash the JIT executor.
  **GoogleMaps** (a static archive with heavy ObjC machinery) is the canonical
  offender. The mitigation in this ruleset is to consume such deps as a prebuilt
  `.xcframework` `.binaryTarget` rather than recompiling them through SwiftPM —
  in `GoMartNew/Package.swift`, GoogleMaps appears exactly as
  `.binaryTarget(name: "GoogleMaps", path: ".deps/GoogleMaps/GoogleMaps.xcframework")`.
  (At the app level, force-loading symbols — `-force_load` — and taming `+load`
  side effects were also part of the story; note that this *ruleset* does not
  itself emit `-force_load` linker flags — its lever is binarization plus
  `avoid_deps` to prevent duplicate-symbol blow-ups.)

- **Prebuilt library-evolution Swift binary xcframeworks.** A resilient
  (library-evolution) Swift binary such as **CourierProtos** can fail to
  link/load on the JIT preview path. Worse, a resilient binary expects *its* deps
  (e.g. **SwiftProtobuf**) to also expose a resilient ABI — but in the preview
  package those deps are compiled from source, which does not. There is no clean
  per-flag fix, which motivated two new escape hatches (commit `5f767a6`):
  - **`exclude_modules`** drops the offending module entirely: no
    target/binaryTarget, removed from every dependency array, and any dep source
    that `import`s it is skipped at copy time via the runtime grep guard (§5.1).
  - **`replace_sources`** swaps a specific dep source that references the dropped
    type for a hand-written, excluded-module-free **stub**, so files that still
    reference the type keep compiling.

- **Platform-gated wrapper modules.** Some SPM packages hide their real ObjC
  module behind a "Wrap"/`*Target` module whose edge to the real module is gated
  by a `select()` on `@platforms//os:ios`. In the previews **host** configuration
  that select resolves empty, so the aspect never sees the real module and
  importers fail with *"Unable to find module dependency"*. **FirebasePerformance**
  is the real example: `GoMartNew/BUILD.bazel` points `extra_binary_libs` at
  `@swiftpkg_firebase_ios_sdk//:FirebasePerformance.rspm_objc` and sets
  `binary_module_renames = {"FirebasePerformanceTarget": "FirebasePerformance"}`.

- **Private headers.** SwiftPM's generated umbrella header only exposes what the
  module-named header imports, hiding sibling private headers. **FBLPromises**
  (kept via `keep_as_source`) needs `FBLPromisePrivate.h`, handled by the
  umbrella-header patch (§5.3).

- **Swift language mode.** Some modules rely on Swift-6-only semantics (e.g.
  SE-0365 implicit-self in nested closures — `CVSDK`, `GotoLoginSDK`) and must
  opt into `swift6_modules`, while the rest stay at the working `.v5` baseline.

**Why this does not scale.** Each of the above is per-dependency surgery:
identify a load-time crash or link failure, attribute it to a specific module,
then pick the right lever (binarize, `keep_as_source`, `exclude_modules` +
`replace_sources`, `extra_binary_libs` + rename, or `swift6_modules`). For a
small leaf module this is tractable. For a large feature module like `GoMartNew`,
the full transitive graph is hundreds of modules deep (see the `GoMartNewDummy`
target's dependency array in `Package.swift`), and previewing it kept hitting new
load-time crashes that each required another round of investigation. The
package-target preview path (previewing a file that belongs to a package target,
with its complete hostile dependency graph) was the most fragile of all. The
whack-a-mole did not converge.

---

## 8. Why we pivoted to the Aloha Sandbox

Rather than fight to preview arbitrary large modules with their full (often
hostile) dependency graphs, the team pivoted to a single, fixed preview package —
the **"Aloha Sandbox"** at `LaunchpadHost/Previews` (target `GojekPreviews`).

The sandbox is wired to only the three clean, Swift-only UI design-system
modules:

- `//Pods/AlohaAssets:AlohaAssetsInternal`
- `//Pods/AlohaUI`
- `//Pods/AsphaltAloha`

These are first-party Swift source + resource bundles — no binary frameworks, no
ObjC `+load`, no library-evolution binaries — so the sandbox previews on the
plain SwiftPM package-target path and needs **no `swift_previews_gen` /
binarization at all**. Developers design a view in the sandbox, preview it
reliably, then copy-paste the finished view into its real module.

One wrinkle the sandbox handles: `AsphaltAlohaFramework`'s config provider
`fatalError`s in DEBUG when no provider is registered. The sandbox emits
`Sources/AlohaPreviewSupport.swift`, which registers a preview-only
`AlohaConfigProviding` (Liquid Glass disabled) through an idempotent
`AlohaPreview.bootstrap`. Every preview starts its body with `let _ =
AlohaPreview.bootstrap` so the provider is set before any themed view's `body`
reads a flag. See the app-side usage guide
(`scripts/swiftui_previews/PREVIEWS_GUIDE.md`) for the developer workflow.

The full-graph machinery documented above (§§2–7) still exists and still works
for tractable modules — the sandbox is the **recommended default**, not a removal
of the real-module path.

---

## 9. Map of the source tree

| File | Responsibility |
|---|---|
| `defs.bzl` | Public API: re-exports `swift_previews_package`, `swift_previews_gen`, `SourceFilesInfo`, `SWIFT_PREVIEW_EXCLUDES` |
| `internal/core.bzl` | Aspect, both rule impls, attrs, macros |
| `internal/providers.bzl` | `SourceFilesInfo` provider |
| `internal/swift_collector.bzl` | Swift sources + `swift_resources` / `apple_resource_bundle` resources |
| `internal/cc_collector.bzl` | `cc_library` sources/headers |
| `internal/objc_collector.bzl` | `objc_library` sources/public+private headers |
| `internal/package_generator.bzl` | `Package.swift` text generation |
| `internal/script_generator.bzl` | Copy-script generation (sources, resources, ObjC/C, xcframeworks, Phase-A collect, Package.swift write) |
| `internal/xcframework_generator.bzl` | Phase-A `apple_static_xcframework` BUILD generation |
| `tests/*.bzl` | analysis tests (`aspect_tests.bzl`), package-generator and script-generator unit tests, with fixtures under `tests/fixtures/` |

---

## 10. Quick reference — generated layout

```
Views/                         # the Bazel package holding the `previews` target
├── BUILD.bazel
├── <your sources>.swift
├── Package.swift              # GENERATED by `previews`
├── previews_xcfw/             # GENERATED by `previews_gen` (temp xcframework BUILD)
│   └── BUILD.bazel
└── .deps/                     # GENERATED by `previews`
    ├── <SwiftModule>/         # copied .swift + exclude: ["Package.swift"]
    ├── <ObjCModule>/          # .m/.h, include/, umbrella patch if kept-as-source
    ├── <XCFwModule>/<...>.xcframework
    └── <Module>Resources/Resources/
```

Run order is always: `bazel run //Views:previews_gen` (Phase A) **then** `bazel
run //Views:previews` (Phase B), both with `--nocheck_visibility`. Then open
`Views/Package.swift` in Xcode.
