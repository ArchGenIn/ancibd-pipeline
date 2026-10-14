#!/usr/bin/env python3
"""Safety regressions for wrappers, preprocessing paths, and TSV utilities.

Tests use disposable files and a fake Apptainer/bcftools executable; no
scientific inputs or container environment are needed.
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

FAKE_APPTAINER = '''#!/usr/bin/env python3
import os, pathlib, sys
args = sys.argv[1:]
i = 1
while i < len(args):
    if args[i] in ('--bind', '--env', '--pwd'):
        i += 2
    elif args[i] == '--cleanenv':
        i += 1
    else:
        i += 1  # image path
        break
if i >= len(args) or args[i] != 'bcftools':
    sys.exit(5)
a = args[i+1:]
if a[0] in ('view', 'merge'):
    out = a[a.index('-o')+1]
    pathlib.Path(out).write_bytes(b'NEW-BCF')
    if os.environ.get('FAKE_FAIL_VIEW') == '1':
        sys.exit(6)
elif a[0] == 'index':
    if '-n' in a:
        print('17')
    else:
        path = a[-1]
        pathlib.Path(path + '.csi').write_bytes(b'NEW-INDEX')
        if os.environ.get('FAKE_FAIL_INDEX') == '1':
            sys.exit(7)
elif a[0] == 'query' and '-l' in a:
    print('A')
else:
    sys.exit(8)
'''


def run_cmd(cmd: list[str | Path], env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run([str(x) for x in cmd], text=True, capture_output=True, env=env)


class SafetyTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.tmp = Path(self.temp.name)
        self.repo = self.tmp / 'repo'
        (self.repo / 'config').mkdir(parents=True)
        shutil.copytree(ROOT / 'scripts', self.repo / 'scripts')
        (self.repo / 'scripts' / 'preprocess').mkdir(exist_ok=True)
        self.data = self.tmp / 'data'
        self.data.mkdir()
        self.bin = self.tmp / 'bin'
        self.bin.mkdir()
        apptainer = self.bin / 'apptainer'
        apptainer.write_text(FAKE_APPTAINER, encoding='utf-8')
        apptainer.chmod(0o755)
        (self.repo / 'config' / 'local.env').write_text(
            f'SIF_IMAGE={self.tmp}/image.sif\nDATA_ROOT={self.data}\n'
            f'HDF5_ROOT={self.data}\nRUNS_ROOT={self.tmp}/runs\nBATCH_SIZE=2\n'
            'CH_RANGE=1-1\n', encoding='utf-8'
        )
        self.env = {**os.environ, 'PATH': f'{self.bin}:{os.environ["PATH"]}'}
        (self.data / 'chr1.in.bcf').write_bytes(b'INPUT')
        (self.data / 'chr1.other.bcf').write_bytes(b'OTHER')
        (self.data / 'chr1.targets.txt').write_text('1\t100\n')
        (self.data / 'samples.txt').write_text('A\n')
        self.src = self.data / 'chr1.in.bcf'
        self.dst = self.data / 'chr1.out.bcf'
        self.scripts = self.repo / 'scripts'

    def opts(self, name: str) -> list[str]:
        if name == 'downsample':
            return ['--in-template', str(self.data / 'chr{chr}.in.bcf'),
                    '--out-template', str(self.data / 'chr{chr}.out.bcf'),
                    '--targets-dir', str(self.data), '--target-template', 'chr{chr}.targets.txt']
        if name == 'subset':
            return ['--in-template', str(self.data / 'chr{chr}.in.bcf'),
                    '--out-template', str(self.data / 'chr{chr}.out.bcf'),
                    '--samples', str(self.data / 'samples.txt')]
        return ['--first-template', str(self.data / 'chr{chr}.in.bcf'),
                '--second-template', str(self.data / 'chr{chr}.other.bcf'),
                '--out-template', str(self.data / 'chr{chr}.out.bcf')]

    def utility(self, name: str, extra: list[str], env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        return run_cmd(['bash', self.scripts / 'preprocess' / f'{name}_bcfs.sh',
                        *self.opts(name), '--chroms', '1-1', '--force', *extra], env or self.env)

    def test_sidecar_cannot_alias_input_bcf(self) -> None:
        for name in ('merge', 'subset'):
            with self.subTest(name=name):
                result = self.utility(name, ['--samples-out', str(self.src)])
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.src.read_bytes(), b'INPUT')

    def test_sidecar_cannot_alias_another_output(self) -> None:
        for name in ('merge', 'subset'):
            with self.subTest(name=name):
                result = self.utility(name, ['--samples-out', str(self.dst)])
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.src.read_bytes(), b'INPUT')

    def test_failed_force_preserves_previous_bcf_and_index(self) -> None:
        for name in ('downsample', 'merge', 'subset'):
            with self.subTest(name=name):
                self.dst.write_bytes(b'OLD-BCF')
                Path(str(self.dst) + '.csi').write_bytes(b'OLD-INDEX')
                result = self.utility(name, [], {**self.env, 'FAKE_FAIL_INDEX': '1'})
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.dst.read_bytes(), b'OLD-BCF')
                self.assertEqual(Path(str(self.dst) + '.csi').read_bytes(), b'OLD-INDEX')

    def test_successful_force_replaces_previous_bcf_and_index(self) -> None:
        for name in ('downsample', 'merge', 'subset'):
            with self.subTest(name=name):
                self.dst.write_bytes(b'OLD-BCF')
                Path(str(self.dst) + '.csi').write_bytes(b'OLD-INDEX')
                result = self.utility(name, [])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.dst.read_bytes(), b'NEW-BCF')
                self.assertEqual(Path(str(self.dst) + '.csi').read_bytes(), b'NEW-INDEX')

    def test_cross_chromosome_output_input_collision(self) -> None:
        (self.data / 'chr2.in.bcf').write_bytes(b'SECOND-INPUT')
        # chr1 output is chr2 input; must reject *before* running chr1.
        args = ['--in-template', str(self.data / 'chr{chr}.in.bcf'),
                '--out-template', str(self.data / 'chr{chr}.out.bcf'),
                '--targets-dir', str(self.data), '--target-template', 'chr{chr}.targets.txt']
        (self.data / 'chr2.targets.txt').write_text('2\t100\n')
        # Use a symlink: chr1.out.bcf aliases chr2.in.bcf.
        (self.data / 'chr1.out.bcf').symlink_to(self.data / 'chr2.in.bcf')
        result = run_cmd(['bash', self.scripts / 'preprocess/downsample_bcfs.sh',
                          *args, '--chroms', '1-2', '--force'], self.env)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.data / 'chr2.in.bcf').read_bytes(), b'SECOND-INPUT')

    def test_completed_run_metadata_protected(self) -> None:
        run = self.tmp / 'runs' / 'completed'
        (run / 'meta').mkdir(parents=True)
        (run / 'work' / 'plans').mkdir(parents=True)
        (run / 'out').mkdir()
        (run / 'meta/iids.txt').write_text('A\nB\n')
        (run / 'meta/pairjobs.tsv').write_text('existing plan\n')
        (run / 'work/plans/example.pairs').write_text('A\tB\n')
        (run / 'DONE').touch()
        env = {**self.env, 'RUN_ID': 'completed'}
        for script, args in (('make_iid_list.sh', []), ('make_pairjobs.sh', ['--mode', 'all'])):
            with self.subTest(script=script):
                result = run_cmd(['bash', self.scripts / script, *args], env)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((run / 'meta/iids.txt').read_text(), 'A\nB\n')
                self.assertEqual((run / 'meta/pairjobs.tsv').read_text(), 'existing plan\n')
                self.assertEqual((run / 'work/plans/example.pairs').read_text(), 'A\tB\n')

    def test_new_run_same_timestamp_unique(self) -> None:
        for _ in range(2):
            result = run_cmd(['bash', self.scripts / 'new_run.sh', 'same'], self.env)
            self.assertEqual(result.returncode, 0, result.stderr)
            if _ == 0:
                previous = result.stdout.strip()
            else:
                self.assertNotEqual(result.stdout.strip(), previous)

    def test_headerless_ibd_rejected_without_clobber(self) -> None:
        ibd, ch, out = (self.data / item for item in ('ibd.tsv', 'ch.tsv', 'out.tsv'))
        ibd.touch()
        ch.write_text('iid1\tiid2\nA\tB\n')
        out.write_text('old output\n')
        result = run_cmd(['bash', self.scripts / 'postprocess/subset_ch_all_pairs.sh',
                          '--ibd-ind', ibd, '--ch-all', ch, '--out', out, '--force'], self.env)
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertEqual(out.read_text(), 'old output\n')

    def test_postprocess_report_alias_rejected(self) -> None:
        ibd, ch, out = (self.data / item for item in ('ibd.tsv', 'ch.tsv', 'out.tsv'))
        ibd.write_text('iid1\tiid2\nA\tB\n')
        ch.write_text('iid1\tiid2\nA\tB\n')
        result = run_cmd(['bash', self.scripts / 'postprocess/subset_ch_all_pairs.sh',
                          '--ibd-ind', ibd, '--ch-all', ch, '--out', out,
                          '--pair-list', ch, '--force'], self.env)
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertEqual(ch.read_text(), 'iid1\tiid2\nA\tB\n')

    def test_merge_missing_input_preserves_existing_output(self) -> None:
        src = self.data / 'a.tsv'
        missing = self.data / 'absent.tsv'
        dst = self.data / 'merged.tsv'
        src.write_text('x\ty\n1\t2\n')
        dst.write_text('OLD\n')
        result = run_cmd([sys.executable, self.scripts / 'merge_tsvs.py',
                          '--out', dst, src, missing])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(dst.read_text(), 'OLD\n')


if __name__ == '__main__':
    unittest.main()
