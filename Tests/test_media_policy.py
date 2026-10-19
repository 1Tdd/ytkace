"""Compile and execute the production media policy used by the tweak."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class MediaPolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compiler = shutil.which('c++') or shutil.which('g++') or shutil.which('clang++')
        if compiler is None:
            raise unittest.SkipTest('C++17 compiler required; these tests also run in Linux CI')
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        root = Path(__file__).resolve().parents[1]
        cls.binary = Path(cls.temp.name) / 'media-policy-test'
        result = subprocess.run([
            compiler, '-std=c++17', '-Wall', '-Wextra', '-Werror',
            '-I', str(root / 'Tweak/Runtime'), str(root / 'Tests/media_policy_test.cpp'),
            '-o', str(cls.binary),
        ], capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)

    def run_scenario(self, name):
        result = subprocess.run([str(self.binary), name], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


for scenario in (
    'timestamps', 'malformed_timestamps', 'overlapping_cuts', 'touching_cuts',
    'partial_cut', 'fully_cut', 'spanning_caption', 'invalid_cuts',
    'paused_zero', 'paused_duplicate', 'paused_seek', 'external_resume',
    'video_reset', 'invalid_activity',
):
    def test(self, scenario=scenario):
        self.run_scenario(scenario)
    setattr(MediaPolicyTests, 'test_' + scenario, test)
