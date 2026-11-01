import fcntl


def bump(path):
    with open(path, "r+") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        n = int(f.read() or 0) + 1
        f.seek(0)
        f.truncate()
        f.write(str(n))
        return n
