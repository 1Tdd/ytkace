import importlib.util
import pathlib
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("check_hooks", ROOT / "Tools" / "check_hooks.py")
CHECK = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = CHECK
SPEC.loader.exec_module(CHECK)


def table():
    return CHECK.ClassTable(
        instance={"YTParent": {"inherited"}, "YTChild": {"own"}, "YTMovedImpl": {"moved"}},
        meta={"YTParent": {"shared"}, "YTChild": set(), "YTMovedImpl": set()},
        parents={"YTChild": "YTParent", "YTParent": None, "YTMovedImpl": None},
    )


class CheckHooksTests(unittest.TestCase):
    def test_parses_literal_targets_across_lines(self):
        with tempfile.TemporaryDirectory() as directory:
            pathlib.Path(directory, "a.mm").write_text(
                'YTKACEInstallInstanceHook(@"YTOne", @"one", (IMP)a, &b);\n'
                'YTKACEInstallClassHook(\n    @"YTTwo",\n    @"two:", (IMP)a, &b);\n'
                'YTKACEInstallInstanceHook(className, @"skipped", (IMP)a, &b);\n'
                'YTKACEInstallInstanceHook(@"YTThree", @"three:"\n    "more:"\n    @"last:", (IMP)a, &b);\n',
                encoding="utf-8")
            self.assertEqual(CHECK.parse_hooks(directory),
                             {("Instance", "YTOne", "one"), ("Class", "YTTwo", "two:"),
                              ("Instance", "YTThree", "three:more:last:")})

    def test_separates_possible_system_inheritance(self):
        classes = table()
        classes.system_parents = {"YTParent": "UIView", "YTMovedImpl": "NSObject"}
        hooks = {("Instance", "YTChild", "layoutSubviews"), ("Instance", "YTMoved", "gone")}
        self.assertEqual(CHECK.find_problems(hooks, classes), {
            "maybe-inherited YTChild layoutSubviews", "missing-method YTMoved gone"})

    def test_finds_own_inherited_and_renamed_methods(self):
        hooks = {("Instance", "YTChild", "own"), ("Instance", "YTChild", "inherited"),
                 ("Instance", "YTMoved", "moved"), ("Class", "YTChild", "shared")}
        self.assertEqual(CHECK.find_problems(hooks, table()), set())

    def test_reports_missing_targets(self):
        hooks = {("Instance", "YTChild", "gone"), ("Instance", "YTGone", "any"),
                 ("Class", "YTChild", "own")}
        self.assertEqual(CHECK.find_problems(hooks, table()), {
            "missing-method YTChild gone", "missing-class YTGone any", "missing-method YTChild own"})

    def test_ignores_system_classes(self):
        hooks = {("Instance", "UIView", "didMoveToWindow"), ("Instance", "AVPlayer", "rate")}
        self.assertEqual(CHECK.find_problems(hooks, table()), set())

    def test_baseline_ignores_comments_and_absent_files(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory, "1.0.txt")
            self.assertIsNone(CHECK.read_baseline(path))
            path.write_text("# accepted\nmissing-class YTGone any\n\n", encoding="utf-8")
            self.assertEqual(CHECK.read_baseline(path), {"missing-class YTGone any"})


if __name__ == "__main__":
    unittest.main()
