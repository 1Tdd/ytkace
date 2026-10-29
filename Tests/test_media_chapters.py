"""Probe real MP4/M4A/MP3 files to verify chapter metadata and media retention."""
from pathlib import Path
import json
import shutil
import subprocess
import tempfile
import unittest


class MediaChapterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not all(shutil.which(tool) for tool in ('c++', 'pkg-config', 'ffmpeg', 'ffprobe')):
            raise unittest.SkipTest('FFmpeg development tools not installed')
        flags = subprocess.run(['pkg-config', '--cflags', '--libs', 'libavformat', 'libavcodec', 'libavutil'],
                               capture_output=True, text=True)
        if flags.returncode:
            raise unittest.SkipTest('FFmpeg development libraries not installed')
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        cls.directory = Path(cls.temp.name)
        root = Path(__file__).resolve().parents[1]
        cls.binary = cls.directory / 'chapters-test'
        subprocess.run(['c++', '-std=c++17', '-Wall', '-Wextra', '-Werror',
                        '-I', str(root / 'Tweak/Features/Downloads'),
                        str(root / 'Tests/media_chapters_test.cpp'),
                        str(root / 'Tweak/Features/Downloads/MediaChapters.cpp'),
                        '-o', str(cls.binary), *flags.stdout.split()], check=True)
        cls.video = cls.directory / 'source.mp4'
        cls.ffmpeg('-f', 'lavfi', '-i', 'testsrc2=size=160x90:rate=24',
                   '-f', 'lavfi', '-i', 'sine=sample_rate=48000', '-t', '1.7',
                   '-c:v', 'libx264', '-c:a', 'aac', '-metadata', 'title=Video title',
                   '-metadata', 'artist=YTKACE', str(cls.video))

    @staticmethod
    def ffmpeg(*args):
        return subprocess.run(['ffmpeg', '-v', 'error', '-y', *args], check=True, capture_output=True, timeout=60)

    def probe(self, path):
        return json.loads(subprocess.run(['ffprobe', '-v', 'error', '-show_chapters', '-show_format',
                                         '-show_streams', '-of', 'json', str(path)],
                                        check=True, capture_output=True, text=True).stdout)

    def embed(self, source, name, mode='normal', success=True):
        output = self.directory / name
        result = subprocess.run([str(self.binary), str(source), str(output), mode], capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, success, result.stderr)
        if success:
            self.ffmpeg('-i', str(output), '-f', 'null', '-')
        else:
            self.assertFalse(output.exists())
        return output

    def assert_chapters(self, path, titles=('Introduzione', 'Caffè & musica 日本語', 'Finale'), starts=(0, .6, 1.2)):
        info = self.probe(path)
        chapters = info['chapters']
        self.assertEqual([c['tags']['title'] for c in chapters], list(titles))
        for chapter, start in zip(chapters, starts):
            self.assertAlmostEqual(float(chapter['start_time']), start, delta=.002)
            self.assertGreater(float(chapter['end_time']), start)
        for first, second in zip(chapters, chapters[1:]):
            self.assertAlmostEqual(float(first['end_time']), float(second['start_time']), delta=.002)
        self.assertAlmostEqual(float(chapters[-1]['end_time']), float(info['format']['duration']), delta=.06)
        self.assertEqual(info['format']['tags']['title'], 'Video title')
        self.assertEqual(info['format']['tags']['artist'], 'YTKACE')
        return info

    def test_cut_timeline(self):
        subprocess.run([str(self.binary), 'timeline'], check=True)

    def test_caption_formatting(self):
        subprocess.run([str(self.binary), 'caption'], check=True)

    def read_caption(self, path, success=True):
        result = subprocess.run([str(self.binary), 'read', str(path)], capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, success, result.stderr)
        return result.stdout

    def test_saved_files_provide_share_captions(self):
        source = self.directory / 'long-source.mp4'
        self.ffmpeg('-stream_loop', '4', '-i', str(self.video), '-t', '7', '-c', 'copy', str(source))
        for extension in ('mp4', 'm4a', 'mp3'):
            with self.subTest(extension=extension):
                media = source
                if extension != 'mp4':
                    media = self.directory / ('long-source.' + extension)
                    self.ffmpeg('-i', str(source), '-vn', '-c:a', 'libmp3lame' if extension == 'mp3' else 'copy', str(media))
                output = self.embed(media, 'caption.' + extension, 'caption-source')
                before = output.read_bytes()
                self.assertEqual(self.read_caption(output), '00:00 Introduzione\n00:02 Caffè & musica 日本語\n00:05 Finale')
                self.assertEqual(output.read_bytes(), before)

    def test_share_caption_uses_edited_timeline(self):
        source = self.directory / 'long-cut-source.mp4'
        self.ffmpeg('-stream_loop', '4', '-i', str(self.video), '-t', '7', '-c', 'copy', str(source))
        output = self.embed(source, 'caption-cuts.mp4', 'caption-cut-source')
        self.assertEqual(self.read_caption(output), '00:00 Introduzione\n00:02 Finale')

    def test_missing_chapters_provide_no_extra_text(self):
        self.assertEqual(self.read_caption(self.video), '')

    def test_unreadable_files_fail_without_caption_text(self):
        source = self.directory / 'unreadable.mp4'
        source.write_bytes(b'broken')
        self.assertEqual(self.read_caption(source, success=False), '')

    def test_mp4_retains_media_and_unicode_chapters(self):
        output = self.embed(self.video, 'chapters.mp4')
        info = self.assert_chapters(output)
        self.assertEqual([s['codec_name'] for s in info['streams'] if s['codec_type'] != 'data'], ['h264', 'aac'])
        for path in (self.video, output):
            # Packet hashes verify that adding chapters never re-encodes media.
            digest = self.ffmpeg('-i', str(path), '-map', '0:v:0', '-map', '0:a:0',
                                 '-c', 'copy', '-f', 'streamhash', '-hash', 'sha256', '-').stdout
            if path == self.video:
                original = digest
            else:
                self.assertEqual(digest, original)

    def test_m4a_chapters(self):
        source = self.directory / 'source.m4a'
        self.ffmpeg('-i', str(self.video), '-vn', '-c:a', 'copy', str(source))
        self.assert_chapters(self.embed(source, 'chapters.m4a'))

    def test_mp3_retains_cover_and_id3_tags(self):
        cover = self.directory / 'cover.jpg'
        self.ffmpeg('-f', 'lavfi', '-i', 'color=c=blue:s=64x64', '-frames:v', '1', '-threads', '1', str(cover))
        source = self.directory / 'source.mp3'
        self.ffmpeg('-i', str(self.video), '-i', str(cover), '-map', '0:a', '-map', '1:v',
                   '-c:a', 'libmp3lame', '-c:v', 'copy', '-disposition:v', 'attached_pic', str(source))
        info = self.assert_chapters(self.embed(source, 'chapters.mp3'))
        self.assertEqual(info['streams'][0]['codec_name'], 'mp3')
        self.assertEqual(info['streams'][1]['disposition']['attached_pic'], 1)

    def test_subtitles_survive(self):
        subtitles = self.directory / 'captions.srt'
        subtitles.write_text('1\n00:00:00,000 --> 00:00:01,500\nHello\n', encoding='utf-8')
        source = self.directory / 'captions.mp4'
        self.ffmpeg('-i', str(self.video), '-i', str(subtitles), '-map', '0', '-map', '1',
                   '-c', 'copy', '-c:s', 'mov_text', '-metadata:s:s:0', 'language=ita', str(source))
        info = self.assert_chapters(self.embed(source, 'chapter-captions.mp4'))
        self.assertTrue(any(s['codec_name'] == 'mov_text' and s['tags']['language'] == 'ita' for s in info['streams']))

    def test_mov_cover_art_survives(self):
        cover = self.directory / 'mov-cover.jpg'
        self.ffmpeg('-f', 'lavfi', '-i', 'color=c=blue:s=64x64', '-frames:v', '1', '-threads', '1', str(cover))
        for extension in ('mp4', 'm4a'):
            with self.subTest(extension=extension):
                source = self.directory / ('cover-source.' + extension)
                self.ffmpeg('-i', str(self.video), '-i', str(cover), '-map', '0:a', '-map', '1:v',
                            '-c', 'copy', '-disposition:v', 'attached_pic', str(source))
                info = self.assert_chapters(self.embed(source, 'cover-chapters.' + extension))
                self.assertTrue(any(s['disposition'].get('attached_pic') == 1 for s in info['streams']))

    def test_actual_cuts_remove_chapter_and_shift_remaining_times(self):
        output = self.embed(self.video, 'cut-chapters.mp4', 'cuts')
        self.assert_chapters(output, titles=('Introduzione', 'Finale'), starts=(0, .6))

    def test_replacing_chapters_does_not_duplicate_tracks(self):
        source = self.embed(self.video, 'first-chapters.mp4')
        output = self.embed(source, 'second-chapters.mp4')
        self.assert_chapters(output)
        self.assertEqual(len(self.probe(source)['streams']), len(self.probe(output)['streams']))

    def test_cancel_preserves_input_and_removes_output(self):
        self.embed(self.video, 'cancel.mp4', 'cancel', success=False)
        self.embed(self.video, 'cancel-read.mp4', 'cancel-read', success=False)
        self.assertTrue(self.video.exists())

    def test_invalid_input_does_not_leave_partial_output(self):
        source = self.directory / 'broken.mp4'
        source.write_bytes(b'broken')
        self.embed(source, 'broken-output.mp4', success=False)
