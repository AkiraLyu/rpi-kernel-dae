import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts/update-rpi-boot-config.sh"
IMAGE = "kernel_2712-dae-6.18.39-dae.img"
INITRAMFS = "initramfs_2712-dae-6.18.39-dae"


class BootConfigTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.config = Path(self.temp.name) / "config.txt"

    def update(self, image=IMAGE, initramfs=INITRAMFS):
        return subprocess.run(
            ["sh", str(HELPER), str(self.config), "rpi-dae-kernel", image, initramfs],
            text=True, capture_output=True,
        )

    def test_fresh_config_without_kernel_gets_matching_boot_files(self):
        original = "auto_initramfs=1\n[cm5]\ndtoverlay=dwc2,dr_mode=host\n[all]\n"
        self.config.write_text(original)
        self.config.chmod(0o644)
        result = self.update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.config.read_text(), original + (
            "# BEGIN rpi-dae-kernel\n[all]\n"
            f"kernel={IMAGE}\nauto_initramfs=1\n"
            f"initramfs {INITRAMFS} followkernel\n# END rpi-dae-kernel\n"
        ))
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o644)

    def test_model_sections_and_includes_are_preserved_before_override(self):
        original = (
            "[all]\nkernel=kernel_2712.img\ninitramfs old-initrd followkernel\n"
            "include custom.txt\n[pi4]\nkernel=kernel8.img\n"
            "[pi5]\narm_boost=1\n[none]\nkernel=disabled.img"
        )
        self.config.write_text(original)
        result = self.update()
        self.assertEqual(result.returncode, 0, result.stderr)
        content = self.config.read_text()
        self.assertTrue(content.startswith(original + "\n"))
        self.assertIn(f"[all]\nkernel={IMAGE}\n", content)
        self.assertTrue(content.endswith("# END rpi-dae-kernel\n"))

    def test_reinstall_is_idempotent_and_upgrade_replaces_only_our_block(self):
        original = "# User settings\n[all]\nauto_initramfs=1\n"
        self.config.write_text(original)
        self.assertEqual(self.update().returncode, 0)
        installed = self.config.read_text()
        self.assertEqual(self.update().returncode, 0)
        self.assertEqual(self.config.read_text(), installed)
        result = self.update("kernel-next.img", "initramfs-next")
        self.assertEqual(result.returncode, 0, result.stderr)
        content = self.config.read_text()
        self.assertTrue(content.startswith(original))
        self.assertEqual(content.count("# BEGIN rpi-dae-kernel"), 1)
        self.assertNotIn(IMAGE, content)
        self.assertNotIn(INITRAMFS, content)
        self.assertIn("kernel=kernel-next.img", content)
        self.assertIn("initramfs initramfs-next followkernel", content)

    def test_user_settings_added_after_block_stay_before_final_override(self):
        self.config.write_text("[all]\n")
        self.assertEqual(self.update().returncode, 0)
        with self.config.open("a") as file:
            file.write("[pi4]\nkernel=kernel8.img\n")
        self.assertEqual(self.update().returncode, 0)
        self.assertTrue(self.config.read_text().startswith(
            "[all]\n[pi4]\nkernel=kernel8.img\n# BEGIN rpi-dae-kernel\n[all]\n"
        ))

    def test_malformed_managed_blocks_leave_original_untouched(self):
        for original in (
            "[all]\n# BEGIN rpi-dae-kernel\nuser-data=keep\n",
            "[all]\n# END rpi-dae-kernel\n",
            "# BEGIN rpi-dae-kernel\n# BEGIN rpi-dae-kernel\n# END rpi-dae-kernel\n",
        ):
            with self.subTest(original=original):
                self.config.write_text(original)
                result = self.update()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.config.read_text(), original)
                self.assertEqual(list(self.config.parent.glob("config.txt.*")), [])

    def test_missing_config_is_not_silently_created(self):
        result = self.update()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.config.exists())


if __name__ == "__main__":
    unittest.main()
