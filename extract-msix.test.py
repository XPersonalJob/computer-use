import importlib.util
import tempfile
import unittest
import zipfile
from pathlib import Path

spec = importlib.util.spec_from_file_location('extract_msix', Path(__file__).with_name('extract-msix.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ExtractTests(unittest.TestCase):
    def run_archive(self, entries, check):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / 'app.msix'
            with zipfile.ZipFile(archive, 'w') as package:
                package.writestr('app/resources/cua_node/manifest.json', '{}')
                package.writestr('app/resources/plugins/openai-bundled/plugins/computer-use/.codex-plugin/plugin.json', '{}')
                for name, data in entries:
                    package.writestr(name, data)
            check(archive, root / 'output')

    def test_decodes_msix_names_and_only_extracts_components(self):
        def check(archive, output):
            module.extract(archive, output)
            self.assertEqual((output / 'cua_node/bin/node_modules/@oai/sky/helper.dll').read_bytes(), b'unchanged')
            self.assertFalse((output / 'app.exe').exists())
        self.run_archive([
            ('app/resources/cua_node/bin/node_modules/%40oai/sky/helper.dll', b'unchanged'),
            ('app/app.exe', b'ignored'),
        ], check)

    def test_rejects_encoded_traversal_and_duplicate_names(self):
        for entries in [
            [('app/resources/cua_node/%2e%2e/escaped', b'x')],
            [('app/resources/cua_node/%2f%2fescaped', b'x')],
            [('app/resources/cua_node/bin/%40oai/a', b'x'), ('app/resources/cua_node/bin/@oai/a', b'y')],
        ]:
            with self.subTest(entries=entries):
                def check(archive, output):
                    with self.assertRaises(ValueError):
                        module.extract(archive, output)
                self.run_archive(entries, check)


if __name__ == '__main__':
    unittest.main()
