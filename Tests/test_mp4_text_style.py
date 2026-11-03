from pathlib import Path
import os
import shutil
import struct
import subprocess
import tempfile
import unittest


def box(kind, payload, extended=False):
    header = (struct.pack('>I4sQ', 1, kind, len(payload) + 16) if extended
              else struct.pack('>I4s', len(payload) + 8, kind))
    return header + payload


def movie(extended=False, tracks=1):
    sample = box(b'tx3g', bytes(8) + bytes([0x55]) * 30 + box(b'ftab', b'font'))
    track = box(b'stsd', bytes(4) + struct.pack('>I', 1) + sample, extended)
    for kind in (b'stbl', b'minf', b'mdia', b'trak'):
        track = box(kind, track, extended)
    return box(b'moov', track * tracks, extended)


class MP4TextStyleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compiler = shutil.which('c++') or shutil.which('g++') or shutil.which('clang++')
        if not compiler:
            raise unittest.SkipTest('C++17 compiler not found')
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        cls.directory = Path(cls.temp.name)
        cls.binary = cls.directory / 'mp4-text-style'
        root = Path(__file__).resolve().parents[1]
        subprocess.run([compiler, '-std=c++17', '-Wall', '-Wextra', '-Werror',
                        '-I', str(root / 'Tweak/Features/Downloads'),
                        str(root / 'Tests/mp4_text_style_test.cpp'), '-o', str(cls.binary)],
                       check=True, capture_output=True, text=True)

    def run_patch(self, path, succeeds=True):
        result = subprocess.run([str(self.binary), str(path)], timeout=10)
        self.assertEqual(result.returncode, 0 if succeeds else 1)

    def check_style(self, original, patched):
        # Only the 30-byte style record may change, not font tables or sample payload.
        expected = bytearray(original)
        count = 0
        cursor = 0
        while (cursor := original.find(b'tx3g', cursor)) >= 0:
            style = bytearray(30)
            style[4:6] = bytes([1, 255])
            style[14:18] = struct.pack('>HH', 1080, 1920)
            style[23] = 1
            style[25] = 54
            style[26:30] = bytes([255]) * 4
            expected[cursor + 12:cursor + 42] = style
            cursor += 4
            count += 1
        self.assertGreater(count, 0)
        self.assertEqual(patched, expected)

    def test_normal_and_extended_boxes_multiple_tracks(self):
        for extended in (False, True):
            path = self.directory / 'tracks.mp4'
            original = movie(extended, tracks=2)
            path.write_bytes(original)
            self.run_patch(path)
            self.check_style(original, path.read_bytes())

    def test_media_payload_with_fake_tx3g_is_untouched(self):
        payload = box(b'mdat', box(b'tx3g', bytes(64)))
        metadata = movie()
        path = self.directory / 'payload.mp4'
        path.write_bytes(payload + metadata)
        self.run_patch(path)
        result = path.read_bytes()
        self.assertEqual(result[:len(payload)], payload)
        self.check_style(metadata, result[len(payload):])

    @unittest.skipIf(os.name == 'nt', 'Sparse-file fixture requires a Unix filesystem')
    def test_large_sparse_media_skipped_without_reading_payload(self):
        path = self.directory / 'large.mp4'
        # Beyond 4 GiB also exercises 64-bit offsets; occupies only a few disk blocks.
        size = (1 << 32) + 4096
        metadata = movie()
        with path.open('wb') as stream:
            stream.write(struct.pack('>I4sQ', 1, b'mdat', size))
            stream.seek(size - 8)
            stream.write(b'KEEPTHIS')
            stream.write(metadata)
        self.run_patch(path)
        self.assertEqual(path.stat().st_size, size + len(metadata))
        with path.open('rb') as stream:
            stream.seek(size - 8)
            self.assertEqual(stream.read(8), b'KEEPTHIS')
            self.check_style(metadata, stream.read())

    def test_malformed_trailing_box_does_not_modify_earlier_style(self):
        for tail in (b'x', struct.pack('>I4s', 999999, b'free'), struct.pack('>I4s', 4, b'free')):
            original = movie() + tail
            path = self.directory / 'broken.mp4'
            path.write_bytes(original)
            self.run_patch(path, succeeds=False)
            self.assertEqual(path.read_bytes(), original)

    def test_no_subtitle_and_truncated_sample_are_rejected(self):
        for original in (box(b'mdat', b'tx3g' + bytes(64)), movie()[:-1]):
            path = self.directory / 'no-style.mp4'
            path.write_bytes(original)
            self.run_patch(path, succeeds=False)
            self.assertEqual(path.read_bytes(), original)

    def test_real_ffmpeg_file_remains_decodable(self):
        if not shutil.which('ffmpeg') or not shutil.which('ffprobe'):
            self.skipTest('FFmpeg tools not installed')
        caption = self.directory / 'caption.srt'
        caption.write_text('1\n00:00:00,000 --> 00:00:00,500\nHello\n')
        path = self.directory / 'real.mp4'
        subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'color=s=1920x1080:r=2',
                        '-i', str(caption), '-t', '1', '-c:v', 'libx264', '-preset', 'ultrafast',
                        '-c:s', 'mov_text', str(path)], check=True, capture_output=True)
        size = path.stat().st_size
        self.run_patch(path)
        self.assertEqual(path.stat().st_size, size)
        subprocess.run(['ffmpeg', '-v', 'error', '-i', str(path), '-f', 'null', '-'],
                       check=True, capture_output=True)
        result = subprocess.run(['ffmpeg', '-v', 'error', '-i', str(path), '-map', '0:s', '-f', 'srt', '-'],
                                check=True, capture_output=True, text=True)
        self.assertIn('Hello', result.stdout)
