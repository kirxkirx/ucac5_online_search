#!/usr/bin/env python3
"""Write a tiny synthetic UCAC5 catalog for the offline tests.

Usage: make_test_catalog.py OUTPUT_DIR

A UCAC5 zone file is a sequence of 52-byte little-endian records
(https://cdsarc.cds.unistra.fr/ftp/I/340/readmeU5.txt); zone N holds the
stars with -90 + 0.2*(N-1) <= Dec < -90 + 0.2*N degrees. The search program
uses these fields of a record:

    epi   mean epoch, (epoch - 1997.0) in units of 0.001 yr
    ira   RA  at the mean epoch, mas
    idc   Dec at the mean epoch, mas
    pmir  proper motion in RA*cos(Dec), 0.1 mas/yr
    pmid  proper motion in Dec, 0.1 mas/yr
    im1   UCAC model magnitude, mmag

The stars below are placed around the input positions in
tests/data/fixture_*_positions.txt so that each matching rule is exercised.
"""

import collections
import os
import struct
import sys

# srcid rag dcg erg edg flg nu1 epi ira idc pmir pmid pmer pmed phgm im1 rmag jmag hmag kmag
RECORD = struct.Struct('<q i i h h b b h i i h h h h h h h h h h')
assert RECORD.size == 52


def record(ra_deg, dec_deg, mag, epoch=2000.0, pm_ra=0.0, pm_dec=0.0):
    ira = round(ra_deg * 3600000)
    idc = round(dec_deg * 3600000)
    blob = RECORD.pack(1, ira, idc, 10, 10, 2, 3, round((epoch - 1997.0) * 1000), ira, idc,
                       round(pm_ra * 10), round(pm_dec * 10), 10, 10,
                       round(mag * 1000), round(mag * 1000), 20000, 20000, 20000, 20000)
    return dec_deg, blob


STARS = [
    # "main" test: four input positions at RA 150.0 - 151.5, Dec 10.05 - 10.35
    record(150.000100, 10.050100, 10.000, 2000.5, 12.3, -4.5),    # the only star near input 1
    record(150.500200, 10.100200, 12.000, 2001.0, 1.0, 1.0),      # 1" from input 2, the fainter of two
    record(150.500400, 10.100400, 11.000, 2002.0, -2.0, 3.0),     # 2" from input 2, the brighter one wins
    record(151.000100, 10.250100, 15.000),                        # 0.5" from input 3, fainter than the limit
    record(151.008000, 10.250000, 9.500, 2000.0, 7.0, 8.0),       # 28" from input 3: matched only by a wide search
    record(151.030000, 10.250000, 8.200),                         # 106" from input 3: beyond the largest allowed radius
    record(151.499900, 10.349900, 8.000, 1999.25, -55.5, -0.1),   # near input 4, in the next zone, negative proper motion
    # "wrap" test: two input positions on both sides of RA = 0/360
    record(359.990500, 10.100500, 11.500, 2003.0, 0.5, 0.5),      # high-RA side
    record(0.009500, 10.149500, 11.600, 2003.5, 0.6, 0.6),        # low-RA side
    record(180.000000, 10.120000, 11.000),                        # in the RA gap between them: must be ignored
]


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    output_dir = sys.argv[1]
    os.makedirs(output_dir, exist_ok=True)
    zones = collections.defaultdict(list)
    for dec_deg, blob in STARS:
        zones[int((dec_deg + 90.0) / 0.2) + 1].append(blob)
    # The search program checks that zone 1 can be opened before doing anything else
    open(os.path.join(output_dir, 'z001'), 'wb').close()
    for zone, blobs in sorted(zones.items()):
        with open(os.path.join(output_dir, 'z%03d' % zone), 'wb') as zone_file:
            zone_file.write(b''.join(blobs))


if __name__ == '__main__':
    main()
