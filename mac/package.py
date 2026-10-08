#!/usr/bin/env python3
"""Empacota uma cópia independente; nunca altera a saída do compilador."""
import argparse
import hashlib
from functools import lru_cache
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
SYSTEM = ('/System/Library/', '/usr/lib/')
MAGICS = {b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xfe\xed\xfa\xce', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf'}


def run(*args):
    p = subprocess.run([str(x) for x in args], text=True, errors='replace', stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if p.returncode:
        raise RuntimeError(f"{args[0]} failed ({p.returncode}):\n{p.stdout}\n{p.stderr}")
    return p.stdout


def machos(app):
    result = []
    for path in app.rglob('*'):
        if path.is_file() and not path.is_symlink():
            with path.open('rb') as f:
                if f.read(4) in MAGICS:
                    result.append(path)
    return result


def deps(path):
    own = run('otool', '-D', path).splitlines()[1:]
    return [d for d in re.findall(r'^\s+(.+?) \(compatibility version', run('otool', '-L', path), re.M) if d not in own]


@lru_cache(maxsize=4096)
def _rpaths(path, stamp, size):
    return re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset', run('otool', '-l', path))

def rpaths(path):
    stat = path.stat()
    return _rpaths(path, stat.st_mtime_ns, stat.st_size)


def expand(value, loader, executable):
    return Path(value.replace('@loader_path', str(loader.parent)).replace('@executable_path', str(executable.parent)))


def resolve(dep, loader, executable, inherited=(), extra=()):
    if dep.startswith('@rpath/'):
        suffix = dep[len('@rpath/'):]
        choices = [expand(r, loader, executable) / suffix for r in rpaths(loader)]
        choices += [expand(r, executable, executable) / suffix for r in inherited]
        choices += [Path(r) / suffix for r in extra]
    else:
        choices = [expand(dep, loader, executable)]
    for path in choices:
        if path.exists():
            return path.resolve()
    raise RuntimeError(f'Unresolved dependency: {loader}: {dep}')


def version_tuple(v):
    return tuple(map(int, v.split('.')))


def min_os(path):
    lines = run('otool', '-l', path)
    versions = re.findall(r'\bminos ([\d.]+)', lines)
    versions += re.findall(r'cmd LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version ([\d.]+)', lines)
    if not versions:
        raise RuntimeError(f'Missing deployment target: {path}')
    return max(versions, key=version_tuple)


def uses_sdl3_compat(app):
    library = app / 'Contents/Frameworks/libSDL2-2.0.0.dylib'
    return library.is_file() and 'Failed loading SDL3 library.' in run('strings', '-a', library)


def bundle_sdl3(app, extras):
    # sdl2-compat usa dlopen: otool/macdeployqt não enxergam esta dependência.
    if not uses_sdl3_compat(app):
        return {}
    frameworks = app / 'Contents/Frameworks'
    alias = frameworks / 'libSDL3.dylib'
    if alias.is_file():
        if not alias.resolve().is_relative_to(frameworks.resolve()):
            raise RuntimeError('SDL3 runtime alias points outside the bundle')
        return {}
    source = next((Path(root) / 'libSDL3.dylib' for root in extras
                   if (Path(root) / 'libSDL3.dylib').is_file()), None)
    if source is None:
        raise RuntimeError('sdl2-compat requires the SDL3 dynamic runtime; libSDL3.dylib was not found')
    source = source.resolve()
    destination = frameworks / source.name
    if destination.exists():
        raise RuntimeError('Unexpected existing SDL3 runtime without its loader alias')
    shutil.copy2(source, destination)
    if alias != destination:
        alias.symlink_to(destination.name)
    return {str(destination.relative_to(app)): {
        'source': str(source), 'sha256_before_relink': hashlib.sha256(source.read_bytes()).hexdigest()}}


def validate_sdl3_runtime(app):
    if uses_sdl3_compat(app):
        runtime = app / 'Contents/Frameworks/libSDL3.dylib'
        if not runtime.is_file() or not runtime.resolve().is_relative_to(app.resolve()):
            raise RuntimeError('Missing bundled SDL3 runtime required by sdl2-compat')


def smoke_sdl_runtime(app):
    # Carrega a cadeia real do compat sem janela, áudio, controle ou rede.
    library = app / 'Contents/Frameworks/libSDL2-2.0.0.dylib'
    if not library.is_file():
        return
    environment = os.environ.copy()
    for key in ('SDL3_LIBRARY', 'SDL_DYNAMIC_API', 'SDL3_DYNAMIC_API',
                'DYLD_LIBRARY_PATH', 'DYLD_FALLBACK_LIBRARY_PATH', 'DYLD_FRAMEWORK_PATH'):
        environment.pop(key, None)
    code = """import ctypes, sys
lib = ctypes.CDLL(sys.argv[1])
lib.SDL_Init.argtypes = [ctypes.c_uint32]
lib.SDL_Init.restype = ctypes.c_int
if lib.SDL_Init(0) != 0:
    lib.SDL_GetError.restype = ctypes.c_char_p
    raise RuntimeError(lib.SDL_GetError().decode())
lib.SDL_Quit()
print('SDL runtime load passed (no subsystems initialized)')
"""
    result = subprocess.run([sys.executable, '-c', code, str(library)], env=environment,
                            text=True, capture_output=True, timeout=30)
    if result.returncode:
        raise RuntimeError('Bundled SDL runtime load failed: ' + result.stdout + result.stderr)
    return result.stdout.strip()


def audit(app):
    validate_sdl3_runtime(app)
    for link in app.rglob('*'):
        if link.is_symlink() and not link.resolve().is_relative_to(app.resolve()):
            raise RuntimeError(f'External symlink in bundle: {link}')
    executable = app / 'Contents/MacOS' / plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleExecutable']
    files = machos(app)
    required_arches = set(run('lipo', '-archs', executable).split())
    records = []
    for path in files:
        arches = set(run('lipo', '-archs', path).split())
        if not required_arches.issubset(arches):
            raise RuntimeError(f'Incompatible architectures: {path}: {sorted(arches)}')
        for dep in deps(path):
            if dep.startswith(SYSTEM):
                continue
            resolved = resolve(dep, path, executable, rpaths(executable))
            if not resolved.is_relative_to(app.resolve()):
                raise RuntimeError(f'External dependency: {path}: {dep}')
        for rp in rpaths(path):
            resolved = expand(rp, path, executable).resolve()
            if not resolved.is_relative_to(app.resolve()):
                raise RuntimeError(f'External rpath: {path}: {rp}')
        records.append({'binary': str(path.relative_to(app)), 'minimum_macos': min_os(path)})
    required = max((r['minimum_macos'] for r in records), key=version_tuple)
    declared = plistlib.loads((app / 'Contents/Info.plist').read_bytes()).get('LSMinimumSystemVersion', '0')
    return {'minimum_macos': required, 'declared_minimum_macos': declared, 'binaries': records}


def vendor(app, extras):
    executable = app / 'Contents/MacOS' / plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleExecutable']
    frameworks = app / 'Contents/Frameworks'
    frameworks.mkdir(exist_ok=True)
    qtpaths = shutil.which('qtpaths') or shutil.which('qtpaths6')
    qtlibs = [Path(run(qtpaths, '--query', 'QT_INSTALL_LIBS').strip())] if qtpaths else []
    extras = [frameworks, *extras, *qtlibs]
    origins = {}
    copied = {}
    inventory = bundle_sdl3(app, extras)
    for relative, entry in inventory.items():
        origins[app / relative] = Path(entry["source"])
    pending = machos(app)
    processed = set()
    while pending:
        path = pending.pop()
        if path in processed:
            continue
        processed.add(path)
        origin = origins.get(path, path)
        if run('otool', '-D', path).splitlines()[1:] and path.is_relative_to(frameworks):
            run('install_name_tool', '-id', '@rpath/' + str(path.relative_to(frameworks)), path)
        for dep in deps(path):
            if dep.startswith(SYSTEM):
                continue
            source = resolve(dep, origin, executable, rpaths(executable), extras)
            if source.is_relative_to(app.resolve()):
                destination = source
            elif source in copied:
                destination = copied[source]
            else:
                parts = source.parts
                index = next((i for i, s in enumerate(parts) if s.endswith('.framework')), None)
                if index is not None:
                    framework_source = Path(*parts[:index + 1])
                    framework_dest = frameworks / framework_source.name
                    if not framework_dest.exists():
                        shutil.copytree(framework_source, framework_dest, symlinks=True)
                        for binary in machos(framework_dest):
                            origins[binary] = framework_source / binary.relative_to(framework_dest)
                            pending.append(binary)
                    destination = framework_dest / source.relative_to(framework_source)
                else:
                    destination = frameworks / source.name
                    if destination.exists() and destination.resolve() != source:
                        source_uuid = re.findall(r'uuid ([A-Fa-f0-9-]+)', run('otool', '-l', source))
                        target_uuid = re.findall(r'uuid ([A-Fa-f0-9-]+)', run('otool', '-l', destination))
                        if not source_uuid or source_uuid != target_uuid:
                            raise RuntimeError(f'Dependency filename collision: {source.name}')
                    else:
                        shutil.copy2(source, destination)
                    origins[destination] = source
                    pending.append(destination)
                copied[source] = destination
                inventory[str(destination.relative_to(app))] = {'source': str(source), 'sha256_before_relink': hashlib.sha256(source.read_bytes()).hexdigest()}
            relative = os.path.relpath(destination, path.parent)
            run('install_name_tool', '-change', dep, '@loader_path/' + relative, path)
        # Dependências agora são relativas ao carregador. Rpaths externos não viajam.
        for rp in set(rpaths(path)):
            if not expand(rp, path, executable).resolve().is_relative_to(app.resolve()):
                run('install_name_tool', '-delete_rpath', rp, path)
    return inventory


BOTTLE_TAG_MACOS = {'arm64_tahoe': '26.0', 'arm64_sequoia': '15.0', 'arm64_sonoma': '14.0'}


def _uuid(path):
    return tuple(re.findall(r'uuid ([A-Fa-f0-9-]+)', run('otool', '-l', path)))


def _cellar_by_name(cellar):
    index = {}
    # Pelo nome do arquivo e dos symlinks (libfoo.3.dylib -> libfoo.3.2.1.dylib).
    for path in cellar.glob('*/*/**/*'):
        if path.is_file():
            real = path.resolve()
            if real.is_relative_to(cellar):
                index.setdefault(path.name, []).append(real)
    return index


def _bottle_keg(formula, tag, scratch):
    # Garrafas da mesma fórmula feitas para um macOS anterior, baixadas do
    # registro oficial do Homebrew com o SHA-256 que a API publica. O Homebrew
    # local só conhece as garrafas do próprio macOS e não é tocado.
    target = scratch / tag / formula
    if not target.is_dir():
        api = json.loads(run('curl', '-fsSL', '--retry', '5', '--retry-all-errors', f'https://formulae.brew.sh/api/formula/{formula}.json'))
        bottle = api['bottle']['stable']['files'].get(tag)
        if not bottle:
            raise RuntimeError(f'No {tag} bottle for {formula}')
        tarball = scratch / f'{formula}-{tag}.tar.gz'
        run('curl', '-fsSL', '--retry', '5', '--retry-all-errors', '-H', 'Authorization: Bearer QQ==', '-o', tarball, bottle['url'])
        if hashlib.sha256(tarball.read_bytes()).hexdigest() != bottle['sha256']:
            raise RuntimeError(f'SHA-256 mismatch for the {tag} bottle of {formula}')
        target.mkdir(parents=True)
        run('tar', '-xzf', tarball, '-C', target)
        tarball.unlink()
    kegs = [k for k in (target / formula).iterdir() if k.is_dir()]
    if len(kegs) != 1:
        raise RuntimeError(f'Unexpected bottle layout for {formula}: {kegs}')
    return kegs[0]


def _installed_name(dep, cellar):
    # Garrafas citam o symlink (libavutil.61.dylib); o pacote guarda o arquivo
    # real que o Homebrew instalado resolve (libavutil.61.1.100.dylib).
    m = re.match(r'@@HOMEBREW_(?:CELLAR@@/([^/]+)/[^/]+|PREFIX@@/opt/([^/]+))/(.+)', dep)
    if not m:
        return None
    local = cellar.parent / 'opt' / (m.group(1) or m.group(2)) / m.group(3)
    return local.resolve().name if local.exists() else None


def _relink_bottle(app, path, tag, scratch, cellar, by_name, inventory):
    # Dependências da garrafa: o que o pacote já tem, ou (quando a garrafa
    # antiga foi compilada com outra opção, ex. freetype com brotli) a garrafa
    # dessa dependência, copiada para Frameworks e religada do mesmo jeito.
    frameworks = app / 'Contents/Frameworks'
    for dep in deps(path):
        if dep.startswith(SYSTEM):
            continue
        name = Path(dep).name
        mapped = by_name.get(name) or by_name.get(_installed_name(dep, cellar))
        if mapped is None:
            bundled = frameworks / name
            if not bundled.exists():
                m = re.match(r'@@HOMEBREW_(?:CELLAR@@/([^/]+)/[^/]+|PREFIX@@/opt/([^/]+))/(.+)', dep)
                if not m:
                    raise RuntimeError(f'{path.relative_to(app)} ({tag}) needs {dep}')
                formula = m.group(1) or m.group(2)
                keg = _bottle_keg(formula, tag, scratch)
                source = (keg / m.group(3)).resolve()
                shutil.copyfile(source, bundled)
                os.chmod(bundled, 0o755)
                run('install_name_tool', '-id', '@rpath/' + name, bundled)
                _relink_bottle(app, bundled, tag, scratch, cellar, {}, inventory)
                for rp in rpaths(bundled):
                    run('install_name_tool', '-delete_rpath', rp, bundled)
                notices = app / 'Contents/Resources/ThirdPartyLicenses' / f'{formula}-{keg.name}'
                for notice in keg.glob('*'):
                    if notice.is_file() and re.match(r'(LICEN[CS]E|COPYING|NOTICE|AUTHORS)', notice.name, re.I):
                        notices.mkdir(parents=True, exist_ok=True)
                        shutil.copy2(notice, notices / notice.name)
                inventory[str(bundled.relative_to(app))] = {
                    'source': str(source), 'bottle': f'{formula} {tag}',
                    'sha256_before_relink': hashlib.sha256(source.read_bytes()).hexdigest()}
            mapped = '@loader_path/' + os.path.relpath(bundled, path.parent)
        if mapped != dep:
            run('install_name_tool', '-change', dep, mapped, path)


def retarget(app, tag, inventory, scratch):
    """Troca binários do Homebrew feitos para um macOS mais novo pelas garrafas de `tag`.

    O Homebrew deste Mac instala garrafas do macOS dele; a mesma fórmula tem
    garrafas para versões anteriores. Cada binário é achado no Cellar pelo UUID
    (install_name_tool não o altera), substituído pelo da garrafa e religado
    com os mesmos caminhos que o original já tinha dentro do pacote."""
    floor = BOTTLE_TAG_MACOS[tag]
    cellar = Path(run(shutil.which('brew'), '--cellar').strip())
    index = None
    for path in machos(app):
        if version_tuple(min_os(path)) <= version_tuple(floor):
            continue
        if index is None:
            index = _cellar_by_name(cellar)
        uuid = _uuid(path)
        origin = next((c for c in index.get(path.name, []) if _uuid(c) == uuid), None)
        if origin is None:
            raise RuntimeError(f'No Homebrew origin for {path.relative_to(app)} (needs macOS {min_os(path)})')
        formula, version = origin.relative_to(cellar).parts[:2]
        relative = origin.relative_to(cellar / formula / version)
        replacement = _bottle_keg(formula, tag, scratch) / relative
        if not replacement.is_file():
            raise RuntimeError(f'{relative} missing from the {tag} bottle of {formula}')

        own_id = run('otool', '-D', path).splitlines()[1:]
        by_name = {Path(d).name: d for d in deps(path)}
        old_rpaths = rpaths(path)
        mode = path.stat().st_mode
        path.unlink()
        shutil.copyfile(replacement, path)
        os.chmod(path, mode | stat.S_IWUSR)
        if own_id:
            run('install_name_tool', '-id', own_id[0], path)
        _relink_bottle(app, path, tag, scratch, cellar, by_name, inventory)
        for rp in rpaths(path):
            run('install_name_tool', '-delete_rpath', rp, path)
        for rp in dict.fromkeys(old_rpaths):
            run('install_name_tool', '-add_rpath', rp, path)
        if version_tuple(min_os(path)) > version_tuple(floor):
            raise RuntimeError(f'{relative} from the {tag} bottle still needs macOS {min_os(path)}')
        # 'source' continua apontando o Cellar, de onde saem as licenças.
        inventory[str(path.relative_to(app))] = {
            'source': str(origin), 'bottle': f'{formula} {tag}',
            'sha256_before_relink': hashlib.sha256(replacement.read_bytes()).hexdigest()}


def dependency_dirs(input_app, build_dir=None, extra=()):
    # A árvore de build acompanha --input; o cache fornece o prefixo SDL real.
    build = Path(build_dir).resolve() if build_dir else Path(input_app).resolve().parent.parent
    result = [build / 'third-party/cpp-steam-tools', *(Path(p).resolve() for p in extra)]
    cache = build / 'CMakeCache.txt'
    if cache.is_file():
        for line in cache.read_text().splitlines():
            if re.match(r'PC_SDL2_(?:LIBDIR|LIBRARY_DIRS):', line):
                result.extend(Path(p) for p in line.partition('=')[2].split(';') if p)
    return list(dict.fromkeys(p.resolve() for p in result if p.is_dir()))


def licenses(app, inventory, extras=()):
    target = app / 'Contents/Resources/ThirdPartyLicenses'
    target.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / 'COPYING', target / 'P5M-AGPL-3.0.txt')
    shutil.copytree(ROOT / 'LICENSES', target / 'ProjectLicenses', dirs_exist_ok=True)
    roots = {p for p in (ROOT / 'third-party').iterdir() if p.is_dir()}
    roots.update(Path(r['source']).parent for r in inventory.values())
    brew_command = shutil.which('brew')
    brew = Path(run(brew_command, '--cellar').strip()) if brew_command else None
    roots.update(Path(p).parent for p in extras)
    # Inclui os notices de todos os componentes que macdeployqt copiou também.
    for binary in machos(app):
        for p in brew.glob('*/*') if brew else ():
            if binary.name.startswith('lib' + p.parent.name) or (binary.name.startswith('Qt') and p.parent.name.startswith('qt')):
                roots.add(p)
    for value in inventory.values():
        source = Path(value['source'])
        if brew and source.is_relative_to(brew):
            roots.add(brew / source.relative_to(brew).parts[0] / source.relative_to(brew).parts[1])
    for source in sorted(roots):
        if not source.exists():
            continue
        name = source.parent.name + '-' + source.name
        for f in source.iterdir():
            if f.is_file() and re.match(r'(?i)(copying|license|notice|copyright)', f.name):
                dest = target / name
                dest.mkdir(exist_ok=True)
                shutil.copy2(f, dest / f.name)
        receipt = source / 'INSTALL_RECEIPT.json'
        if receipt.exists():
            dest = target / name
            dest.mkdir(exist_ok=True)
            data = json.loads(receipt.read_text())
            public_receipt = {k: data[k] for k in ('homebrew_version', 'compiler', 'arch', 'built_as_bottle', 'runtime_dependencies') if k in data}
            source_metadata = data.get('source', {})
            public_receipt['source'] = {k: source_metadata[k] for k in ('spec', 'versions', 'tap_git_head') if k in source_metadata}
            (dest / receipt.name).write_text(json.dumps(public_receipt, indent=2) + '\n')
        for dirname in ('LICENSES', 'licenses', 'share/licenses'):
            if (source / dirname).is_dir():
                shutil.copytree(source / dirname, target / name / 'licenses', dirs_exist_ok=True)
    (target / 'README.txt').write_text('P5M is distributed under AGPL-3.0. This bundle includes dependencies with their own licenses.\nThe release must be accompanied by the exact Corresponding Source, including these packaging scripts and dependency build instructions.\nHomebrew package receipts and full license texts must be reviewed before a public release.\n', encoding='utf-8')




def strip_debug(app):
    # Remove DWARF/STABS só da cópia; símbolos Swift e App Intents continuam.
    for binary in machos(app):
        binary.chmod(binary.stat().st_mode | stat.S_IWUSR)
        run('strip', '-S', binary)


def privacy_audit(app):
    resources = app / 'Contents/Resources'
    candidates = list((resources / 'ThirdPartyLicenses').rglob('*'))
    candidates.append(resources / 'packaging-manifest.json')
    candidates += list((resources / 'Metadata.appintents').rglob('*'))
    forbidden = re.compile(r'/Users/|PSMeta|\b192\.168\.\d+\.\d+\b|\b10\.\d+\.\d+\.\d+\b|\b172\.(?:1[6-9]|2\d|3[01])\.\d+\.\d+\b|' + re.escape(Path.home().name), re.I)
    for path in candidates:
        if path.is_file() and forbidden.search(path.read_text(errors='ignore')):
            raise RuntimeError(f'Private build data in packaged notice/manifest: {path.relative_to(app)}')


def sign(app, identity, entitlements):
    # O Qt local pode conter Versions/Resources vazio, que codesign trata
    # como outra versão inválida. Normaliza só a cópia de distribuição.
    for framework in app.rglob('*.framework'):
        stray = framework / 'Versions/Resources'
        if stray.is_dir() and not stray.is_symlink() and not list(stray.iterdir()):
            stray.rmdir()
    common = ['codesign', '--force', '--sign', identity]
    if identity != '-':
        common += ['--options', 'runtime', '--timestamp']
    for binary in sorted(machos(app), key=lambda p: len(p.parts), reverse=True):
        args = common.copy()
        if entitlements and '/MacOS/' in str(binary):
            args += ['--entitlements', entitlements]
        run(*args, binary)
    bundles = [p for p in app.rglob('*') if p.is_dir() and not p.is_symlink() and p.suffix in ('.app', '.framework', '.xpc', '.bundle')]
    for bundle in sorted(bundles, key=lambda p: len(p.parts), reverse=True):
        args = common.copy()
        if entitlements and bundle.suffix in ('.app', '.xpc'):
            args += ['--entitlements', entitlements]
        run(*args, bundle)
    args = common.copy()
    if entitlements:
        args += ['--entitlements', entitlements]
    run(*args, app)
    run('codesign', '--verify', '--deep', '--strict', '--verbose=2', app)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path, default=ROOT / 'build-mac/gui/chiaki.app')
    parser.add_argument('--output', type=Path, default=ROOT / 'dist/P5M.app')
    parser.add_argument('--build-dir', type=Path, help='Build tree; inferred from --input when omitted')
    parser.add_argument('--dependency-dir', action='append', type=Path, default=[],
                        help='Additional native library directory (repeatable); includes its prefix notices')
    parser.add_argument('--audit-only', type=Path)
    parser.add_argument('--identity', default='-', help='Installed Developer ID identity, or - for local ad-hoc signature')
    parser.add_argument('--entitlements', type=Path, help='Reviewed entitlements for Developer ID / WebEngine')
    parser.add_argument('--macdeployqt', default=shutil.which('macdeployqt'))
    parser.add_argument('--bottle-tag', choices=sorted(BOTTLE_TAG_MACOS),
                        help='Swap Homebrew binaries built for a newer macOS for the bottles of this tag (e.g. arm64_tahoe for macOS 26)')
    args = parser.parse_args()
    if args.audit_only:
        report = audit(args.audit_only.resolve())
        if version_tuple(report['declared_minimum_macos']) < version_tuple(report['minimum_macos']):
            raise RuntimeError('Info.plist promises an unsupported macOS version')
        print(json.dumps(report, indent=2))
        return
    if args.output.exists():
        raise RuntimeError('Output exists. Choose a new --output; existing artifacts are preserved.')
    if not args.macdeployqt:
        raise RuntimeError('macdeployqt not found')
    if args.identity != '-':
        installed = run('security', 'find-identity', '-v', '-p', 'codesigning')
        if not any(args.identity in line and 'Developer ID Application:' in line for line in installed.splitlines()):
            raise RuntimeError('Requested Developer ID identity is not installed in Keychain')
    if args.identity != '-' and not args.entitlements:
        raise RuntimeError('Developer ID signing requires explicit reviewed --entitlements (QtWebEngine JIT).')
    app = args.output.resolve()
    app.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(args.input.resolve(), app, symlinks=True)
    extras = dependency_dirs(args.input, args.build_dir, args.dependency_dir)
    print('Relocating native dependencies...', flush=True)
    inventory = vendor(app, extras)
    print('Deploying Qt Quick and WebEngine...', flush=True)
    run(args.macdeployqt, app, '-qmldir=' + str(ROOT / 'gui/src/qml'), '-always-overwrite', '-no-strip', '-no-codesign')
    if not (app / 'Contents/PlugIns/platforms/libqcocoa.dylib').exists():
        raise RuntimeError('Qt Cocoa platform plugin missing after deployment')
    if not list(app.rglob('QtWebEngineProcess.app')):
        raise RuntimeError('QtWebEngine helper missing after deployment')
    inventory.update(vendor(app, extras))
    if args.bottle_tag:
        print(f'Swapping in {args.bottle_tag} bottles...', flush=True)
        scratch = app.parent / ('.bottles-' + app.stem)
        scratch.mkdir(exist_ok=True)
        retarget(app, args.bottle_tag, inventory, scratch)
    print('Removing private debug paths from distribution binaries...', flush=True)
    strip_debug(app)
    print('Collecting notices and auditing Mach-O binaries...', flush=True)
    licenses(app, inventory, extras)
    report = audit(app)
    plist_path = app / 'Contents/Info.plist'
    info = plistlib.loads(plist_path.read_bytes())
    info['LSMinimumSystemVersion'] = max(info.get('LSMinimumSystemVersion', '0'), report['minimum_macos'], key=version_tuple)
    plist_path.write_bytes(plistlib.dumps(info))
    report = audit(app)
    private_paths = []
    for binary in machos(app):
        strings = run('strings', '-a', binary)
        if '/Users/' + Path.home().name in strings or 'PSMeta' in strings:
            private_paths.append(str(binary.relative_to(app)))
    report['private_binary_paths_after_strip'] = private_paths
    if private_paths:
        raise RuntimeError('Private path constants remain after strip in: ' + ', '.join(private_paths))
    report['signature'] = 'ad-hoc (not notarized)' if args.identity == '-' else 'Developer ID (not notarized)'
    report['dependencies'] = inventory
    # O manifesto público não inclui caminhos pessoais da máquina de build.
    public = json.loads(json.dumps(report))
    for dependency in public['dependencies'].values():
        dependency['source'] = Path(dependency['source']).name
    (app / 'Contents/Resources/packaging-manifest.json').write_text(json.dumps(public, indent=2) + '\n')
    privacy_audit(app)
    print('Signing and verifying the bundle...', flush=True)
    sign(app, args.identity, args.entitlements)
    print(smoke_sdl_runtime(app), flush=True)
    archive = app.with_suffix('.zip')
    if archive.exists():
        raise RuntimeError('Archive exists; choose a new output name')
    run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, archive)
    print(json.dumps({'app': str(app), 'archive': str(archive), 'minimum_macos': report['minimum_macos'], 'binaries': len(report['binaries']), 'signature': report['signature']}, indent=2))


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError) as error:
        sys.exit(str(error))
