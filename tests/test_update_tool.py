import os
import sys
import tempfile
import unittest
from collections import defaultdict
from pathlib import Path
from unittest import mock

import requests
import yaml
from bioblend.galaxy.client import ConnectionError

sys.path.insert(0, str(Path(__file__).parents[1] / 'scripts'))
import update_tool


class UpdateToolTestCase(unittest.TestCase):
    def setUp(self):
        update_tool.tool_sheds.clear()
        update_tool.last_request_at = 0

    def tool_shed(self, side_effect):
        tool_shed = mock.Mock()
        tool_shed.repositories.get_ordered_installable_revisions.side_effect = side_effect
        update_tool.tool_sheds[update_tool.DEFAULT_TOOL_SHED_URL] = tool_shed
        return tool_shed

    def write_lockfile(self, directory, name='example'):
        filename = Path(directory) / 'tools.yml'
        with open(str(filename) + '.lock', 'w') as handle:
            yaml.safe_dump({
                'tools': [{
                    'name': name,
                    'owner': 'iuc',
                    'revisions': ['old'],
                }],
            }, handle)
        return filename

    def test_retries_transient_errors(self):
        errors = [
            ConnectionError('rate limited', status_code=429),
            ConnectionError('unavailable', status_code=503),
            requests.ConnectionError('connection failed'),
        ]

        for error in errors:
            with self.subTest(error=error):
                with tempfile.TemporaryDirectory() as directory:
                    filename = self.write_lockfile(directory)
                    tool_shed = self.tool_shed([error, ['old']])
                    stats = defaultdict(int)
                    update_tool.last_request_at = 0
                    with mock.patch.object(update_tool.time, 'sleep'):
                        update_tool.update_file(str(filename), stats=stats)
                    self.assertEqual(tool_shed.repositories.get_ordered_installable_revisions.call_count, 2)
                    self.assertEqual(stats['retries'], 1)

    def test_adds_only_latest_revision_and_writes_summary(self):
        with tempfile.TemporaryDirectory() as directory:
            filename = self.write_lockfile(directory)
            summary = Path(directory) / 'summary.md'
            self.tool_shed([['old', 'intermediate', 'latest']])

            with mock.patch.dict(os.environ, {'GITHUB_STEP_SUMMARY': str(summary)}):
                result = update_tool.main([str(filename)])

            with open(str(filename) + '.lock') as handle:
                revisions = yaml.safe_load(handle)['tools'][0]['revisions']
            self.assertEqual(result, 0)
            self.assertEqual(revisions, ['old', 'latest'])
            self.assertIn('Latest revisions found: 1', summary.read_text())

    def test_unresolved_failure_exits_nonzero_without_writing(self):
        with tempfile.TemporaryDirectory() as directory:
            first_directory = Path(directory) / 'first'
            second_directory = Path(directory) / 'second'
            first_directory.mkdir()
            second_directory.mkdir()
            first = self.write_lockfile(first_directory)
            second = self.write_lockfile(second_directory, name='unreached')
            summary = Path(directory) / 'summary.md'
            error = ConnectionError('rate limited', status_code=429)
            tool_shed = self.tool_shed([error] * update_tool.MAX_ATTEMPTS)

            with mock.patch.object(update_tool.time, 'sleep'), \
                    mock.patch.dict(os.environ, {'GITHUB_STEP_SUMMARY': str(summary)}):
                result = update_tool.main([str(first), str(second)])

            self.assertEqual(result, 1)
            self.assertEqual(
                tool_shed.repositories.get_ordered_installable_revisions.call_count,
                update_tool.MAX_ATTEMPTS,
            )
            for filename in (first, second):
                with open(str(filename) + '.lock') as handle:
                    self.assertEqual(yaml.safe_load(handle)['tools'][0]['revisions'], ['old'])
            self.assertIn('**Status:** failed', summary.read_text())
            self.assertIn('Lockfiles scanned: 1', summary.read_text())
            self.assertIn('HTTP 429 responses: {}'.format(update_tool.MAX_ATTEMPTS), summary.read_text())

    def test_continues_after_not_found_and_exits_nonzero(self):
        with tempfile.TemporaryDirectory() as directory:
            first_directory = Path(directory) / 'first'
            second_directory = Path(directory) / 'second'
            first_directory.mkdir()
            second_directory.mkdir()
            first = self.write_lockfile(first_directory, name='missing')
            second = self.write_lockfile(second_directory)
            summary = Path(directory) / 'summary.md'
            error = ConnectionError('not found', status_code=404)
            tool_shed = self.tool_shed([error, ['old', 'latest']])

            with mock.patch.object(update_tool.time, 'sleep'), \
                    mock.patch.dict(os.environ, {'GITHUB_STEP_SUMMARY': str(summary)}):
                result = update_tool.main([str(first), str(second)])

            with open(str(second) + '.lock') as handle:
                revisions = yaml.safe_load(handle)['tools'][0]['revisions']
            self.assertEqual(result, 1)
            self.assertEqual(tool_shed.repositories.get_ordered_installable_revisions.call_count, 2)
            self.assertEqual(revisions, ['old', 'latest'])
            self.assertIn('Unresolved failures: 1', summary.read_text())
            self.assertIn('Failure: `iuc/missing: HTTP 404`', summary.read_text())

    def test_continues_after_missing_revision_response(self):
        for revisions in (None, []):
            with self.subTest(revisions=revisions), tempfile.TemporaryDirectory() as directory:
                filename = self.write_lockfile(directory)
                summary = Path(directory) / 'summary.md'
                self.tool_shed([revisions])

                with mock.patch.object(update_tool.time, 'sleep'), \
                        mock.patch.dict(os.environ, {'GITHUB_STEP_SUMMARY': str(summary)}):
                    result = update_tool.main([str(filename)])

                self.assertEqual(result, 1)
                self.assertIn('Unresolved failures: 1', summary.read_text())
                self.assertIn('Tool Shed returned no revisions for iuc/example', summary.read_text())

    def test_adds_scheme_before_creating_tool_shed(self):
        factory = mock.Mock()
        tool_shed = factory.return_value

        with mock.patch.object(update_tool.ToolSheds, 'default_factory', factory):
            sheds = update_tool.ToolSheds()
            self.assertIs(sheds['testtoolshed.g2.bx.psu.edu'], tool_shed)

        factory.assert_called_once_with(url='https://testtoolshed.g2.bx.psu.edu')
        self.assertEqual(tool_shed.timeout, 30)


if __name__ == '__main__':
    unittest.main()
