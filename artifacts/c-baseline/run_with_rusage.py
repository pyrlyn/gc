#!/usr/bin/env python3
"""Run a command and print its stdout/stderr plus wait4 ru_maxrss (KiB on Linux)."""
import os, sys, subprocess

cmd = sys.argv[1:]
p = subprocess.Popen(cmd)
_, status, ru = os.wait4(p.pid, 0)
code = os.waitstatus_to_exitcode(status)
print(f"elapsed_s={ru.ru_utime + ru.ru_stime:.3f} user_s={ru.ru_utime:.3f} sys_s={ru.ru_stime:.3f} peak_rss_kb={ru.ru_maxrss}", file=sys.stderr)
raise SystemExit(code)
