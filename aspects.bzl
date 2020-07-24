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

_rust_rules = [
    "rust_library",
    "rust_binary",
]

TargetInfo = provider(
    fields = {
        'name' : 'target name',
        'root' : 'crate root',
        'edition' : 'edition',
        'dependencies' : 'dependencies',
        'cfgs' : 'compilation cfgs',
        'env' : 'Environment variables, used for the `env!` macro',
    }
)

def _rust_project_aspect_impl(target, ctx):
  # We support only these rule kinds.
  if ctx.rule.kind not in _rust_rules:
    return []

  info = ctx.toolchains["@io_bazel_rules_rust//rust:toolchain"]

  # extract the crate_root path
  edition = ctx.rule.attr.edition
  if not edition:
    # TODO if edition isn't specified, default to what is in the rust toolchain
    edition = info.default_edition

  crate_name = ctx.rule.attr.name

  crate_root = ctx.rule.attr.crate_root
  if not crate_root:
    if len(ctx.rule.attr.srcs) == 1:
      crate_root = ctx.rule.attr.srcs[0]
    else:
      for src in ctx.rule.attr.srcs:
        # TODO check this logic
        if src.contains("lib.rs"):
          crate_root = src
          break
  # this will always be the first in the depset
  crate_root = crate_root.files.to_list()[0].path

  cfgs = ctx.rule.attr.crate_features
  env = ctx.rule.attr.rustc_env

  deps = []
  for dep in ctx.rule.attr.deps:
    deps.append(dep[TargetInfo])

  return [TargetInfo(name = crate_name, edition = edition, cfgs = cfgs, root= crate_root, env=env,dependencies = deps)]

rust_project_aspect = aspect(
    attr_aspects = ["deps"],
    implementation = _rust_project_aspect_impl,
    toolchains = [ "@io_bazel_rules_rust//rust:toolchain" ]
)

def create_crate(target):
  crate = dict()
  crate["name"] = target.name
  crate["root_module"] = target.root
  crate["edition"] = target.edition
  deps = []
  for dep in target.dependencies:
    crate_dep = dict()
    # We fill in the crate id in the second iteration over the crates
    crate_dep["crate"] = None
    crate_dep["name"] = dep.name
    deps.append(crate_dep)
  crate["deps"] = deps
  crate["cfg"] = target.cfgs
  crate["env"] = target.env
  return crate

def populate_sysroot(ctx, idx, crate_mapping, output):
  #TODO fill in sysroot
  root = ctx.attr.exec_root
  info = ctx.toolchains["@io_bazel_rules_rust//rust:toolchain"]

  for lib in info.rust_lib.files.to_list():
    print(root + "/" + lib.path)

  return

def _rust_project_impl(ctx):
  output = dict()
  output["crates"] = []

  crate_mapping = dict()

  idx = 0
  populate_sysroot(ctx, idx, crate_mapping, output)
  for target in ctx.attr.targets:
    for dep in target[TargetInfo].dependencies:
      crate = create_crate(dep)
      crate_mapping[crate["name"]] = idx
      idx += 1
      output["crates"].append(crate)
  crate = create_crate(target[TargetInfo])
  output["crates"].append(crate)

  # Go through the targets a second time and fill in their dependencies since we now have stable placement
  # for their index.
  for crate in output["crates"]:
    for dep in crate["deps"]:
      dep["crate"] = crate_mapping[dep["name"]]

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
