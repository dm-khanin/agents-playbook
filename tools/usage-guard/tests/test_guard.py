import json, os, shutil, subprocess, sys, tempfile, time, unittest
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import guard  # noqa: E402 - the module sits one level up from its tests

GUARD = str(Path(guard.__file__).resolve())


class GuardCase(unittest.TestCase):
    """Runs guard.py as the hooks do — JSON on stdin, a fresh USAGE_GUARD_HOME — so no test touches real state."""

    def setUp(self):
        self.home = Path(tempfile.mkdtemp())
        self.env = dict(os.environ, USAGE_GUARD_HOME=str(self.home))
        self.sent = self.home / 'sent.txt'
        self.notifier = self.home / 'notify.sh'
        self.notifier.write_text('#!/bin/sh\nprintf "%s\\n" "$1" >> "{}"\necho 200\n'.format(self.sent))
        self.notifier.chmod(0o755)
        self.config(resume_delay_s=0, resume_jitter_s=0)

    def tearDown(self):
        # A detached notify child may still be logging into the directory; retry instead of racing it.
        for _ in range(50):
            try:
                shutil.rmtree(str(self.home))
                return
            except FileNotFoundError:
                return
            except OSError:
                time.sleep(0.1)
        shutil.rmtree(str(self.home), ignore_errors=True)

    def enable_notify(self):
        self.config(notify_command=[str(self.notifier)])

    def config(self, **values):
        path = self.home / 'config.json'
        current = json.loads(path.read_text()) if path.exists() else {}
        current.update(values)
        path.write_text(json.dumps(current))

    def run_guard(self, *args, stdin=''):
        return subprocess.run([sys.executable, GUARD] + list(args), input=stdin, capture_output=True, text=True,
                              env=self.env, timeout=60)

    def start_guard(self, *args, stdin=''):
        with tempfile.TemporaryFile('w+') as source:
            source.write(stdin)
            source.seek(0)
            return subprocess.Popen([sys.executable, GUARD] + list(args), stdin=source, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, text=True, env=self.env)

    @staticmethod
    def finish(proc):
        out, err = proc.communicate(timeout=30)
        return proc.returncode, out, err

    def feed(self, five=None, seven=None):
        limits = {}
        if five is not None:
            limits['five_hour'] = {'used_percentage': five[0], 'resets_at': five[1]}
        if seven is not None:
            limits['seven_day'] = {'used_percentage': seven[0], 'resets_at': seven[1]}
        done = self.run_guard('feed', stdin=json.dumps({'model': {'id': 'm'}, 'rate_limits': limits}))
        self.assertEqual((done.returncode, done.stdout), (0, ''))

    def hook(self, sid='s1', agent=None):
        data = {'session_id': sid, 'hook_event_name': 'PreToolUse', 'tool_name': 'Bash', 'cwd': '/tmp/w',
                'tool_input': {'command': 'ls'}}
        if agent:
            data['agent_id'] = agent
        return json.dumps(data)

    def check(self, sid='s1'):
        done = self.run_guard('check', stdin=self.hook(sid))
        self.assertEqual(done.returncode, 0, done.stderr)
        return json.loads(done.stdout) if done.stdout.strip() else None

    def sent_lines(self, expect, wait=5.0):
        """Notifications go out from a detached child, so poll until `expect` lines landed, then settle."""
        deadline = time.time() + wait
        while time.time() < deadline:
            lines = self.sent.read_text().splitlines() if self.sent.exists() else []
            if len(lines) >= expect:
                break
            time.sleep(0.1)
        time.sleep(0.5)
        return self.sent.read_text().splitlines() if self.sent.exists() else []

    def wait_for(self, path, wait=5.0):
        deadline = time.time() + wait
        while time.time() < deadline and not path.exists():
            time.sleep(0.05)
        self.assertTrue(path.exists(), path)


class CheckTest(GuardCase):

    def test_under_threshold_passes(self):
        self.feed(five=(96.9, int(time.time()) + 3600))
        self.assertIsNone(self.check())

    def test_threshold_itself_stops_the_turn_and_denies_the_tool(self):
        self.feed(five=(97, int(time.time()) + 3600))
        out = self.check()
        self.assertIs(out['continue'], False)
        self.assertEqual(out['hookSpecificOutput']['permissionDecision'], 'deny')
        self.assertIn('5h window at 97.0%', out['stopReason'])
        self.assertIn('resumes on its own', out['stopReason'])

    def test_marker_records_the_paused_session(self):
        resets = int(time.time()) + 3600
        self.feed(five=(98.5, resets))
        self.check('s7')
        marker = json.loads((self.home / 'paused' / 's7.json').read_text())
        self.assertEqual((marker['resume_at'], marker['auto'], marker['cwd']), (resets, True, '/tmp/w'))

    def test_window_past_its_reset_passes(self):
        self.feed(five=(99, int(time.time()) - 5))
        self.assertIsNone(self.check())

    def test_weekly_window_stops_and_says_resume_by_hand_when_far(self):
        self.feed(five=(10, int(time.time()) + 3600), seven=(98, int(time.time()) + 3 * 86400))
        out = self.check()
        self.assertIn('7d window at 98.0%', out['stopReason'])
        self.assertNotIn('5h window', out['stopReason'])
        self.assertIn('resume it by hand', out['stopReason'])

    def test_windows_setting_drops_the_weekly_guard(self):
        self.config(windows=['5h'])
        self.feed(seven=(99, int(time.time()) + 86400))
        self.assertIsNone(self.check())

    def test_threshold_setting_is_honoured(self):
        self.config(threshold=80)
        self.feed(five=(85, int(time.time()) + 3600))
        self.assertIsNotNone(self.check())

    def test_kill_switch_file_turns_the_guard_off(self):
        self.feed(five=(99, int(time.time()) + 3600))
        (self.home / 'disabled').touch()
        self.assertIsNone(self.check())

    def test_missing_state_passes(self):
        self.assertIsNone(self.check())

    def test_corrupt_state_passes(self):
        (self.home / 'state.json').write_text('{"windows": {"five_hour": "nonsense"}')
        self.assertIsNone(self.check())

    def test_garbage_stdin_passes_and_is_logged(self):
        self.feed(five=(99, int(time.time()) + 3600))
        done = self.run_guard('check', stdin='not json')
        self.assertEqual((done.returncode, done.stdout), (0, ''))
        self.assertIn('error in check', (self.home / 'events.log').read_text())

    def test_notify_command_expands_home(self):
        self.env['HOME'] = str(self.home)
        self.config(notify_command=['~/notify.sh'])
        self.feed(five=(99, int(time.time()) + 3600))
        self.check()
        self.assertEqual(len(self.sent_lines(expect=1)), 1)

    def test_pause_notification_goes_out_once_per_window_across_sessions(self):
        self.enable_notify()
        self.feed(five=(99, int(time.time()) + 3600))
        for sid in ('s1', 's2', 's1'):
            self.check(sid)
        lines = self.sent_lines(expect=1)
        self.assertEqual(len(lines), 1, lines)
        self.assertIn('5h window at 99.0%', lines[0])
        self.assertIn('Auto-resume after', lines[0])
        self.assertIn('rc=0 out=200', (self.home / 'events.log').read_text())


class FeedTest(GuardCase):

    def state(self):
        return json.loads((self.home / 'state.json').read_text())['windows']

    def test_lower_reading_of_the_same_window_does_not_lower_it(self):
        resets = int(time.time()) + 3600
        self.feed(five=(98, resets))
        self.feed(five=(50, resets + 30))
        self.assertEqual(self.state()['five_hour']['pct'], 98)
        self.assertIsNotNone(self.check())

    def test_later_window_replaces_the_old_one(self):
        resets = int(time.time()) + 600
        self.feed(five=(99, resets))
        self.feed(five=(12, resets + 5 * 3600))
        self.assertEqual(self.state()['five_hour'], {'pct': 12, 'resets_at': resets + 5 * 3600})
        self.assertIsNone(self.check())

    def test_reading_of_an_earlier_window_is_ignored(self):
        resets = int(time.time()) + 5 * 3600
        self.feed(five=(12, resets))
        self.feed(five=(99, resets - 5 * 3600 + 600))
        self.assertEqual(self.state()['five_hour']['pct'], 12)
        self.assertIsNone(self.check())

    def test_iso_reset_time_and_float_percentage_are_read(self):
        resets = int(time.time()) + 3600
        iso = datetime.fromtimestamp(resets, tz=timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        self.feed(five=(97.25, iso))
        self.assertEqual(self.state()['five_hour'], {'pct': 97.25, 'resets_at': resets})

    def test_payload_without_rate_limits_writes_nothing(self):
        done = self.run_guard('feed', stdin=json.dumps({'model': {'id': 'm'}}))
        self.assertEqual(done.returncode, 0)
        self.assertFalse((self.home / 'state.json').exists())

    def test_corrupt_state_is_repaired_by_the_next_reading(self):
        (self.home / 'state.json').write_text('{"windows": {"five_hour": {"pct": "x"}}}')
        self.feed(five=(40, int(time.time()) + 3600))
        self.assertEqual(self.state()['five_hour']['pct'], 40)


class OverrideTest(GuardCase):

    def test_off_lets_the_current_window_through(self):
        self.feed(five=(99, int(time.time()) + 3600))
        self.run_guard('off')
        self.assertIsNone(self.check())

    def test_off_lapses_when_the_window_resets(self):
        resets = int(time.time()) + 600
        self.feed(five=(99, resets))
        self.run_guard('off', '5h')
        self.feed(five=(99, resets + 5 * 3600))
        self.assertIsNotNone(self.check())

    def test_off_for_one_window_keeps_the_other(self):
        self.feed(five=(99, int(time.time()) + 3600), seven=(99, int(time.time()) + 86400))
        self.run_guard('off', '5h')
        out = self.check()
        self.assertIn('7d window', out['stopReason'])
        self.assertNotIn('5h window', out['stopReason'])

    def test_on_drops_the_override(self):
        self.feed(five=(99, int(time.time()) + 3600))
        self.run_guard('off')
        self.run_guard('on')
        self.assertIsNotNone(self.check())


class ProbeTest(GuardCase):

    def test_probe_blocks_only_its_own_session(self):
        self.run_guard('probe', 'p1', '--pct', '99', '--in', '120')
        self.assertIsNotNone(self.check('p1'))
        self.assertIsNone(self.check('p2'))

    def test_probe_notifications_are_tagged(self):
        self.enable_notify()
        self.run_guard('probe', 'p1', '--in', '120')
        self.check('p1')
        self.assertTrue(self.sent_lines(expect=1)[0].startswith('⏸ [probe] 5h'))

    def test_expired_probe_falls_back_to_the_shared_state(self):
        self.feed(five=(10, int(time.time()) + 3600))
        self.run_guard('probe', 'p1', '--in', '1')
        time.sleep(1.2)
        self.assertIsNone(self.check('p1'))


class WakeTest(GuardCase):

    def test_not_blocked_exits_at_once(self):
        self.feed(five=(50, int(time.time()) + 3600))
        started = time.time()
        done = self.run_guard('wake', stdin=self.hook())
        self.assertEqual((done.returncode, done.stderr), (0, ''))
        self.assertLess(time.time() - started, 3)

    def test_wakes_after_the_reset_with_exit_2(self):
        self.enable_notify()
        self.feed(five=(99, int(time.time()) + 3))
        self.check()
        started = time.time()
        done = self.run_guard('wake', stdin=self.hook())
        self.assertEqual(done.returncode, 2, done.stderr)
        self.assertGreaterEqual(time.time() - started, 1)
        self.assertIn('Continue the task you were working on', done.stderr)
        self.assertFalse((self.home / 'paused' / 's1.json').exists())
        self.assertEqual(len([l for l in self.sent_lines(expect=2) if l.startswith('▶️')]), 1)

    def test_second_waker_of_the_same_agent_exits_while_the_first_waits(self):
        self.feed(five=(99, int(time.time()) + 3))
        self.check()
        first = self.start_guard('wake', stdin=self.hook())
        self.wait_for(self.home / 'wakers' / 's1__main.lock')
        started = time.time()
        second = self.run_guard('wake', stdin=self.hook())
        self.assertEqual((second.returncode, second.stderr), (0, ''))
        self.assertLess(time.time() - started, 2)
        self.assertEqual(self.finish(first)[0], 2)

    def test_other_session_gets_its_own_waker(self):
        self.feed(five=(99, int(time.time()) + 4))
        self.check('s1')
        self.check('s2')
        first = self.start_guard('wake', stdin=self.hook('s1'))
        other = self.run_guard('wake', stdin=self.hook('s2'))
        self.assertEqual(other.returncode, 2, other.stderr)
        self.assertEqual(self.finish(first)[0], 2)

    def test_only_one_of_two_agent_wakers_wakes_the_session(self):
        self.feed(five=(99, int(time.time()) + 4))
        self.check()
        main = self.start_guard('wake', stdin=self.hook())
        sub = self.start_guard('wake', stdin=self.hook(agent='a9'))
        codes = sorted([self.finish(main)[0], self.finish(sub)[0]])
        self.assertEqual(codes, [0, 2])

    def test_marker_claim_has_exactly_one_winner_under_contention(self):
        (self.home / 'paused').mkdir()
        (self.home / 'paused' / 's1.json').write_text('{}')
        start_at = time.time() + 0.8
        code = ('import sys, time\nfrom pathlib import Path\nsys.path.insert(0, sys.argv[1])\nimport guard\n'
                'while time.time() < float(sys.argv[2]):\n    pass\n'
                'print(guard.claim_marker(Path(sys.argv[3]), "s1"))\n')
        procs = [subprocess.Popen([sys.executable, '-c', code, str(Path(GUARD).parent), str(start_at), str(self.home)],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=self.env)
                 for _ in range(6)]
        results = sorted(p.communicate(timeout=30)[0].strip() for p in procs)
        self.assertEqual(results, ['False'] * 5 + ['True'])

    def test_off_while_waiting_calls_the_wake_off(self):
        self.feed(five=(99, int(time.time()) + 3))
        self.check()
        waker = self.start_guard('wake', stdin=self.hook())
        self.wait_for(self.home / 'wakers' / 's1__main.lock')
        self.run_guard('off')
        code, _, err = self.finish(waker)
        self.assertEqual((code, err), (0, ''))

    def test_stale_lock_of_a_dead_waker_is_taken_over(self):
        self.feed(five=(99, int(time.time()) + 3))
        self.check()
        dead = subprocess.Popen(['true'])
        dead.wait()
        lock = self.home / 'wakers' / 's1__main.lock'
        lock.parent.mkdir(parents=True)
        lock.write_text(str(dead.pid))
        self.assertEqual(self.run_guard('wake', stdin=self.hook()).returncode, 2)

    def test_reset_beyond_the_wait_limit_exits_at_once(self):
        self.feed(seven=(99, int(time.time()) + 3 * 86400))
        self.check()
        started = time.time()
        done = self.run_guard('wake', stdin=self.hook())
        self.assertEqual(done.returncode, 0)
        self.assertLess(time.time() - started, 3)
        self.assertTrue((self.home / 'paused' / 's1.json').exists())

    def test_probe_wakes_its_session(self):
        self.enable_notify()
        self.run_guard('probe', 's1', '--in', '3')
        self.check()
        done = self.run_guard('wake', stdin=self.hook())
        self.assertEqual(done.returncode, 2, done.stderr)
        self.assertTrue(any(l.startswith('▶️ [probe]') for l in self.sent_lines(expect=2)))


class StatusTest(GuardCase):

    def test_status_lists_windows_and_paused_sessions(self):
        self.feed(five=(42.5, int(time.time()) + 3600), seven=(99, int(time.time()) + 86400))
        self.check('s3')
        out = self.run_guard('status').stdout
        self.assertIn('5h   42.5%', out)
        self.assertIn('7d   99.0%', out)
        self.assertIn('paused sessions: 1', out)
        self.assertIn('s3', out)


if __name__ == '__main__':
    unittest.main()
