import argparse
import logging
import os
import time
from collections import defaultdict

import requests
import yaml
from bioblend import toolshed
from bioblend.galaxy.client import ConnectionError

DEFAULT_TOOL_SHED_URL = 'https://toolshed.g2.bx.psu.edu'
REQUEST_INTERVAL = 0.25
MAX_ATTEMPTS = 6
TRANSIENT_STATUS_CODES = {None, 429, 500, 502, 503, 504}


class ToolSheds(defaultdict):
    default_factory = toolshed.ToolShedInstance

    def __missing__(self, key):
        url = key if key.lower().startswith(('http://', 'https://')) else 'https://' + key
        logging.debug('Creating new ToolShedInstance for URL: %s', url)
        tool_shed = self.default_factory(url=url)
        tool_shed.timeout = 30
        self[key] = tool_shed
        return tool_shed


tool_sheds = ToolSheds()
last_request_at = 0


def update_file(fn, owner=None, name=None, without=False, stats=None, failures=None):
    global last_request_at

    if stats is None:
        stats = defaultdict(int)
    if failures is None:
        failures = []

    with open(fn + '.lock', 'r') as handle:
        locked = yaml.safe_load(handle)

    changed = False
    for tool in locked['tools']:
        logging.debug("Examining {owner}/{name}".format(**tool))

        if without and tool.get('revisions'):
            continue
        if not without and owner and tool['owner'] not in owner:
            continue
        if not without and name and tool['name'] != name:
            continue

        tool_shed_url = tool.get('tool_shed_url', DEFAULT_TOOL_SHED_URL)
        if tool_shed_url != DEFAULT_TOOL_SHED_URL:
            logging.warning('Non-default Tool Shed URL for %s/%s: %s', tool['owner'], tool['name'], tool_shed_url)
        tool_shed = tool_sheds[tool_shed_url]

        logging.debug("Fetching updates for {owner}/{name}".format(**tool))
        revisions = None
        for attempt in range(MAX_ATTEMPTS):
            delay = REQUEST_INTERVAL - (time.monotonic() - last_request_at)
            if delay > 0:
                time.sleep(delay)
            last_request_at = time.monotonic()
            stats['requests'] += 1

            try:
                revisions = tool_shed.repositories.get_ordered_installable_revisions(tool['name'], tool['owner'])
                break
            except (ConnectionError, requests.RequestException) as error:
                status = getattr(error, 'status_code', None)
                if status == 429:
                    stats['rate_limits'] += 1
                elif status is None:
                    stats['network_errors'] += 1
                elif status >= 500:
                    stats['server_errors'] += 1
                if status == 404:
                    failure = '{owner}/{name}: HTTP {status}'.format(status=status, **tool)
                    failures.append(failure)
                    logging.error('Repository update failed; continuing scan: %s', failure)
                    break
                if status not in TRANSIENT_STATUS_CODES or attempt == MAX_ATTEMPTS - 1:
                    raise RuntimeError('{owner}/{name}: {error}'.format(error=error, **tool)) from error
                stats['retries'] += 1
                retry_delay = 2 ** attempt
                logging.warning(
                    'Transient Tool Shed error for %s/%s (%s); retrying in %ss',
                    tool['owner'],
                    tool['name'],
                    error,
                    retry_delay,
                )
                time.sleep(retry_delay)

        if revisions is None:
            continue
        if not revisions:
            failure = 'Tool Shed returned no revisions for {owner}/{name}'.format(**tool)
            failures.append(failure)
            logging.error('%s; continuing scan', failure)
            continue
        stats['repositories'] += 1
        latest_revision = str(revisions[-1])
        if latest_revision in tool.get('revisions', []):
            stats['current'] += 1
            continue

        logging.info(
            "Found newer revision of {owner}/{name} ({revision})".format(revision=latest_revision, **tool)
        )
        tool.setdefault('revisions', []).append(latest_revision)
        stats['updates'] += 1
        changed = True

    if changed:
        with open(fn + '.lock', 'w') as handle:
            yaml.dump(locked, handle, default_flow_style=False)
        stats['files_written'] += 1


def write_summary(stats, files_scanned, started, failures):
    summary = '\n'.join([
        '## Tool Shed update summary',
        '',
        '**Status:** {}'.format('failed' if failures else 'completed'),
        '',
        '- Lockfiles scanned: {}'.format(files_scanned),
        '- Repositories checked: {}'.format(stats['repositories']),
        '- Repositories already current: {}'.format(stats['current']),
        '- Latest revisions found: {}'.format(stats['updates']),
        '- Files written: {}'.format(stats['files_written']),
        '- Request attempts: {}'.format(stats['requests']),
        '- Transient retries: {}'.format(stats['retries']),
        '- HTTP 429 responses: {}'.format(stats['rate_limits']),
        '- HTTP 5xx responses: {}'.format(stats['server_errors']),
        '- Network errors: {}'.format(stats['network_errors']),
        '- Unresolved failures: {}'.format(len(failures)),
        '- Duration: {:.1f}s'.format(time.monotonic() - started),
    ])
    if failures:
        summary += '\n\n' + '\n'.join(
            '- Failure: `{}`'.format(failure.replace('`', "'")) for failure in failures
        )
    logging.info('\n%s', summary)

    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as handle:
            handle.write(summary + '\n')


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument('fn', nargs='+', help="Tool.yaml files")
    parser.add_argument('--owner', action='append', help="Repository owner to filter on, anything matching this will be updated. Can be specified multiple times")
    parser.add_argument('--name', help="Repository name to filter on, anything matching this will be updated")
    parser.add_argument('--without', action='store_true', help="If supplied will ignore any owner/name and just automatically add the latest hash for anything lacking one.")
    parser.add_argument('--log', choices=('critical', 'error', 'warning', 'info', 'debug'), default='info')
    args = parser.parse_args(argv)
    logging.basicConfig(level=getattr(logging, args.log.upper()))
    stats = defaultdict(int)
    failures = []
    started = time.monotonic()
    files_scanned = 0

    try:
        for fn in args.fn:
            files_scanned += 1
            update_file(fn, owner=args.owner, name=args.name, without=args.without, stats=stats, failures=failures)
    except Exception as error:
        logging.error('Tool update failed: %s', error)
        failures.append(str(error))
        write_summary(stats, files_scanned, started, failures)
        return 1

    write_summary(stats, files_scanned, started, failures)
    return 1 if failures else 0


if __name__ == '__main__':
    raise SystemExit(main())
