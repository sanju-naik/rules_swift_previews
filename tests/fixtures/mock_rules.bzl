def _apple_resource_bundle_impl(ctx):
    files = []
    files.extend(ctx.files.resources)
    files.extend(ctx.files.structured_resources)
    files.extend(ctx.files.infoplists)
    return [DefaultInfo(files = depset(files))]

apple_resource_bundle = rule(
    implementation = _apple_resource_bundle_impl,
    attrs = {
        "resources": attr.label_list(allow_files = True),
        "structured_resources": attr.label_list(allow_files = True),
        "infoplists": attr.label_list(allow_files = True),
        "bundle_name": attr.string(default = ""),
    },
)
