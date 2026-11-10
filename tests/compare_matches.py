#!/usr/bin/env python3
"""Compare a reply of the search (file or "-" for standard input) with the expected matches.

Usage: compare_matches.py EXPECTED ACTUAL

Comment lines ("#") and empty lines are ignored. The lines must agree in
number and order. The match distance (third column) comes out of acos() and
may differ in the last printed digit between C libraries, so it is compared
with a tolerance; all the other columns must agree exactly as printed.
"""

import sys

DISTANCE_COLUMN = 2
DISTANCE_TOLERANCE_ARCSEC = 5e-5


def read_matches(name):
    stream = sys.stdin if name == '-' else open(name)
    with stream:
        return [line.split() for line in stream if line.strip() and not line.startswith('#')]


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    expected = read_matches(sys.argv[1])
    actual = read_matches(sys.argv[2])
    if len(expected) != len(actual):
        sys.exit('MISMATCH: %d matches expected, got %d' % (len(expected), len(actual)))
    for number, (want, got) in enumerate(zip(expected, actual), start=1):
        same = len(want) == len(got) == 9
        for column in range(9 if same else 0):
            if column == DISTANCE_COLUMN:
                try:
                    same = same and abs(float(want[column]) - float(got[column])) <= DISTANCE_TOLERANCE_ARCSEC
                except ValueError:
                    same = False
            else:
                same = same and want[column] == got[column]
        if not same:
            sys.exit('MISMATCH in match %d:\n expected: %s\n got:      %s' % (number, ' '.join(want), ' '.join(got)))
    print('%d matches, as expected' % len(actual))


if __name__ == '__main__':
    main()
