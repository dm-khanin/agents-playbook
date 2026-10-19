#!/usr/bin/env python3
"""usage-guard: pause Claude Code sessions near a claude.ai plan limit and resume them after the window resets.

Claude Code exposes plan usage only in the statusLine payload, so `feed` copies it from there into one state file
that every session reads. `check` (a PreToolUse hook) ends the turn at a tool-call boundary while a window sits at
or over the threshold; `wake` (a PreToolUse asyncRewake hook) sleeps until that window resets and exits 2, which
wakes the session with a "continue" message. Every hook path fails open: a broken guard must never stop work.

    guard.py feed | check | wake          hook and statusLine entry points (JSON on stdin)
    guard.py status                       windows, overrides, paused sessions
    guard.py off [5h|7d|all] / on         let sessions run past the threshold until the current window resets
    guard.py probe SESSION_ID [--pct N] [--in SECONDS] [--window 5h|7d] [--clear]
                                          fake a blocking window for one session, to test the hooks live
"""
import fcntl
import json
import os
import random
import re
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Tuple

LABELS = {'five_hour': '5h', 'seven_day': '7d'}
ALIASES = {'5h': 'five_hour', '7d': 'seven_day', 'five_hour': 'five_hour', 'seven_day': 'seven_day'}
DEFAULTS = {
    'threshold': 97,
    'windows': ['five_hour', 'seven_day'],
    'resume_delay_s': 90,
    'resume_jitter_s': 60,
    # The wake hook is killed at its own `timeout` (21600 s in the settings), so a wait must end before that.
    'max_auto_wait_s': 21000,
    # argv list or a single executable; the message is appended as the last argument.
    'notify_command': None,
}
# Readings of one window drift by seconds, while consecutive windows are hours apart.
SAME_WINDOW_S = 900
SLEEP_CHUNK_S = 30
NOTIFIED_TTL_S = 8 * 86400
LOG_MAX_BYTES = 512 * 1024
RESUME_MESSAGE = (
    'usage-guard: the claude.ai usage window that paused this session has reset. Continue the task you were '
    'working on when usage-guard stopped you; do not repeat work that is already complete. The tool call it '
    'stopped did not run, so re-run it if it is still needed. If subagents or workflows were cut off by the '
    'pause, check what they finished and re-run only the unfinished part.')

Window = Dict[str, float]


def home() -> Path:
    return Path(os.environ.get('USAGE_GUARD_HOME') or str(Path.home() / '.claude' / 'usage-guard'))


def self_command() -> str:
    return 'python3 {}'.format(os.path.abspath(__file__))


def read_json(path: Path, default=None):
    try:
        with open(str(path), encoding='utf-8') as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def write_json(path: Path, obj) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name('.{}.{}.tmp'.format(path.name, os.getpid()))
    with open(str(tmp), 'w', encoding='utf-8') as f:
        json.dump(obj, f, indent=1, sort_keys=True)
    os.replace(str(tmp), str(path))


def load_config() -> dict:
    cfg = dict(DEFAULTS)
    user = read_json(home() / 'config.json', {})
    if isinstance(user, dict):
        cfg.update(user)
    return cfg


def safe_id(value) -> str:
    return re.sub(r'[^A-Za-z0-9_-]', '_', str(value or 'unknown'))[:80]


def log_event(text: str) -> None:
    try:
        path = home() / 'events.log'
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.exists() and path.stat().st_size > LOG_MAX_BYTES:
            os.replace(str(path), str(path.with_name('events.log.1')))
        with open(str(path), 'a', encoding='utf-8') as f:
            f.write('{} {}\n'.format(datetime.now().strftime('%Y-%m-%d %H:%M:%S'), text))
    except OSError:
        pass


def to_epoch(value) -> Optional[int]:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return int(value)
    if isinstance(value, str) and value.strip():
        text = value.strip()
        if re.fullmatch(r'\d+(\.\d+)?', text):
            return int(float(text))
        try:
            parsed = datetime.fromisoformat(text.replace('Z', '+00:00'))
        except ValueError:
            return None
        return int(parsed.timestamp())
    return None


def to_pct(value) -> Optional[float]:
    if isinstance(value, bool):
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def windows_from_payload(payload) -> Dict[str, Window]:
    limits = payload.get('rate_limits') if isinstance(payload, dict) else None
    out = {}
    for kind in LABELS:
        raw = limits.get(kind) if isinstance(limits, dict) else None
        if not isinstance(raw, dict):
            continue
        pct, resets_at = to_pct(raw.get('used_percentage')), to_epoch(raw.get('resets_at'))
        if pct is not None and resets_at is not None:
            out[kind] = {'pct': pct, 'resets_at': resets_at}
    return out


def valid_window(window) -> Optional[Window]:
    if not isinstance(window, dict):
        return None
    pct, resets_at = to_pct(window.get('pct')), to_epoch(window.get('resets_at'))
    return None if pct is None or resets_at is None else {'pct': pct, 'resets_at': resets_at}


def merge_window(old: Optional[Window], new: Window) -> Window:
    old = valid_window(old)
    if not old:
        return new
    if new['resets_at'] > old['resets_at'] + SAME_WINDOW_S:
        return new
    if new['resets_at'] < old['resets_at'] - SAME_WINDOW_S:
        return old
    # Usage never falls inside one window, so a lower reading of it comes from a session that has not called the
    # API for a while; keeping the maximum stops many sessions writing at once from lowering the shared value.
    return {'pct': max(old['pct'], new['pct']), 'resets_at': max(old['resets_at'], new['resets_at'])}


def cmd_feed(stdin: str) -> int:
    try:
        fresh = windows_from_payload(json.loads(stdin))
    except ValueError:
        return 0
    if not fresh:
        return 0
    base = home()
    base.mkdir(parents=True, exist_ok=True)
    with open(str(base / 'state.lock'), 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = read_json(base / 'state.json', {})
        windows = state.get('windows') if isinstance(state, dict) and isinstance(state.get('windows'), dict) else {}
        for kind, window in fresh.items():
            windows[kind] = merge_window(windows.get(kind), window)
        write_json(base / 'state.json', {'windows': windows, 'updated_at': int(time.time())})
    return 0


def probe_for(sid: str, now: float) -> Optional[dict]:
    probe = read_json(home() / 'probe' / '{}.json'.format(safe_id(sid)))
    if not isinstance(probe, dict) or not isinstance(probe.get('windows'), dict):
        return None
    if all(w.get('resets_at', 0) <= now for w in probe['windows'].values()):
        return None
    return probe


def session_view(sid: str, now: float) -> Tuple[Dict[str, Window], Optional[dict]]:
    """The windows this session obeys: a live probe replaces the shared state for its session only."""
    probe = probe_for(sid, now)
    if probe is not None:
        return probe['windows'], probe
    state = read_json(home() / 'state.json', {})
    windows = state.get('windows') if isinstance(state, dict) else None
    return (windows if isinstance(windows, dict) else {}), None


def blocking(windows: Dict[str, Window], cfg: dict, now: float) -> List[Tuple[str, float, int]]:
    overrides = read_json(home() / 'override.json', {})
    overrides = overrides if isinstance(overrides, dict) else {}
    out = []
    for kind in [ALIASES.get(k, k) for k in cfg['windows']]:
        window = valid_window(windows.get(kind))
        if window is None:
            continue
        pct, resets_at = window['pct'], int(window['resets_at'])
        if pct < float(cfg['threshold']) or now >= resets_at:
            continue
        # An override names the window it was given for, so it lapses by itself when that window resets.
        if to_epoch(overrides.get(kind)) == resets_at:
            continue
        out.append((kind, pct, resets_at))
    return out


def fmt_time(epoch: float, now: float) -> str:
    stamp = datetime.fromtimestamp(epoch)
    return stamp.strftime('%H:%M') if epoch - now < 20 * 3600 else stamp.strftime('%a %d %b %H:%M')


def describe(blocks, now: float, auto: bool, cfg: dict) -> str:
    parts = ', '.join('{} window at {:.1f}% (resets {})'.format(LABELS[k], pct, fmt_time(r, now))
                      for k, pct, r in blocks)
    tail = ('resumes on its own after the reset' if auto
            else 'the reset is too far off for an automatic resume, so resume it by hand')
    return 'usage-guard: {}, threshold {}%. Session paused; it {}. Override: {} off'.format(
        parts, cfg['threshold'], tail, self_command())


def notify_once(cfg: dict, key: str, text: str) -> None:
    command = cfg.get('notify_command')
    if not command:
        return
    sent = home() / 'notified'
    sent.mkdir(parents=True, exist_ok=True)
    try:
        os.close(os.open(str(sent / safe_id(key)), os.O_CREAT | os.O_EXCL | os.O_WRONLY))
    except FileExistsError:
        return
    # Detached, so a slow network never holds up the hook; the child logs the outcome.
    subprocess.Popen([sys.executable, os.path.abspath(__file__), '_notify', key, text],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True)


def cmd_notify_child(key: str, text: str) -> int:
    command = load_config().get('notify_command')
    # No shell runs the command, so `~` and `$HOME` in it are expanded here.
    argv = [os.path.expandvars(os.path.expanduser(str(part)))
            for part in ([command] if isinstance(command, str) else list(command or []))]
    if not argv:
        return 0
    try:
        done = subprocess.run(argv + [text], capture_output=True, text=True, timeout=60)
        log_event('notify key={} rc={} out={}'.format(key, done.returncode, done.stdout.strip()[:40]))
    except (OSError, subprocess.SubprocessError) as e:
        log_event('notify key={} failed: {}'.format(key, e))
    return 0


def prune(base: Path, now: float) -> None:
    for path in list((base / 'notified').glob('*')) + list((base / 'wakers').glob('*.claim')):
        try:
            if now - path.stat().st_mtime > NOTIFIED_TTL_S:
                path.unlink()
        except OSError:
            pass
    # A session closed while paused leaves its marker behind; nothing will ever wake it.
    for path in (base / 'paused').glob('*.json'):
        marker = read_json(path, {})
        if not isinstance(marker, dict) or now - float(marker.get('resume_at') or 0) > 86400:
            try:
                path.unlink()
            except OSError:
                pass


def disabled() -> bool:
    return (home() / 'disabled').exists()


def hook_input(stdin: str) -> dict:
    data = json.loads(stdin)
    return data if isinstance(data, dict) else {}


def cmd_check(stdin: str) -> int:
    data = hook_input(stdin)
    if disabled():
        return 0
    cfg, now = load_config(), time.time()
    sid = safe_id(data.get('session_id'))
    windows, probe = session_view(sid, now)
    blocks = blocking(windows, cfg, now)
    if not blocks:
        return 0
    resume_at = max(r for _, _, r in blocks)
    auto = resume_at - now <= float(cfg['max_auto_wait_s'])
    base = home()
    write_json(base / 'paused' / '{}.json'.format(sid), {
        'paused_at': int(now), 'resume_at': resume_at, 'auto': auto, 'cwd': data.get('cwd'),
        'windows': {k: {'pct': p, 'resets_at': r} for k, p, r in blocks}})
    agent = safe_id(data.get('agent_id') or 'main')
    log_event('pause sid={} agent={} {} auto={}'.format(
        sid, agent, ' '.join('{}={:.1f}%'.format(LABELS[k], p) for k, p, _ in blocks), 'yes' if auto else 'no'))
    tag = '-probe-{}'.format(sid) if probe else ''
    for kind, pct, resets_at in blocks:
        notify_once(cfg, 'pause-{}-{}{}'.format(kind, resets_at, tag), '⏸ {}{} window at {:.1f}% — sessions pausing. {}'.format(
            '[probe] ' if probe else '', LABELS[kind], pct,
            'Auto-resume after {}.'.format(fmt_time(resets_at, now)) if auto
            else 'Resets {}; resume by hand.'.format(fmt_time(resets_at, now))))
    prune(base, now)
    reason = describe(blocks, now, auto, cfg)
    print(json.dumps({'continue': False, 'stopReason': reason, 'hookSpecificOutput': {
        'hookEventName': 'PreToolUse', 'permissionDecision': 'deny', 'permissionDecisionReason': reason}}))
    return 0


def pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def acquire_lock(path: Path) -> bool:
    path.parent.mkdir(parents=True, exist_ok=True)
    for _ in range(2):
        try:
            fd = os.open(str(path), os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        except FileExistsError:
            try:
                holder = int(path.read_text().strip() or '0')
            except (OSError, ValueError):
                holder = 0
            if holder and pid_alive(holder):
                return False
            try:
                path.unlink()
            except OSError:
                pass
            continue
        with os.fdopen(fd, 'w') as f:
            f.write(str(os.getpid()))
        return True
    return False


def release_lock(path: Path) -> None:
    try:
        if path.read_text().strip() == str(os.getpid()):
            path.unlink()
    except OSError:
        pass


def claim_marker(base: Path, sid: str) -> bool:
    """Takes the session's pause marker; True for exactly one caller per pause."""
    # Two processes unlinking one path at the same instant can both be told it succeeded (measured on macOS),
    # so the existence check and the unlink happen under one flock.
    marker = base / 'paused' / '{}.json'.format(sid)
    (base / 'wakers').mkdir(parents=True, exist_ok=True)
    with open(str(base / 'wakers' / '{}.claim'.format(sid)), 'a') as claim:
        fcntl.flock(claim, fcntl.LOCK_EX)
        if not marker.exists():
            return False
        marker.unlink()
        return True


def sleep_until(target: float) -> None:
    # Short chunks against the wall clock, so a laptop that slept through the reset wakes up on time.
    while True:
        left = target - time.time()
        if left <= 0:
            return
        time.sleep(min(left, SLEEP_CHUNK_S))


def cmd_wake(stdin: str) -> int:
    data = hook_input(stdin)
    if disabled():
        return 0
    cfg, started = load_config(), time.time()
    sid = safe_id(data.get('session_id'))
    if not blocking(session_view(sid, started)[0], cfg, started):
        return 0
    base = home()
    lock = base / 'wakers' / '{}__{}.lock'.format(sid, safe_id(data.get('agent_id') or 'main'))
    if not acquire_lock(lock):
        return 0
    try:
        deadline = started + float(cfg['max_auto_wait_s'])
        resume_at = 0
        while True:
            now = time.time()
            windows, probe = session_view(sid, now)
            blocks = blocking(windows, cfg, now)
            if not blocks:
                break
            resume_at = max(r for _, _, r in blocks)
            delay = float((probe or cfg).get('resume_delay_s', cfg['resume_delay_s']))
            jitter = float((probe or cfg).get('resume_jitter_s', cfg['resume_jitter_s']))
            target = resume_at + delay + random.uniform(0, jitter)
            if target > deadline:
                log_event('wait-too-long sid={} resume_at={}'.format(sid, fmt_time(resume_at, now)))
                return 0
            sleep_until(target)
        # The first waker to take the marker wakes the session; `off` takes the markers to call the wake off.
        if not claim_marker(base, sid):
            log_event('wake-skipped sid={} (no pause marker)'.format(sid))
            return 0
        log_event('resume sid={} agent={}'.format(sid, safe_id(data.get('agent_id') or 'main')))
        probe = probe_for(sid, started)
        notify_once(cfg, 'resume-{}{}'.format(int(resume_at), '-probe-{}'.format(sid) if probe else ''),
                    '▶️ {}usage window reset — paused sessions are resuming.'.format('[probe] ' if probe else ''))
        sys.stderr.write(RESUME_MESSAGE + '\n')
        return 2
    finally:
        release_lock(lock)


def fmt_left(seconds: float) -> str:
    seconds = int(max(seconds, 0))
    days, rest = divmod(seconds, 86400)
    hours, minutes = rest // 3600, rest % 3600 // 60
    return '{}d{}h'.format(days, hours) if days else '{}h{:02d}m'.format(hours, minutes)


def cmd_status() -> int:
    cfg, now, base = load_config(), time.time(), home()
    state = read_json(base / 'state.json', {}) or {}
    updated = state.get('updated_at')
    print('threshold {}%, windows {}{}'.format(cfg['threshold'], ', '.join(LABELS.get(k, k) for k in cfg['windows']),
                                               ', DISABLED' if disabled() else ''))
    print('state updated {}'.format('{} ago'.format(fmt_left(now - updated)) if updated else 'never'))
    for kind, raw in sorted((state.get('windows') or {}).items()):
        window = valid_window(raw)
        if window is None:
            continue
        print('  {}  {:5.1f}%  resets {} (in {})'.format(LABELS.get(kind, kind), window['pct'],
                                                         fmt_time(window['resets_at'], now),
                                                         fmt_left(window['resets_at'] - now)))
    overrides = read_json(base / 'override.json', {}) or {}
    print('overrides: {}'.format(', '.join('{} until {}'.format(LABELS.get(k, k), fmt_time(v, now))
                                           for k, v in overrides.items()) or 'none'))
    paused = sorted((base / 'paused').glob('*.json'))
    print('paused sessions: {}'.format(len(paused)))
    for path in paused:
        marker = read_json(path, {}) or {}
        print('  {}  resume {}  auto={}  cwd={}'.format(path.stem, fmt_time(marker.get('resume_at', now), now),
                                                       marker.get('auto'), marker.get('cwd')))
    wakers = []
    for path in sorted((base / 'wakers').glob('*.lock')):
        try:
            if pid_alive(int(path.read_text().strip() or '0')):
                wakers.append(path.stem)
        except (OSError, ValueError):
            pass
    print('waiting wakers: {}'.format(', '.join(wakers) or 'none'))
    return 0


def parse_kinds(args: List[str]) -> List[str]:
    if not args or args[0] == 'all':
        return list(LABELS)
    if args[0] not in ALIASES:
        raise SystemExit('unknown window {!r}: use 5h, 7d or all'.format(args[0]))
    return [ALIASES[args[0]]]


def cmd_off(args: List[str]) -> int:
    base, kinds = home(), parse_kinds(args)
    state = read_json(base / 'state.json', {}) or {}
    windows = state.get('windows') or {}
    overrides = read_json(base / 'override.json', {}) or {}
    for kind in kinds:
        window = valid_window(windows.get(kind))
        if window is not None:
            overrides[kind] = int(window['resets_at'])
    write_json(base / 'override.json', overrides)
    for path in (base / 'paused').glob('*.json'):
        claim_marker(base, path.stem)
    log_event('off {}'.format(','.join(LABELS[k] for k in kinds)))
    print('usage-guard off for {} until the current window resets; paused sessions will not auto-resume, '
          'tell them to continue.'.format(', '.join(LABELS[k] for k in kinds)))
    return 0


def cmd_on() -> int:
    try:
        (home() / 'override.json').unlink()
    except FileNotFoundError:
        pass
    log_event('on')
    print('usage-guard on')
    return 0


def cmd_probe(args: List[str]) -> int:
    if not args:
        raise SystemExit('usage: probe SESSION_ID [--pct N] [--in SECONDS] [--window 5h|7d] [--clear]')
    sid, opts = safe_id(args[0]), dict(zip(args[1::2], args[2::2]))
    path = home() / 'probe' / '{}.json'.format(sid)
    if '--clear' in args:
        if path.exists():
            path.unlink()
        print('probe cleared for {}'.format(sid))
        return 0
    kind = ALIASES[opts.get('--window', '5h')]
    resets_at = int(time.time()) + int(opts.get('--in', '60'))
    write_json(path, {'windows': {kind: {'pct': float(opts.get('--pct', '99')), 'resets_at': resets_at}},
                      'resume_delay_s': 5, 'resume_jitter_s': 0})
    log_event('probe sid={} {} resets={}'.format(sid, LABELS[kind], fmt_time(resets_at, time.time())))
    print('probe armed for {}: {} blocked until {}'.format(sid, LABELS[kind], fmt_time(resets_at, time.time())))
    return 0


def main(argv: List[str]) -> int:
    command, args = (argv[1] if len(argv) > 1 else ''), argv[2:]
    if command in ('feed', 'check', 'wake'):
        try:
            stdin = sys.stdin.read()
            return {'feed': cmd_feed, 'check': cmd_check, 'wake': cmd_wake}[command](stdin)
        except Exception as e:  # noqa: BLE001 - a hook must never fail the tool call it guards
            log_event('error in {}: {!r}'.format(command, e))
            return 0
    if command == '_notify' and len(args) == 2:
        return cmd_notify_child(args[0], args[1])
    commands = {'status': lambda: cmd_status(), 'off': lambda: cmd_off(args), 'on': lambda: cmd_on(),
                'probe': lambda: cmd_probe(args)}
    if command not in commands:
        print(__doc__.strip())
        return 0 if command in ('', '-h', '--help', 'help') else 1
    return commands[command]()


if __name__ == '__main__':
    sys.exit(main(sys.argv))
