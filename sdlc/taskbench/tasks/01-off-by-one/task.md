Fix the off-by-one bug in triangle() in sums.py: the function should return the sum 1 + 2 + ... + n but currently returns the wrong value for all n > 1. Tests in test_sums.py are failing.
