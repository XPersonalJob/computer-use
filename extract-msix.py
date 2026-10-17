"""Extract only Computer Use payloads, decoding MSIX package-part URI names."""
import shutil
import stat
import sys
import zipfile
from pathlib import Path, PurePosixPath
from urllib.parse import unquote


def extract(archive: Path, output: Path) -> None:
    prefixes = {
        'app/resources/cua_node/': 'cua_node',
        'app/resources/plugins/openai-bundled/plugins/computer-use/': 'computer-use',
    }
    seen = set()
    with zipfile.ZipFile(archive) as package:
        for member in package.infolist():
            name = unquote(member.filename)
            for prefix, destination in prefixes.items():
                if not name.startswith(prefix):
                    continue
                relative = name[len(prefix):]
                relative_path = PurePosixPath(relative)
                parts = relative_path.parts
                if relative_path.is_absolute() or '\\' in relative or any(part == '..' or ':' in part for part in parts):
                    raise ValueError(f'Unsafe MSIX entry: {member.filename}')
                if stat.S_ISLNK(member.external_attr >> 16):
                    raise ValueError(f'Unexpected MSIX symlink: {member.filename}')
                target = output / destination / relative
                key = str(target).casefold()
                if key in seen:
                    raise ValueError(f'Duplicate MSIX entry: {member.filename}')
                seen.add(key)
                if member.is_dir():
                    target.mkdir(parents=True, exist_ok=True)
                else:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with package.open(member) as source, target.open('wb') as sink:
                        shutil.copyfileobj(source, sink)
                break
    for required in ('cua_node/manifest.json', 'computer-use/.codex-plugin/plugin.json'):
        if not (output / required).is_file():
            raise ValueError(f'MSIX is missing {required}')


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit('Usage: extract-computer-use-msix.py <package.msix> <output>')
    extract(Path(sys.argv[1]), Path(sys.argv[2]))
