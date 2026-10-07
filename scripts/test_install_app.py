"""Regression checks against the built, signed Jack.app; never registers or opens it."""
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).with_name('install-app.py')
SPEC = importlib.util.spec_from_file_location('jack_install', SCRIPT)
installer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(installer)


class InstallationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='jack-installer-', dir='/private/tmp')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = installer.PROJECT / 'build/Build/Products/Release/Jack.app'
        installer.verify(self.source)
        self.destination = self.root / 'Applications/Jack.app'
        self.backups = self.root / 'Backups'
        subprocess.run(['ditto', str(self.source), str(self.destination)], check=True)
        plist = self.destination / 'Contents/Info.plist'
        info = plistlib.loads(plist.read_bytes())
        info['CFBundleShortVersionString'], info['CFBundleVersion'] = '0.0.1', '1'
        plist.write_bytes(plistlib.dumps(info))
        subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(self.destination)], check=True, capture_output=True)
        self.old_manifest = installer.manifest(self.destination)
        self.inode = self.destination.stat().st_ino

    def test_update_preserves_app_identity_and_previous_signed_files(self):
        backup = installer.install(self.source, self.destination, self.backups)
        self.assertEqual(self.destination.stat().st_ino, self.inode)
        self.assertEqual(installer.manifest(self.destination), installer.manifest(self.source))
        self.assertEqual(installer.manifest(backup), self.old_manifest)
        installer.verify(backup)
        installer.install(self.source, self.destination, self.backups)
        self.assertEqual(self.destination.stat().st_ino, self.inode)

    def test_failed_contents_swap_restores_the_previous_application(self):
        rename = installer.os.rename

        def fail_new_contents(source, target):
            if '.Jack-staging-' in str(source) and Path(source).name == 'Contents':
                raise OSError('simulated installation failure')
            return rename(source, target)

        with patch.object(installer.os, 'rename', side_effect=fail_new_contents):
            with self.assertRaisesRegex(OSError, 'simulated installation failure'):
                installer.install(self.source, self.destination, self.backups)
        self.assertEqual(installer.manifest(self.destination), self.old_manifest)
        self.assertEqual(self.destination.stat().st_ino, self.inode)
        installer.verify(self.destination)

    def test_failed_verification_restores_the_previous_application(self):
        manifest = installer.manifest

        def mismatch(application):
            if Path(application) == self.destination:
                return {'simulated': ('file', 'bad digest')}
            return manifest(application)

        with patch.object(installer, 'manifest', side_effect=mismatch):
            with self.assertRaisesRegex(RuntimeError, 'no coinciden'):
                installer.install(self.source, self.destination, self.backups)
        self.assertEqual(installer.manifest(self.destination), self.old_manifest)
        self.assertEqual(self.destination.stat().st_ino, self.inode)
        installer.verify(self.destination)

    def test_rejects_source_as_destination(self):
        with self.assertRaisesRegex(RuntimeError, 'carpetas distintas'):
            installer.install(self.source, self.source, self.backups)

    def test_rejects_symbolic_destination(self):
        link = self.root / 'Jack-link.app'
        link.symlink_to(self.destination, target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, 'carpetas distintas'):
            installer.install(self.source, link, self.backups)
        self.assertEqual(installer.manifest(self.destination), self.old_manifest)

    def test_unregistered_backup_does_not_block_dock_refresh(self):
        def run(command, **options):
            code = 1 if command[:2] == [installer.LSREGISTER, '-u'] else 0
            if code and options.get('check'):
                raise subprocess.CalledProcessError(code, command)
            return subprocess.CompletedProcess(command, code)

        with patch.object(installer.subprocess, 'run', side_effect=run) as calls:
            installer.refresh_registration(self.destination, self.backups / 'previous.app')
        self.assertEqual([call.args[0][:2] for call in calls.call_args_list], [
            [installer.LSREGISTER, '-u'], [installer.LSREGISTER, '-f'], ['xcrun', 'swift'], ['killall', 'Dock']
        ])


if __name__ == '__main__':
    unittest.main()
