import hashlib
import json
import pathlib
import re
import tarfile

folder = pathlib.Path(__file__).resolve().parent
root = folder.parents[3]
versions = json.loads((root / 'kiroku-store/bench/results/ep6-release/proposal/versions.json').read_text())
records = []

for package, (_, version) in versions.items():
    prefix = f'{package}-{version}'
    source = root / 'dist-newstyle/sdist' / f'{prefix}.tar.gz'
    docs_candidates = list((root / 'dist-newstyle').rglob(f'{prefix}-docs.tar.gz'))
    assert source.is_file(), source
    assert len(docs_candidates) == 1, docs_candidates
    docs = docs_candidates[0]
    cabal_path = root / package / f'{package}.cabal'
    cabal = cabal_path.read_text()
    # Collect exposed modules from each library, including public sublibraries.
    modules = []
    for block in re.finditer(r'^\s+exposed-modules:\s*\n((?:[ \t]+[^\n]*\n)*)', cabal, re.M):
        for line in block.group(1).splitlines():
            module = line.strip()
            if re.fullmatch(r'[A-Z][A-Za-z0-9_.]*', module):
                modules.append(module)
            else:
                break
    assert modules, package
    with tarfile.open(source) as archive:
        names = archive.getnames()
        def read(relative):
            return archive.extractfile(f'{prefix}/{relative}').read()
        assert read(f'{package}.cabal') == cabal_path.read_bytes()
        assert read('CHANGELOG.md') == (root / package / 'CHANGELOG.md').read_bytes()
        assert read('LICENSE') == (root / package / 'LICENSE').read_bytes()
        assert f'## {version}' in read('CHANGELOG.md').decode()
        assert 'license-file:' in cabal and 'LICENSE' in cabal
        for module in modules:
            suffix = '/' + module.replace('.', '/') + '.hs'
            assert any(name.endswith(suffix) for name in names), (package, module)
        if package == 'kiroku-store-migrations':
            for relative in ['migrations/manifest', 'migrations.lock']:
                assert read(relative) == (root / package / relative).read_bytes()
            manifest = (root / package / 'migrations/manifest').read_text().splitlines()
            assert manifest[-2:] == ['0013.sql', '0014.sql']
            for sql in (root / package).glob('migrations/*.sql'):
                assert read(str(sql.relative_to(root / package))) == sql.read_bytes()
    with tarfile.open(docs) as archive:
        names = archive.getnames()
        assert any(name.endswith('/doc-index.html') for name in names), package
        assert any(name.endswith('.haddock') for name in names), package
        for module in modules:
            html = '/' + module.replace('.', '-') + '.html'
            assert any(name.endswith(html) for name in names), (package, module, html)
    record = {'package': package, 'version': version, 'public_modules_checked': modules,
              'checks': ['exact Cabal metadata', 'changelog', 'license', 'public source modules',
                         'Hackage Haddock symbol index/interface/public module pages']}
    if package == 'kiroku-store-migrations':
        record['checks'].append('exact manifest, lock and all migration SQL payloads')
    for kind, path in [('source', source), ('docs', docs)]:
        record[kind] = {'path': str(path.relative_to(root)), 'bytes': path.stat().st_size,
                        'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
    records.append(record)
    print(f'{package} {version}: source/docs verified; {len(modules)} public modules')

(folder / 'archives.json').write_text(json.dumps(records, indent=2) + '\n')
