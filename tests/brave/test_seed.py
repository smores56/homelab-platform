"""The seed planter: the conversion, idempotency, and what it refuses.

The seed is a fixture in the contract form every other tool here carries
(`v10` + base64 of IV + ciphertext); Brave stores base64 of the raw blob. Nothing
in these tests touches a browser or a Sync chain, and nothing prints a seed.
"""

from __future__ import annotations

import base64
import io
import json
import os
import stat
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

from apps.brave_ingest import seed as seeder

#: A 16-byte IV and 32 bytes of ciphertext: block-aligned, which is what an
#: OSCrypt v10 blob is. Deliberately not a real seed.
IV = bytes(range(16))
CIPHERTEXT = bytes(range(32, 64))
CONTRACT_SEED = "v10" + base64.b64encode(IV + CIPHERTEXT).decode("ascii")
STORED_SEED = base64.b64encode(b"v10" + IV + CIPHERTEXT).decode("ascii")


class SeedConversionTests(unittest.TestCase):
    def test_the_contract_form_becomes_the_stored_form(self) -> None:
        planted = seeder.plant({}, CONTRACT_SEED)
        self.assertEqual(planted["brave_sync_v2"]["seed"], STORED_SEED)
        self.assertEqual(
            base64.b64decode(planted["brave_sync_v2"]["seed"]), b"v10" + IV + CIPHERTEXT
        )

    def test_the_three_sync_prefs_are_written(self) -> None:
        planted = seeder.plant({}, CONTRACT_SEED)
        self.assertEqual(
            planted["sync"],
            {
                "requested": True,
                "keep_everything_synced": True,
                "has_setup_completed": True,
            },
        )

    def test_unrelated_keys_and_other_sync_keys_survive(self) -> None:
        document = {
            "profile": {"name": "smortress", "exit_type": "Normal"},
            "brave_sync_v2": {"other": 1},
            "sync": {"device_id": "abc", "requested": False},
        }
        planted = seeder.plant(document, CONTRACT_SEED)
        self.assertEqual(planted["profile"], document["profile"])
        self.assertEqual(planted["brave_sync_v2"]["other"], 1)
        self.assertEqual(planted["sync"]["device_id"], "abc")
        self.assertIs(planted["sync"]["requested"], True)
        # The caller's document is not mutated: a refusal after this point must not
        # leave a plant in memory that a later write would publish.
        self.assertNotIn("seed", document["brave_sync_v2"])


class SeedProfileTests(unittest.TestCase):
    def setUp(self) -> None:
        self._work = tempfile.TemporaryDirectory()
        self.addCleanup(self._work.cleanup)
        self.root = Path(self._work.name)
        self.prefs = self.root / "Default" / "Preferences"
        self.secret = self.root / "brave-sync-seed"
        self.secret.write_text(CONTRACT_SEED + "\n", encoding="utf-8")

    def test_planting_twice_leaves_the_same_preferences(self) -> None:
        seeder.seed_profile(self.prefs, self.secret)
        first = self.prefs.read_bytes()
        summary = seeder.seed_profile(self.prefs, self.secret)
        self.assertEqual(self.prefs.read_bytes(), first)
        self.assertTrue(summary["unchanged"])
        self.assertFalse(summary["planted"])

    def test_the_seeded_file_is_owner_only(self) -> None:
        seeder.seed_profile(self.prefs, self.secret)
        mode = stat.S_IMODE(os.stat(self.prefs).st_mode)
        self.assertEqual(oct(mode), oct(0o600))

    def test_an_existing_loose_mode_is_tightened(self) -> None:
        self.prefs.parent.mkdir(parents=True)
        self.prefs.write_text("{}", encoding="utf-8")
        os.chmod(self.prefs, 0o644)
        seeder.seed_profile(self.prefs, self.secret)
        self.assertEqual(stat.S_IMODE(os.stat(self.prefs).st_mode), 0o600)

    def test_existing_keys_are_kept_beside_the_seed(self) -> None:
        self.prefs.parent.mkdir(parents=True)
        document = {"profile": {"exit_type": "Normal"}, "sync": {"device_id": "abc"}}
        self.prefs.write_text(json.dumps(document), encoding="utf-8")
        seeder.seed_profile(self.prefs, self.secret)
        written = json.loads(self.prefs.read_text(encoding="utf-8"))
        self.assertEqual(written["profile"], document["profile"])
        self.assertEqual(written["sync"]["device_id"], "abc")
        self.assertEqual(written["brave_sync_v2"]["seed"], STORED_SEED)


class SeedRefusalTests(unittest.TestCase):
    def setUp(self) -> None:
        self._work = tempfile.TemporaryDirectory()
        self.addCleanup(self._work.cleanup)
        self.root = Path(self._work.name)
        self.prefs = self.root / "Default" / "Preferences"
        self.secret = self.root / "brave-sync-seed"

    def refuse(self, value: str | None) -> tuple[int, str]:
        if value is not None:
            self.secret.write_text(value, encoding="utf-8")
        output = io.StringIO()
        with redirect_stdout(output):
            code = seeder.main(["--prefs", str(self.prefs), "--seed-file", str(self.secret)])
        return code, output.getvalue()

    def test_a_missing_seed_file_is_refused_and_writes_nothing(self) -> None:
        code, output = self.refuse(None)
        self.assertEqual(code, seeder.EXIT_REFUSED)
        self.assertFalse(self.prefs.exists())
        self.assertIn("refused", output)

    def test_an_empty_seed_is_refused(self) -> None:
        code, _ = self.refuse("\n")
        self.assertEqual(code, seeder.EXIT_REFUSED)
        self.assertFalse(self.prefs.exists())

    def test_a_seed_without_the_oscrypt_prefix_is_refused(self) -> None:
        code, output = self.refuse(base64.b64encode(IV + CIPHERTEXT).decode("ascii"))
        self.assertEqual(code, seeder.EXIT_REFUSED)
        self.assertIn("v10", output)
        self.assertFalse(self.prefs.exists())

    def test_a_seed_that_is_not_base64_is_refused(self) -> None:
        code, _ = self.refuse("v10" + "not base64 at all")
        self.assertEqual(code, seeder.EXIT_REFUSED)
        self.assertFalse(self.prefs.exists())

    def test_a_seed_that_is_not_block_aligned_is_refused(self) -> None:
        code, output = self.refuse("v10" + base64.b64encode(IV + b"short").decode("ascii"))
        self.assertEqual(code, seeder.EXIT_REFUSED)
        self.assertIn("OSCrypt", output)
        self.assertFalse(self.prefs.exists())

    def test_a_symlinked_seed_file_is_refused(self) -> None:
        target = self.root / "real-seed"
        target.write_text(CONTRACT_SEED, encoding="utf-8")
        self.secret.symlink_to(target)
        code, output = self.refuse(None)
        self.assertEqual(code, seeder.EXIT_REFUSED)
        self.assertIn("symlink", output)
        self.assertFalse(self.prefs.exists())

    def test_a_refusal_leaves_an_existing_profile_alone(self) -> None:
        self.prefs.parent.mkdir(parents=True)
        before = json.dumps({"profile": {"exit_type": "Crashed"}})
        self.prefs.write_text(before, encoding="utf-8")
        code, _ = self.refuse("v10" + "garbage")
        self.assertEqual(code, seeder.EXIT_REFUSED)
        self.assertEqual(self.prefs.read_text(encoding="utf-8"), before)

    def test_preferences_that_are_not_json_are_refused(self) -> None:
        self.prefs.parent.mkdir(parents=True)
        self.prefs.write_text("not json", encoding="utf-8")
        code, output = self.refuse(CONTRACT_SEED)
        self.assertEqual(code, seeder.EXIT_REFUSED)
        self.assertIn("not JSON", output)
        self.assertEqual(self.prefs.read_text(encoding="utf-8"), "not json")


class SeedLogTests(unittest.TestCase):
    def test_no_log_line_carries_the_seed(self) -> None:
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            prefs = root / "Default" / "Preferences"
            secret = root / "brave-sync-seed"
            secret.write_text(CONTRACT_SEED + "\n", encoding="utf-8")
            output = io.StringIO()
            with redirect_stdout(output):
                code = seeder.main(
                    ["--prefs", str(prefs), "--seed-file", str(secret)]
                )
                seeder.main(["--prefs", str(prefs), "--seed-file", str(secret)])
            self.assertEqual(code, 0)
            logged = output.getvalue()
            for form in (CONTRACT_SEED, STORED_SEED, CONTRACT_SEED[3:], STORED_SEED[:16]):
                self.assertNotIn(form, logged)
            # The line is a JSON record, and the fields it may carry are paths and
            # booleans: no value of the document is ever logged.
            for line in logged.splitlines():
                record = json.loads(line)
                self.assertEqual(
                    sorted(record), ["event", "planted", "prefs", "ts", "unchanged", "unit"]
                )
                # Nothing but paths and booleans: a field carrying a document value
                # would be a field carrying the seed.
                for key in ("prefs", "planted", "unchanged", "event", "unit"):
                    self.assertNotIn(STORED_SEED, json.dumps(record[key]))


class SeedExportRecipeTests(unittest.TestCase):
    def test_the_documented_export_recipe_round_trips(self) -> None:
        """`jq | base64 -d | tail -c +4 | base64 -w0` plus the literal prefix."""

        raw = base64.b64decode(STORED_SEED)
        exported = "v10" + base64.b64encode(raw[3:]).decode("ascii")
        self.assertEqual(seeder.stored_seed(exported), STORED_SEED)
        self.assertEqual(seeder.oscrypt_blob(exported), raw)


if __name__ == "__main__":
    unittest.main()
