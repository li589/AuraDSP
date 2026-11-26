#!/usr/bin/env python3
"""Source gates for Windows monitor and visualizer lifecycle (Task 13)."""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
APP = os.path.join(ROOT, "app", "auradsp_app", "lib")
FAILURES = []


def check(label, ok):
    print(("  PASS " if ok else "  FAIL ") + label)
    if not ok:
        FAILURES.append(label)


def source(relative):
    with open(os.path.join(APP, relative), encoding="utf-8-sig") as handle:
        return handle.read()


def method_body(src, signature):
    start = src.find(signature)
    if start < 0:
        return ""
    opening = src.find("{", start)
    if opening < 0:
        return ""
    depth = 0
    for index in range(opening, len(src)):
        if src[index] == "{":
            depth += 1
        elif src[index] == "}":
            depth -= 1
            if depth == 0:
                return src[opening + 1:index]
    return ""


def first_statement_is_disposed_guard(body):
    return body.lstrip().startswith("if (_disposed) return;")


def main():
    monitor = source(os.path.join("platform", "system", "windows_system_monitor.dart"))
    start = method_body(monitor, "void start()")
    stop = method_body(monitor, "void stop()")
    tick = method_body(monitor, "Future<void> tick()")
    check("monitor start advances generation", "_generation++;" in start)
    check("monitor start clears stopped", "_stopped = false;" in start)
    check("monitor stop advances generation", "_generation++;" in stop)
    check("monitor stop marks stopped", "_stopped = true;" in stop)
    check("monitor tick checks generation", "_generation" in tick)
    check("monitor tick checks stopped", "_stopped" in tick)

    state = source(os.path.join("core", "state.dart"))
    events = source(os.path.join("core", "state", "state_events.dart"))
    modes = source(os.path.join("core", "state", "state_audio_modes.dart"))
    dispose = method_body(state, "void dispose()")
    watchdog = method_body(events, "void vizWatchdogTick([DateTime? now])")
    on_event = method_body(modes, "void _onSysMonEvent(SysMonEvent e)")
    on_tick = method_body(modes, "void _onSysMonTick(Map<String, dynamic> scan)")

    check("watchdog timer is retained", "Timer? _vizWatchdogTimer;" in state)
    check("watchdog timer is assigned",
          "_vizWatchdogTimer = Timer.periodic(" in state)
    check("watchdog timer is cancelled in dispose",
          "_vizWatchdogTimer?.cancel();" in dispose)
    check("watchdog ignores ticks after dispose",
          first_statement_is_disposed_guard(watchdog))
    check("system-monitor events ignored after dispose",
          first_statement_is_disposed_guard(on_event))
    check("system-monitor ticks ignored after dispose",
          first_statement_is_disposed_guard(on_tick))
    for notifier in ("vizChannelCount", "vizChannelLevels", "vizStageChLevels"):
        check(notifier + " is disposed", notifier + ".dispose();" in dispose)

    if FAILURES:
        print("smoke_viz_lifecycle: %d FAIL" % len(FAILURES))
        return 1
    print("smoke_viz_lifecycle: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
