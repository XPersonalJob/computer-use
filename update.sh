#!/bin/bash
# Refresh the Computer Use components from the ChatGPT desktop installers.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if (( $# )); then targets=("$@"); else targets=(darwin-arm64 win32-x64); fi
for target in "${targets[@]}"; do
  [[ "$target" == darwin-arm64 || "$target" == win32-x64 ]] || { echo "Usage: $0 [darwin-arm64|win32-x64]..." >&2; exit 1; }
done
python="$(command -v python3 || command -v python || true)"
[[ -n "$python" ]] || { echo 'Python 3 is required.' >&2; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/computer-use.XXXXXX")"
mounted=''
cleanup() {
  if [[ -n "$mounted" ]] && ! hdiutil detach "$mounted" -quiet; then
    echo "Could not unmount $mounted; keeping $work for manual cleanup." >&2
    return
  fi
  rm -rf "$work" "$root"/.staging-*
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

copy() {
  if [[ "$(uname -s)" == Darwin ]]; then
    # Preserves code signatures, modes and relative symlinks.
    ditto "$1" "$2"
  else
    mkdir -p "$(dirname "$2")"
    cp -pR "$1" "$2"
  fi
}

# Copy the runtime and plugin into Neo's layout, validate it, then replace the target.
install() {
  local target="$1" runtime="$2" plugin="$3" archive="$4"
  local staging="$root/.staging-$target"
  rm -rf "$staging"
  copy "$runtime" "$staging"
  copy "$plugin" "$staging/marketplace/plugins/computer-use"
  "$python" - "$staging" "$target" "$archive" <<'PY'
import json, os, sys

root, target, archive = sys.argv[1:]
platform, arch, node, repl, modules, helper = {
    'darwin-arm64': ('darwin', 'arm64', 'bin/node', 'bin/node_repl', 'lib/node_modules',
                     'lib/node_modules/@oai/sky/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService'),
    'win32-x64': ('windows', 'x64', 'bin/node.exe', 'bin/node_repl.exe', 'bin/node_modules',
                  'bin/node_modules/@oai/sky/bin/windows/codex-computer-use.exe'),
}[target]
plugin = 'marketplace/plugins/computer-use'
with open(os.path.join(root, plugin, '.codex-plugin/plugin.json')) as file:
    plugin_manifest = json.load(file)
if plugin_manifest.get('name') != 'computer-use':
    sys.exit('Expected the Computer Use plugin')

marketplace = os.path.join(root, 'marketplace/.agents/plugins')
os.makedirs(marketplace, exist_ok=True)
with open(os.path.join(marketplace, 'marketplace.json'), 'w') as file:
    json.dump({
        'name': 'neo-bundled',
        'interface': {'displayName': 'Neo Bundled'},
        'plugins': [{
            'name': 'computer-use',
            'source': {'source': 'local', 'path': './plugins/computer-use'},
            'policy': {'installation': 'AVAILABLE', 'authentication': 'ON_INSTALL'},
            'category': 'Productivity',
        }],
    }, file, indent=2)
with open(os.path.join(root, 'neo-source.json'), 'w') as file:
    json.dump({'archive': archive, 'pluginVersion': plugin_manifest.get('version')}, file, indent=2)

with open(os.path.join(root, 'manifest.json')) as file:
    manifest = json.load(file)
if not manifest.get('runtime_archive_version') or (
    manifest.get('platform'), manifest.get('arch'), manifest.get('node_path'),
    manifest.get('node_repl_path'), manifest.get('node_modules'),
) != (platform, arch, node, repl, modules):
    sys.exit(f'Computer Use runtime does not match {target}')
required = [node, repl, helper, f'{modules}/@oai/sky/package.json', f'{plugin}/skills/computer-use/SKILL.md']
if target == 'win32-x64':
    required += [f'{plugin}/docs/{name}.md' for name in ('api', 'guidance', 'confirmations')]
for name in required:
    if not os.path.exists(os.path.join(root, name)):
        sys.exit(f'Computer Use runtime is missing {name}')
# Links must stay inside the bundle, never point at the source installation.
real = os.path.realpath(root)
for directory, folders, files in os.walk(root):
    for name in folders + files:
        path = os.path.join(directory, name)
        if os.path.islink(path) and (
            os.path.isabs(os.readlink(path)) or not os.path.realpath(path).startswith(real + os.sep)
        ):
            sys.exit(f'Computer Use runtime contains an external link: {path}')
PY
  if [[ "$target" == darwin-arm64 ]]; then
    codesign --verify --strict "$staging/bin/node"
    codesign --verify --strict "$staging/bin/node_repl"
    codesign --verify --strict --deep "$staging/lib/node_modules/@oai/sky/Codex Computer Use.app"
  fi
  find "$staging" -name .DS_Store -delete
  rm -rf "${root:?}/$target"
  mv "$staging" "$root/$target"
  echo "Updated $target from $archive"
}

for target in "${targets[@]}"; do
  if [[ "$target" == darwin-arm64 ]]; then
    [[ "$(uname -s)" == Darwin ]] || { echo 'The macOS DMG can only be extracted on macOS.' >&2; exit 1; }
    installer="$work/ChatGPT.dmg"
    curl -fL --retry 5 --retry-all-errors -C - -o "$installer" https://persistent.oaistatic.com/codex-app-prod/ChatGPT.dmg
    mkdir "$work/dmg"
    hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$work/dmg" "$installer" -quiet
    mounted="$work/dmg"
    shopt -s nullglob
    apps=("$work/dmg"/*.app)
    shopt -u nullglob
    [[ ${#apps[@]} -eq 1 ]] || { echo 'Expected one application in the DMG.' >&2; exit 1; }
    resources="${apps[0]}/Contents/Resources"
    install "$target" "$resources/cua_node" "$resources/plugins/openai-bundled/plugins/computer-use" ChatGPT.dmg
    hdiutil detach "$mounted" -quiet
    mounted=''
  else
    installer="$work/ChatGPT-x64.msix"
    curl -fL --retry 5 --retry-all-errors -C - -o "$installer" https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix
    "$python" "$root/extract-msix.py" "$installer" "$work/msix"
    install "$target" "$work/msix/cua_node" "$work/msix/computer-use" ChatGPT-x64.msix
  fi
done
