from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class ShortsSubmitPlacementTests(unittest.TestCase):
    def test_top_rail_hidden_download_and_rotation(self):
        compiler = shutil.which('c++') or shutil.which('g++') or shutil.which('clang++')
        if compiler is None:
            self.skipTest('C++17 compiler not found')
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / 'shorts-submit-placement-test'
            subprocess.run([
                compiler, '-std=c++17', '-Wall', '-Wextra', '-Werror',
                '-I', str(root / 'Tweak/Features/Shorts'),
                str(root / 'Tests/shorts_submit_placement_test.cpp'), '-o', str(binary),
            ], check=True, capture_output=True, text=True)
            subprocess.run([str(binary)], check=True, capture_output=True, text=True)
