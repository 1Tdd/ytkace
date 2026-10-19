"""Run the actual C++ media-time policy used by the iOS submission preview."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class SponsorPreviewTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compiler = shutil.which('c++') or shutil.which('g++') or shutil.which('clang++')
        if compiler is None:
            raise unittest.SkipTest('C++17 compiler required; these tests also run in Linux CI')
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        root = Path(__file__).resolve().parents[1]
        cls.binary = Path(cls.temp.name) / 'sponsor-preview-test'
        subprocess.run([
            compiler, '-std=c++17', '-Wall', '-Wextra', '-Werror',
            '-I', str(root / 'Tweak/Features/SponsorBlock'),
            str(root / 'Tests/sponsor_preview_test.cpp'), '-o', str(cls.binary),
        ], check=True, capture_output=True, text=True)

    def run_scenario(self, name):
        result = subprocess.run([str(self.binary), name], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


for scenario in (
    'late_seek', 'one_cut', 'zero_start', 'near_start', 'video_end', 'clamp',
    'cancel_seek', 'replace_cut', 'mute', 'mute_end', 'unknown_duration', 'invalid',
):
    def test(self, scenario=scenario):
        self.run_scenario(scenario)
    setattr(SponsorPreviewTests, 'test_' + scenario, test)


if __name__ == '__main__':
    unittest.main()
