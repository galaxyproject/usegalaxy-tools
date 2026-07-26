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

    def write_lockfile(self, directory):
        filename = Path(directory) / 'tools.yml'
        with open(str(filename) + '.lock', 'w') as handle:
            yaml.safe_dump({
                'tools': [{
                    'name': 'example',
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
                tool_shed = self.tool_shed([error, ['latest']])
                stats = defaultdict(int)
                with mock.patch.object(update_tool.time, 'sleep'):
                    revisions = update_tool.get_revisions({
                        'name': 'example',
                        'owner': 'iuc',
                    }, stats)
                self.assertEqual(revisions, ['latest'])
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
            filename = self.write_lockfile(directory)
            summary = Path(directory) / 'summary.md'
            error = ConnectionError('rate limited', status_code=429)
            self.tool_shed([error] * update_tool.MAX_ATTEMPTS)

            with mock.patch.object(update_tool.time, 'sleep'), \
                    mock.patch.dict(os.environ, {'GITHUB_STEP_SUMMARY': str(summary)}):
                result = update_tool.main([str(filename)])

            with open(str(filename) + '.lock') as handle:
                revisions = yaml.safe_load(handle)['tools'][0]['revisions']
            self.assertEqual(result, 1)
            self.assertEqual(revisions, ['old'])
            self.assertIn('**Status:** failed', summary.read_text())
            self.assertIn('HTTP 429 responses: 6', summary.read_text())


if __name__ == '__main__':
    unittest.main()
