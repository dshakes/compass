def total(items, member):
    t = 0
    for p, q in items:
        t += p * q
    if member:
        t = t * 0.9
    return round(t, 2)


def preview(items, member):
    t = 0
    for p, q in items:
        t += p * q
    if member:
        t = t * 0.9
    return round(t, 2)
