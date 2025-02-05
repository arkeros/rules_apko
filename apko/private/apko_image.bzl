"A rule for running apko with prepopulated cache"

load("//apko/private:apko_run.bzl", "apko_run")
load("@bazel_skylib//lib:paths.bzl", "paths")

_ATTRS = {
    "contents": attr.label(doc = "Label to the contents repository generated by translate_lock. See [apko-cache](./apko-cache.md) documentation.", mandatory = True),
    "config": attr.label(doc = "Label to the `apko.yaml` file.", allow_single_file = True, mandatory = True),
    "output": attr.string(default = "oci", values = ["oci", "docker"]),
    "architecture": attr.string(doc = "the CPU architecture which this image should be built to run on. See https://github.com/chainguard-dev/apko/blob/main/docs/apko_file.md#archs-top-level-element"),
    "tag": attr.string(doc = "tag to apply to the resulting docker tarball. only applicable when `output` is `docker`", mandatory = True),
    "args": attr.string_list(doc = "additional arguments to provide when running the `apko build` command."),
}

def _impl(ctx):
    apko_info = ctx.toolchains["@rules_apko//apko:toolchain_type"].apko_info

    cache_name = "cache_{}".format(ctx.label.name)

    if ctx.attr.output == "oci":
        output = ctx.actions.declare_directory(ctx.label.name)
    else:
        output = ctx.actions.declare_file("{}.tar".format(ctx.label.name))

    args = ctx.actions.args()
    args.add("build")
    args.add(ctx.file.config.path)
    args.add(ctx.attr.tag)
    args.add(output.path)

    args.add("--vcs=false")

    args.add_all(ctx.attr.args)

    args.add("--cache-dir={}".format(paths.join(ctx.bin_dir.path, ctx.label.workspace_root, ctx.label.package, cache_name)))
    args.add("--offline")

    if ctx.attr.architecture:
        args.add("--arch")
        args.add(ctx.attr.architecture)

    inputs = [ctx.file.config] + ctx.files.contents

    for content in ctx.files.contents:
        content_owner = content.owner.workspace_name
        content_cache_entry_key = content.path[content.path.find(content_owner) + len(content_owner) + 1:]
        content_entry = ctx.actions.declare_file("/".join([cache_name, content_cache_entry_key]))
        ctx.actions.symlink(
            target_file = content,
            output = content_entry,
        )
        inputs.append(content_entry)

    ctx.actions.run(
        executable = apko_info.binary,
        arguments = [args],
        inputs = inputs,
        outputs = [output],
    )

    return DefaultInfo(
        files = depset([output]),
    )

apko_image_lib = struct(
    attrs = _ATTRS,
    implementation = _impl,
    toolchains = ["@rules_apko//apko:toolchain_type"],
)

_apko_image = rule(
    implementation = apko_image_lib.implementation,
    attrs = apko_image_lib.attrs,
    toolchains = apko_image_lib.toolchains,
)

def apko_image(name, contents, config, tag, output = "oci", architecture = None, args = [], **kwargs):
    """Build OCI images from APK packages directly without Dockerfile

    This rule creates images using the 'apko.yaml' configuration file and relies on cache contents generated by [translate_lock](./translate_lock.md) to be fast.

    ```starlark
    apko_image(
        name = "example",
        config = "apko.yaml",
        contents = "@example_lock//:contents",
        tag = "example:latest",
    )
    ```

    The label `@example_lock//:contents` is generated by the `translate_lock` extension, which consumes an 'apko.resolved.json' file.
    For more details, refer to the [documentation](./docs/apko-cache.md).

    An example demonstrating usage with [rules_oci](https://github.com/bazel-contrib/rules_oci)

    ```starlark
    apko_image(
        name = "alpine_base",
        config = "apko.yaml",
        contents = "@alpine_base_lock//:contents",
        tag = "alpine_base:latest",
    )

    oci_image(
        name = "app",
        base = ":alpine_base"
    )
    ```

    For more examples checkout the [examples](/examples) directory.

    Args:
     name:         of the target for the generated image.
     contents:     Label to the contents repository generated by translate_lock. See [apko-cache](./apko-cache.md) documentation.
     config:       Label to the `apko.yaml` file.
     output:       "oci" of  "docker",
     architecture: the CPU architecture which this image should be built to run on. See https://github.com/chainguard-dev/apko/blob/main/docs/apko_file.md#archs-top-level-element"),
     tag:          tag to apply to the resulting docker tarball. only applicable when `output` is `docker`
     args:         additional arguments to provide when running the `apko build` command.
     **kwargs:       other common arguments like: tags, visibility.
    """
    _apko_image(
        name = name,
        config = config,
        contents = contents,
        output = output,
        architecture = architecture,
        tag = tag,
        args = args,
        **kwargs
    )
    config_label = native.package_relative_label(config)

    # We generate the `.resolve` target only if the config (apko.yaml file) is in the same package as the apko_image rule.
    if config_label.workspace_name == "" and config_label.package == native.package_name() and config_label.name.endswith(".yaml"):
        resolved_json_name = config_label.name.removesuffix(".yaml") + ".resolved.json"

        # We generate the .resolve target only if the `.apko.resolved.json` file exists in the same package.
        for _ in native.glob([resolved_json_name]):
            apko_run(
                name = name + ".resolve",
                args = ["resolve", config_label.package + "/" + config_label.name],
                workdir = "workspace",
            )
