import sys, time, datetime
for line in sys.stdin:
    t = datetime.datetime.now().strftime("%H:%M:%S.%f")[:-3]
    sys.stdout.write(f"{t} {line}"); sys.stdout.flush()
