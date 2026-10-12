"""Тесты tools/art/gen.py без реальной генерации (ADR-0001): подставной `codex` и фейковые логи.

    python3 -m unittest discover -s tools/art -p 'test_*.py'
"""

import io
import json
import os
import stat
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gen  # noqa: E402

PNG = gen.PNG_MAGIC + b"fake-png-body"

FAKE_CODEX = """#!/usr/bin/env python3
import re, sys
from pathlib import Path
if sys.argv[1:3] == ["login", "status"]:
    print("Logged in using ChatGPT")
    sys.exit(0)
Path(sys.argv[0]).with_name("argv.txt").write_text("\\n".join(sys.argv[1:]))
prompt = sys.stdin.read()
target = Path(re.search(r"copy the generated PNG file into this workspace as (\\S+) ", prompt)[1])
target.parent.mkdir(parents=True, exist_ok=True)
target.write_bytes(%r)
print("session id: 0123abcd-0000-0000-0000-000000000000")
"""


class GenTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.style = self.tmp / "style.png"
        self.style.write_bytes(PNG)
        patches = {
            "STYLE_REF": self.style,
            "WORK_DIR": self.tmp / "build/art",
            "LOG_DIR": self.tmp / "build/art-logs",
        }
        for name, value in patches.items():
            patcher = mock.patch.object(gen, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def job(self, **spec) -> gen.Job:
        base = {"name": "rock", "prompt": "a rock", "out": str(self.tmp / "set")}
        return gen.make_job({**base, **spec})


class PromptTest(GenTestCase):
    def test_style_reference_is_always_first(self) -> None:
        extra = self.tmp / "barrel.png"
        extra.write_bytes(PNG)
        job = self.job(ref=[f"{extra}=shape of the approved barrel"])
        self.assertEqual([path for path, _ in job.refs], [self.style, extra])
        self.assertEqual(job.refs[1][1], "shape of the approved barrel")

    def test_style_reference_is_not_duplicated(self) -> None:
        job = self.job(ref=[str(self.style)])
        self.assertEqual(len(job.refs), 1)

    def test_prompt_lists_references_in_order_then_asset_canvas_background(self) -> None:
        extra = self.tmp / "barrel.png"
        extra.write_bytes(PNG)
        job = self.job(ref=[str(extra)], size="1024x1024")
        text = gen.build_prompt(job.prompt, job.refs, job.size)
        self.assertIn("Image 1 (style.png) = style reference only", text)
        self.assertIn("Image 2 (barrel.png) = reference for this asset", text)
        order = [text.index(part) for part in ("REFERENCE IMAGES", "ASSET:\na rock", "Canvas: 1024x1024", "#FFFFFF")]
        self.assertEqual(order, sorted(order))
        self.assertIn("1:1 square", text)

    def test_scene_prompt_has_no_background_line(self) -> None:
        job = self.job(scene=True)
        self.assertTrue(job.scene)
        self.assertNotIn("#FFFFFF", gen.build_prompt(job.prompt, job.refs, job.size, job.scene))

    def test_prompt_is_read_from_file(self) -> None:
        file = self.tmp / "prompt.txt"
        file.write_text("  two crates  \n", encoding="utf-8")
        self.assertEqual(self.job(prompt=str(file)).prompt, "two crates")

    def test_refuses_without_style_reference(self) -> None:
        with self.assertRaisesRegex(gen.GenError, "нет эталона стиля"):
            gen.ref_list([], self.tmp / "missing.png")

    def test_refuses_missing_extra_reference(self) -> None:
        with self.assertRaisesRegex(gen.GenError, "нет файлов эталонов"):
            self.job(ref=[str(self.tmp / "nope.png")])

    def test_rejects_bad_name_size_and_provider(self) -> None:
        for spec in ({"name": "Rock Big"}, {"size": "big"}, {"provider": "openai"}, {"out": ""}):
            with self.subTest(spec=spec), self.assertRaises(gen.GenError):
                self.job(**spec)


class BatchTest(GenTestCase):
    def write_jobs(self, data) -> Path:
        path = self.tmp / "jobs.json"
        path.write_text(json.dumps(data), encoding="utf-8")
        return path

    def test_parses_list_and_dict_and_cli_overrides_provider(self) -> None:
        specs = [
            {"name": "a", "prompt": "x", "out": str(self.tmp), "size": "512x512"},
            {"name": "b", "prompt": "y", "out": str(self.tmp), "provider": "codex"},
        ]
        for data in (specs, {"jobs": specs}):
            jobs = gen.load_jobs(self.write_jobs(data), {"provider": "manual"})
            self.assertEqual([j.name for j in jobs], ["a", "b"])
            self.assertEqual([j.provider for j in jobs], ["manual", "manual"])
            self.assertEqual(jobs[0].size, (512, 512))
            self.assertEqual(jobs[0].refs[0][0], self.style)

    def test_rejects_empty_duplicate_and_broken(self) -> None:
        same = {"name": "a", "prompt": "x", "out": str(self.tmp)}
        for data in ([], [same, same], [{"name": "a"}]):
            with self.subTest(data=data), self.assertRaises(gen.GenError):
                gen.load_jobs(self.write_jobs(data), {})


class FindImageTest(GenTestCase):
    def setUp(self) -> None:
        super().setUp()
        self.target = self.tmp / "build/art/codex/rock.png"
        self.home = self.tmp / "codex-home"
        self.since = time.time()

    def test_prefers_copied_target(self) -> None:
        self.target.parent.mkdir(parents=True)
        self.target.write_bytes(PNG)
        self.assertEqual(gen.find_image("", self.target, self.since, self.home), self.target)

    def test_ignores_stale_target(self) -> None:
        self.target.parent.mkdir(parents=True)
        self.target.write_bytes(PNG)
        os.utime(self.target, (self.since - 100, self.since - 100))
        self.assertIsNone(gen.find_image("", self.target, self.since, self.home))

    def test_path_from_log(self) -> None:
        image = self.home / "generated_images/sess/ig_1.png"
        image.parent.mkdir(parents=True)
        image.write_bytes(PNG)
        log = f"tool output: saved to {image}\nsession id: 0123abcd-1111\n"
        self.assertEqual(gen.find_image(log, self.target, self.since, self.home), image)

    def test_session_folder_from_log(self) -> None:
        folder = self.home / "generated_images/0123abcd-2222"
        folder.mkdir(parents=True)
        (folder / "ig_1.png").write_bytes(PNG)
        newest = folder / "ig_2.png"
        newest.write_bytes(PNG)
        os.utime(folder / "ig_1.png", (self.since - 10, self.since - 10))
        log = "OpenAI Codex\nsession id: 0123abcd-2222\nI generated the image.\n"
        self.assertEqual(gen.find_image(log, self.target, self.since, self.home), newest)

    def test_nothing_found(self) -> None:
        self.assertIsNone(gen.find_image("no image here", self.target, self.since, self.home))


class CodexRunTest(GenTestCase):
    def setUp(self) -> None:
        super().setUp()
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        fake = bin_dir / "codex"
        fake.write_text(FAKE_CODEX % PNG, encoding="utf-8")
        fake.chmod(fake.stat().st_mode | stat.S_IEXEC)
        self.argv = bin_dir / "argv.txt"
        patcher = mock.patch.dict(os.environ, {"PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}"})
        patcher.start()
        self.addCleanup(patcher.stop)

    def run_job(self, job: gen.Job, dry_run: bool = False) -> dict:
        with redirect_stdout(io.StringIO()):
            return gen.run_job(job, dry_run)

    def test_generates_png_and_records_prompt(self) -> None:
        job = self.job()
        result = self.run_job(job)
        self.assertEqual(result["status"], "ok")
        self.assertEqual(job.out.read_bytes(), PNG)
        args = self.argv.read_text().split("\n")
        self.assertEqual(args[args.index("-i") + 1], str(self.style))
        record = (job.out_dir / "PROMPTS.md").read_text(encoding="utf-8")
        self.assertIn("## rock", record)
        self.assertIn("ASSET:\na rock", record)
        self.assertIn("0123abcd-0000-0000-0000-000000000000", record)
        self.assertTrue((gen.LOG_DIR / "rock.log").is_file())
        self.assertTrue((gen.WORK_DIR.parent / ".gdignore").is_file())

    def test_second_run_keeps_previous_file(self) -> None:
        job = self.job()
        self.run_job(job)
        self.run_job(job)
        self.assertEqual(len(list((gen.WORK_DIR / "old").glob("rock-*.png"))), 1)
        self.assertEqual((job.out_dir / "PROMPTS.md").read_text(encoding="utf-8").count("## rock"), 2)

    def test_dry_run_writes_nothing(self) -> None:
        job = self.job()
        self.assertEqual(self.run_job(job, dry_run=True)["status"], "dry-run")
        self.assertFalse(job.out_dir.exists())
        self.assertFalse(self.argv.exists())

    def test_check_reports_login(self) -> None:
        with redirect_stdout(io.StringIO()) as out:
            self.assertEqual(gen.cmd_check(), 0)
        self.assertIn("Logged in", out.getvalue())

    def test_not_png_is_an_error(self) -> None:
        with self.assertRaisesRegex(gen.GenError, "не PNG"):
            gen.save_image(b"RIFF....WEBP", self.tmp / "x.png")


class ManualTest(GenTestCase):
    def test_no_wait_writes_request(self) -> None:
        job = self.job(provider="manual")
        with redirect_stdout(io.StringIO()):
            result = gen.run_job(job, False, wait=False)
        self.assertEqual(result["status"], "pending")
        request = (gen.WORK_DIR / "requests/rock.txt").read_text(encoding="utf-8")
        self.assertIn(str(self.style), request)
        self.assertIn(str(job.out), request)


if __name__ == "__main__":
    unittest.main()
