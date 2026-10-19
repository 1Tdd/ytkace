from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class DownloadFormatTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compiler = shutil.which('c++') or shutil.which('g++') or shutil.which('clang++')
        if compiler is None:
            raise unittest.SkipTest('C++17 compiler not found')
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        root = Path(__file__).resolve().parents[1]
        cls.binary = Path(cls.temp.name) / 'download-formats-test'
        subprocess.run([
            compiler, '-std=c++17', '-Wall', '-Wextra', '-Werror',
            '-I', str(root / 'Tweak/Features/Downloads'),
            str(root / 'Tests/download_format_test.cpp'), '-o', str(cls.binary),
        ], check=True, capture_output=True, text=True)

    def test_download_formats(self):
        for scenario in ('tracks', 'refreshed', 'quality', 'missing_itag', 'media_type', 'sizes'):
            with self.subTest(scenario=scenario):
                subprocess.run([str(self.binary), scenario], check=True, capture_output=True, text=True)
