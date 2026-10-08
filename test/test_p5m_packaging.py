import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('p5m_package', Path(__file__).resolve().parents[1] / 'mac/package.py')
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)

class PackagingTests(unittest.TestCase):
    def test_sdl3_dynamic_dependency(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / 'P5M.app'
            frameworks = app / 'Contents/Frameworks'
            frameworks.mkdir(parents=True)
            (frameworks / 'libSDL2-2.0.0.dylib').write_bytes(b'compat fixture')
            source = root / 'runtime'
            source.mkdir()
            (source / 'libSDL3.0.dylib').write_bytes(b'SDL3 fixture')
            (source / 'libSDL3.dylib').symlink_to('libSDL3.0.dylib')
            with patch.object(package, 'run', return_value='Failed loading SDL3 library.'):
                with self.assertRaisesRegex(RuntimeError, 'Missing bundled SDL3'):
                    package.validate_sdl3_runtime(app)
                with self.assertRaisesRegex(RuntimeError, 'not found'):
                    package.bundle_sdl3(app, [])
                inventory = package.bundle_sdl3(app, [source])
                self.assertIn('Contents/Frameworks/libSDL3.0.dylib', inventory)
                self.assertEqual((frameworks / 'libSDL3.dylib').read_bytes(), b'SDL3 fixture')
                self.assertEqual((frameworks / 'libSDL3.dylib').readlink(), Path('libSDL3.0.dylib'))
                package.validate_sdl3_runtime(app)
                self.assertEqual(package.bundle_sdl3(app, [source]), {})

    def test_dependency_dirs_follow_input_and_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            build = root / 'custom-build'
            steam = build / 'third-party/cpp-steam-tools'
            steam.mkdir(parents=True)
            sdl = root / 'custom-sdl/lib'
            sdl.mkdir(parents=True)
            extra = root / 'external/lib'
            extra.mkdir(parents=True)
            (build / 'CMakeCache.txt').write_text(
                f'PC_SDL2_LIBDIR:INTERNAL={sdl}\n'
                f'PC_SDL2_LIBRARY_DIRS:INTERNAL={sdl}\n')
            self.assertEqual(package.dependency_dirs(build / 'gui/chiaki.app', extra=[extra]),
                             [steam.resolve(), extra.resolve(), sdl.resolve()])
            self.assertEqual(package.dependency_dirs(root / 'other/app', build, [extra]),
                             [steam.resolve(), extra.resolve(), sdl.resolve()])

    def test_sdl_notices_follow_dependency_prefix(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'sdk'
            (source / 'lib').mkdir(parents=True)
            notice = source / 'share/licenses/SDL3/LICENSE.txt'
            notice.parent.mkdir(parents=True)
            notice.write_text('SDL license fixture')
            app = root / 'P5M.app'
            with patch.object(package, 'machos', return_value=[]), \
                 patch.object(package.shutil, 'which', return_value=None):
                package.licenses(app, {}, [source / 'lib'])
            bundled = list((app / 'Contents/Resources/ThirdPartyLicenses').rglob('SDL3/LICENSE.txt'))
            self.assertEqual(len(bundled), 1)
            self.assertEqual(bundled[0].read_text(), 'SDL license fixture')

    def test_real_sdl2_does_not_require_sdl3(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / 'P5M.app'
            frameworks = app / 'Contents/Frameworks'
            frameworks.mkdir(parents=True)
            (frameworks / 'libSDL2-2.0.0.dylib').write_bytes(b'SDL2 fixture')
            with patch.object(package, 'run', return_value='SDL2 original'):
                package.validate_sdl3_runtime(app)
                self.assertEqual(package.bundle_sdl3(app, []), {})

if __name__ == '__main__':
    unittest.main()
