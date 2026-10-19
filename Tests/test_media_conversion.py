from pathlib import Path
import json
import shutil
import subprocess
import tempfile
import unittest


class MediaConversionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not all(shutil.which(tool) for tool in ('c++', 'pkg-config', 'ffmpeg', 'ffprobe')):
            raise unittest.SkipTest('FFmpeg development tools not installed')
        libraries = ['libavformat', 'libavcodec', 'libavutil', 'libswscale', 'libswresample']
        flags = subprocess.run(['pkg-config', '--cflags', '--libs', *libraries], capture_output=True, text=True)
        if flags.returncode:
            raise unittest.SkipTest('FFmpeg development libraries not installed')
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        cls.directory = Path(cls.temp.name)
        root = Path(__file__).resolve().parents[1]
        cls.binary = cls.directory / 'conversion-test'
        subprocess.run(['c++', '-std=c++17', '-Wall', '-Wextra', '-Werror',
                        '-I', str(root / 'Tweak/Features/Downloads'),
                        str(root / 'Tests/media_conversion_test.cpp'),
                        str(root / 'Tweak/Features/Downloads/MediaConversion.cpp'),
                        '-o', str(cls.binary), *flags.stdout.split()], check=True, text=True)
        cls.video = cls.directory / 'vp9.mkv'
        subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=160x90:rate=24',
                        '-f', 'lavfi', '-i', 'sine=frequency=997:sample_rate=48000', '-t', '1.7',
                        '-c:v', 'libvpx-vp9', '-c:a', 'aac', str(cls.video)], check=True, capture_output=True)
        cls.opus = cls.directory / 'opus.webm'
        subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'sine=sample_rate=48000',
                        '-t', '1.7', '-c:a', 'libopus', str(cls.opus)], check=True, capture_output=True)

    def convert(self, source, name, preset='audio', audio='aac', success=True):
        output = self.directory / name
        result = subprocess.run([str(self.binary), str(source), str(output), preset, audio],
                                capture_output=True, text=True, timeout=90)
        self.assertEqual(result.returncode == 0, success, result.stderr)
        if success:
            fractions = [float(line) for line in result.stdout.splitlines()]
            self.assertEqual(fractions[-1], 1)
            self.assertEqual(fractions, sorted(fractions))
            subprocess.run(['ffmpeg', '-v', 'error', '-i', str(output), '-f', 'null', '-'],
                           check=True, capture_output=True, timeout=30)
        else:
            self.assertFalse(output.exists(), result.stderr)
        return output

    def probe(self, path):
        return json.loads(subprocess.run(['ffprobe', '-v', 'error', '-show_streams', '-show_format',
                                         '-of', 'json', str(path)], check=True, capture_output=True, text=True).stdout)

    def test_video_presets(self):
        for preset in ('ultrafast', 'veryfast', 'medium'):
            with self.subTest(preset=preset):
                output = self.convert(self.video, preset + '.mp4', preset)
                info = self.probe(output)
                self.assertEqual([s['codec_name'] for s in info['streams']], ['h264', 'aac'])
                self.assertEqual(info['streams'][0]['width'], 160)
                self.assertEqual(info['streams'][0]['height'], 90)
                self.assertAlmostEqual(float(info['format']['duration']), 1.7, delta=.15)

    def test_av1_to_h264(self):
        source = self.directory / 'av1.mkv'
        subprocess.run(['ffmpeg', '-v', 'error', '-i', str(self.video), '-c:v', 'libaom-av1',
                        '-cpu-used', '8', '-crf', '40', '-c:a', 'copy', str(source)],
                       check=True, capture_output=True, timeout=90)
        output = self.convert(source, 'av1-converted.mp4', 'veryfast')
        self.assertEqual(self.probe(output)['streams'][0]['codec_name'], 'h264')

    def test_mp3_audio_and_metadata(self):
        output = self.convert(self.video, 'audio.mp3', audio='mp3')
        info = self.probe(output)
        self.assertEqual(len(info['streams']), 1)
        self.assertEqual(info['streams'][0]['codec_name'], 'mp3')
        self.assertAlmostEqual(float(info['format']['duration']), 1.7, delta=.15)
        self.assertEqual(info['format']['tags']['title'], 'Conversion test')
        self.assertEqual(info['format']['tags']['artist'], 'YTKACE')

    def test_opus_to_aac(self):
        output = self.convert(self.opus, 'opus.m4a')
        info = self.probe(output)
        self.assertEqual(info['streams'][0]['codec_name'], 'aac')
        self.assertAlmostEqual(float(info['format']['duration']), 1.7, delta=.15)

    def test_opus_to_mp3(self):
        output = self.convert(self.opus, 'opus.mp3', audio='mp3')
        self.assertEqual(self.probe(output)['streams'][0]['codec_name'], 'mp3')

    def test_mp3_artwork_preserves_audio_and_metadata(self):
        source = self.convert(self.video, 'cover-source.mp3', audio='mp3')
        cover = self.directory / 'cover.jpg'
        subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'color=c=blue:s=64x64',
                        '-frames:v', '1', '-threads', '1', str(cover)], check=True, capture_output=True)
        output = self.directory / 'cover.mp3'
        subprocess.run([str(self.binary), str(source), str(output), 'artwork', str(cover)],
                       check=True, capture_output=True, text=True)
        info = self.probe(output)
        self.assertEqual(info['streams'][0]['codec_name'], 'mp3')
        self.assertEqual(info['streams'][1]['codec_name'], 'mjpeg')
        self.assertEqual(info['streams'][1]['disposition']['attached_pic'], 1)
        self.assertEqual(info['format']['tags']['title'], 'Conversion test')
        self.assertAlmostEqual(float(info['format']['duration']), 1.7, delta=.15)

    def test_cancel_removes_partial_file(self):
        self.convert(self.video, 'cancel.mp4', 'medium', 'cancel', success=False)

    def test_invalid_preset(self):
        self.convert(self.video, 'invalid.mp4', 'invalid', success=False)

    def test_invalid_input(self):
        source = self.directory / 'broken.mp4'
        source.write_bytes(b'broken input')
        self.convert(source, 'broken-output.mp4', 'medium', success=False)
