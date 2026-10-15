#!/usr/bin/env bash
# Emit the symbol graphs of every documented module of one checkout of the package.
#
#   scripts/emit-symbol-graphs.sh SOURCE OUTPUT
#
# SOURCE is a checkout of any version (release tag or main); OUTPUT receives one directory
# per module, each with `<Module>.symbols.json` and the module's extension graphs
# (`<Module>@<Other>.symbols.json`):
#
#   OUTPUT/DDDCore/DDDCore.symbols.json
#   OUTPUT/KurrentSupport/KurrentSupport.symbols.json
#   OUTPUT/KurrentSupport/KurrentSupport@KurrentDB.symbols.json
#
# The documented modules are the directories under SOURCE/Sources, minus EXCLUDED below, so
# every version documents the modules it actually has. A module without a symbol graph is an
# error: a new executable or demo target has to be added to EXCLUDED, not silently skipped.
#
# DOC_DEPENDENCY_PINS ("package@version ...") pins dependencies after resolving, for an
# upstream release that breaks the build (see .github/workflows/documentation.yml); a pin is
# skipped for a version that does not depend on that package.
set -euo pipefail

source=$(cd "$1" && pwd)
mkdir -p "$2"
output=$(cd "$2" && pwd)

# DDDKit only re-exports other modules; generate and DDDKitCLI are executables;
# TemplateVariablesDemo is a demo of the VariablesGeneratorPlugin.
EXCLUDED=" DDDKit generate DDDKitCLI TemplateVariablesDemo ProjectorGeneratorFixture "

graphs=$(mktemp -d)
cd "$source"
swift package resolve
for pin in ${DOC_DEPENDENCY_PINS:-}; do
  # Older versions may not depend on the pinned package at all.
  if grep -q "\"identity\" : \"${pin%@*}\"" Package.resolved; then
    swift package resolve "${pin%@*}" --version "${pin#*@}"
  else
    echo "note: ${pin%@*} is not a dependency of this version, not pinning it"
  fi
done
swift build \
  -Xswiftc -emit-symbol-graph \
  -Xswiftc -emit-symbol-graph-dir -Xswiftc "$graphs"

for directory in Sources/*/; do
  module=$(basename "$directory")
  [[ "$EXCLUDED" == *" $module "* ]] && continue
  if [[ ! -f "$graphs/$module.symbols.json" ]]; then
    echo "error: no symbol graph for $module; exclude it in $0 if it is not a library" >&2
    exit 1
  fi
  mkdir -p "$output/$module"
  cp "$graphs/$module.symbols.json" "$output/$module/"
  find "$graphs" -maxdepth 1 -name "$module@*.symbols.json" -exec cp {} "$output/$module/" \;
done
rm -rf "$graphs"
ls "$output"
