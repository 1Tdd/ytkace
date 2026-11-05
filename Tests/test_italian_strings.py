import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
ENTRY = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', re.M)
# A single literal only: split literals are joined by the compiler, not by this pattern.
CALL = re.compile(r'YTKACELocalized\(\s*@"((?:[^"\\]|\\.)*)"\s*\)')


class ItalianStringsTest(unittest.TestCase):
    def test_every_text_shown_by_the_code_has_an_italian_entry(self):
        strings = (ROOT / 'Resources/YTKACE.bundle/it.lproj/Localizable.strings').read_text(encoding='utf-8')
        known = {key for key, _ in ENTRY.findall(strings)}
        missing = set()
        for path in (ROOT / 'Tweak').rglob('*.mm'):
            missing.update(key for key in CALL.findall(path.read_text(encoding='utf-8', errors='replace'))
                           if key not in known)
        self.assertEqual(sorted(missing), [])


if __name__ == '__main__':
    unittest.main()
