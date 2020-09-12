# Copyright 2020 Google
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""
Rust Analyzer Bazel rules.

rust_analyzer will generate a rust-project.json file for the
given targets. This file can be consumed by rust-analyzer as an alternative
to Cargo.toml files.
"""

load("@io_bazel_rules_rust//rust:private/utils.bzl", "find_toolchain")

# We support only these rule kinds.
_rust_rules = [
    "rust_library",
    "rust_binary",
]

RustTargetInfo = provider(
    fields = {
        'name' : 'target name',
        'root' : 'crate root',
        'edition' : 'edition',
        'dependencies' : 'dependencies',
        'transitive_deps' : 'closure of all transitive dependencies',
        'cfgs' : 'compilation cfgs',
        'env' : 'Environment variables, used for the `env!` macro',
    }
)

# Gets the crate_root file from the context.
# If the file is not specified, find lib.rs or main.rs
# in a library or binary rule respectively.
def fetch_crate_root_file(ctx):
  crate_root = ctx.rule.attr.crate_root
  if not crate_root:
    if len(ctx.rule.attr.srcs) == 1:
      crate_root = ctx.rule.attr.srcs[0]
    else:
      for src in ctx.rule.attr.srcs:
        file_name = src.label.name
        crate_type = ctx.rule.attr.crate_type
        if crate_type == "bin" and file_name.endswith("main.rs"):
          crate_root = src
          break
        if crate_type == "rlib" or crate_type == "dylib":
          if file_name.endswith("lib.rs"):
            crate_root = src
            break
  # The rules are structured such that the crate_root path will always be
  # the first element in the in the depset
  crate_root = crate_root.files.to_list()[0].path

def _rust_project_aspect_impl(target, ctx):
  if ctx.rule.kind not in _rust_rules:
    return []

  info = ctx.toolchains["@io_bazel_rules_rust//rust:toolchain"]

  # extract the crate_root path
  edition = ctx.rule.attr.edition
  if not edition:
    edition = info.default_edition

  crate_name = ctx.rule.attr.name

  crate_root = fetch_crate_root_file(ctx)

  cfgs = []
  for feature in ctx.rule.attr.crate_features:
    cfgs.append("feature=\"" + feature + "\"")
  for flag in ctx.rule.attr.rustc_flags:
    # --cfg flags should be passed as well but as an atomic
    # config, not key/value
    if flag.startswith("--cfg"):
      cfgs.append(flag[6:])
  env = ctx.rule.attr.rustc_env

  deps = [dep[RustTargetInfo] for dep in ctx.rule.attr.deps if RustTargetInfo in dep]
  transitive_deps = depset(direct = deps, transitive = [dep[RustTargetInfo].transitive_deps for dep in ctx.rule.attr.deps if RustTargetInfo in dep])

  return [RustTargetInfo(
      name = crate_name,
      edition = edition,
      cfgs = cfgs,
      root= crate_root,
      env=env,
      dependencies = deps,
      transitive_deps = transitive_deps)]

rust_project_aspect = aspect(
    attr_aspects = ["deps"],
    implementation = _rust_project_aspect_impl,
    toolchains = [ "@io_bazel_rules_rust//rust:toolchain" ]
)

def create_crate(target):
  crate = dict()
  crate["name"] = target.name
  crate["ID"] = "ID-" + target.name
  crate["root_module"] = target.root
  crate["edition"] = target.edition
  # TODO(bwb): smarter heuristic for workpace member indexing
  crate["is_workspace_member"] = True
  deps = []
  for dep in target.dependencies:
    deps.append({
        "name": dep.name,
        "ID": "ID-" + dep.name,
    })

  alloc_dep = dict()
  alloc_dep["ID"] = "SYSROOT-alloc"
  alloc_dep["name"] = "alloc"
  deps.append(alloc_dep)

  core_dep = dict()
  core_dep["ID"] = "SYSROOT-core"
  core_dep["name"] = "core"
  deps.append(core_dep)

  std_dep = dict()
  std_dep["ID"] = "SYSROOT-std"
  std_dep["name"] = "std"
  deps.append(std_dep)

  crate["deps"] = deps
  crate["cfg"] = target.cfgs
  crate["env"] = target.env
  return crate

def populate_sysroot(ctx, crate_mapping, output):
  # Hardcode the relevant sysroot structure for now.
  # Anything smarter than this requires a Toml parser

  sysroot = ["alloc", "core", "std", "panic_abort", "unwind"]
  sysroot_deps_map = {
      "alloc": ["core"],
      "std": ["alloc", "core", "panic_abort", "unwind"],
  }

  root = ctx.attr.exec_root
  info = ctx.toolchains["@io_bazel_rules_rust//rust:toolchain"]

  idx = 0
  for sysroot_crate in sysroot:
    crate = dict()
    crate["ID"] = "SYSROOT-" + sysroot_crate
    crate["name"] = sysroot_crate
    crate["root_module"] =  root + "/" + info.rustc_src.label.workspace_root + "/src/lib" + sysroot_crate + "/lib.rs"
    crate["edition"] = "2018"
    # sysroot crates are rarely modified. Mark as not a member of the workspace
    # for faster indexing
    crate["is_workspace_member"] = False
    crate["cfg"] = []
    crate["env"] = {}
    crate["deps"] = []
    if sysroot_crate in sysroot_deps_map.keys():
      for dep in sysroot_deps_map[sysroot_crate]:
        crate["deps"].append({
            "ID": "SYSROOT-" + dep,
            "name": dep,
        })
    crate_mapping[crate["ID"]] = idx
    idx += 1
    output["crates"].append(crate)

  return idx

def _rust_project_impl(ctx):
  output = dict()
  output["crates"] = []

  crate_mapping = dict()

  # idx starts after the sysroot is already populated
  idx = populate_sysroot(ctx, crate_mapping, output)

  for target in ctx.attr.targets:
    for dep in target[RustTargetInfo].transitive_deps.to_list():
      crate = create_crate(dep)
      crate_mapping[crate["ID"]] = idx
      idx += 1
      output["crates"].append(crate)
  crate = create_crate(target[RustTargetInfo])
  output["crates"].append(crate)

  # Go through the targets a second time and fill in their dependencies
  # since we now have stable placement for their index.
  for crate in output["crates"]:
    for dep in crate["deps"]:
      crate_id = dep["ID"]
      dep["crate"] = crate_mapping[crate_id]
      # clean up ID for cleaner output
      dep.pop("ID", None)
    crate.pop("ID", None)

  ctx.actions.write(output = ctx.outputs.filename, content = struct(**output).to_json())

rust_analyzer = rule(
    attrs = {
        "targets": attr.label_list(
            aspects = [rust_project_aspect],
            doc = "List of all targets to be included in the index",
        ),
        "exec_root": attr.string(
            default = "__EXEC_ROOT__",
            doc = "Execution root of Bazel as returned by 'bazel info execution_root'.",
        ),
    },
    outputs = {
        "filename": "rust-project.json",
    },
    implementation = _rust_project_impl,
    toolchains = [ "@io_bazel_rules_rust//rust:toolchain" ]
)
