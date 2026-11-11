[![test](https://github.com/kirxkirx/ucac5_online_search/actions/workflows/test.yml/badge.svg)](https://github.com/kirxkirx/ucac5_online_search/actions/workflows/test.yml)

# UCAC5 online search

The server side of the remote [UCAC5](https://vizier.cds.unistra.fr/viz-bin/VizieR?-source=I/340)
lookup of [VaST](https://github.com/kirxkirx/vast). When VaST solves a plate and
has no local copy of the catalog, it uploads the positions of the detected stars
to one of the servers running this code and gets back the catalog stars found at
these positions.

This is support infrastructure for VaST, not a general catalog service: it
answers exactly the question VaST asks. VaST talks plain HTTP to
`/cgi-bin/ucac5/search_ucac5.py` on the servers listed in its source code
(`src/solve_plate_with_UCAC5.c`); a new server is used once it is on that list.

## The interface

A search is a `multipart/form-data` POST:

```
curl -F file=@positions.txt -F brightmag=2 -F faintmag=13.5 -F searcharcsec=23.35 \
     http://my.server.net/cgi-bin/ucac5/search_ucac5.py
```

| field | meaning | default | clamped to |
|---|---|---|---|
| `file` | text file of up to 10 MB with two numbers per line, `RA Dec` in degrees, and nothing else: reading stops at the first thing that is not a number. The first 1000 pairs are used | | |
| `brightmag` | bright magnitude limit | 0 | not below 0 |
| `faintmag` | faint magnitude limit | 16 | not above 20 |
| `searcharcsec` | search radius, arcseconds | 10 | not above 60 |

The reply is plain text. The first line is a comment with the version of the
service; then comes one line per position that has a catalog star within the
search radius:

```
# UCAC5 online search 1a2b3c4
75.328635 26.534227 0.593114 75.328814 26.534266 7.293000 2001.046000 0.100000 1.600000
```

The columns are the input RA and Dec, the distance to the catalog star in
arcseconds, the catalog RA and Dec in degrees at the catalog epoch, the UCAC
magnitude, the epoch (Julian year), and the proper motion in RA·cos(Dec) and
in Dec (mas/yr). Of several catalog stars within the radius the brightest one
is reported, and a catalog star is given to one position only. Only catalog
stars inside the RA/Dec bounding box of the uploaded positions are considered,
so a single position finds nothing: upload the whole field, as VaST does.

A GET request returns the version line and a usage hint: a quick way to see
what a server runs.

**Errors.** VaST accepts any reply of five lines or more and then tries no
other server. Every error this service reports is therefore a single line,
`# ERROR: ...`, with the matching HTTP status; the details go to the web
server's error log. The web server's own error pages (403, 404, 500, 504) are
longer, and VaST takes them for an answer with no stars in it. So the URL must
always lead to a working installation over plain HTTP, without a redirect. To
take a server out of service, remove the `catalog` link: the service
then answers every search with a one-line error. Do not remove the link in
`cgi-bin`. Apache can also be told to keep its own error pages short:

```
<Location "/cgi-bin/ucac5/">
    ErrorDocument 403 "# ERROR: 403"
    ErrorDocument 404 "# ERROR: 404"
    ErrorDocument 500 "# ERROR: 500"
    ErrorDocument 504 "# ERROR: 504"
</Location>
```

**Busy server.** While the 5-minute load average is above 40 (or 1.5 per CPU
core, if that is more), a search waits, for 40 s at most. Above 50 (or 2 per
core) it is refused with `503` and `# ERROR: the server is too busy`.

## Requirements

- A web server that runs CGI scripts (tested with Apache 2.4) and either
  follows a symbolic link in its `cgi-bin` directory or accepts one more
  `ScriptAlias`. Its time limit for a CGI script (Apache: `Timeout`, 60 s by
  default) must not be shorter than 60 s, and the same holds for a proxy in
  front of it.
- Python 3.6 or newer, standard library only, as `python3` in the `PATH` the web
  server gives to CGI scripts.
- A C compiler, `make`, `git`, `tar` and `curl`.
- A little-endian machine with 5.6 GB of disk space for the catalog
  (`du -h` says 5.3G).

## Installation

Nothing in the repository is edited for a particular host. The one host-specific
item is a symbolic link named `catalog` that tells where the catalog is.

Clone, build and update as one unprivileged user: the web server's own, or
another one. Not as root and not through `sudo`: git refuses to work in a
checkout that belongs to somebody else, and the owner cannot replace files that
root left behind. The web server only reads the installation: it has to be able
to enter every directory on the way to the clone and to the catalog, so keep the
default umask 022.

1. Get the catalog: the 900 zone files `z001` ... `z900` of UCAC5 in one
   directory. VaST's `lib/install_local_copy_of_UCAC5.sh` downloads them into
   `lib/catalogs/ucac5/` of a VaST installation (start it from the VaST
   directory; it asks before downloading). A copy from another server will do
   as well.

2. Clone the repository to a place **outside** of the directories the web
   server publishes:

   ```
   git clone https://github.com/kirxkirx/ucac5_online_search.git /var/www/ucac5_online_search
   cd /var/www/ucac5_online_search
   ```

3. Point it to the catalog, build and test:

   ```
   ln -sT /path/to/the/UCAC5/zone/files catalog
   make check
   make verify-catalog
   ```

   `make check` runs the offline tests and one search of the real catalog, in a
   few seconds. `make verify-catalog` compares the zone files with their known
   checksums; it reads the whole catalog.

4. Make the service visible to the web server with one more symbolic link:

   ```
   ln -sT /var/www/ucac5_online_search/cgi-bin/ucac5 /var/www/my.server.net/cgi-bin/ucac5
   ```

   The linked directory contains a single file, `search_ucac5.py`. The search
   program, the sources, the tests, the updater and `.git` stay out of the web
   server's reach, without any `.htaccess` rules. One installation can be linked
   from several virtual hosts.

5. Check it over HTTP:

   ```
   tests/check_http.sh http://my.server.net/cgi-bin/ucac5/search_ucac5.py
   ```

   This uploads 635 test positions with the `curl` options VaST uses, compares
   the reply with the known 607 matches, and prints the version the server
   reports. It works against any server: run it against each of them to see
   whether they are in sync.

6. Let cron keep the installation up to date, as its owner. In the system-wide
   `/etc/crontab`, which has a user column (here the owner is `apache`):

   ```
   10 15 * * * apache cd /var/www/ucac5_online_search && ./git_ucac5_automated_update.sh
   ```

   or in the owner's own crontab (`crontab -e`), without the user column:

   ```
   10 15 * * * cd /var/www/ucac5_online_search && ./git_ucac5_automated_update.sh
   ```

### If the web server answers 403 or 404

A 403 means that the web server does not follow the link of step 4, or cannot
reach the installation. The `cgi-bin` directory needs `Options FollowSymLinks`,
or `Options SymLinksIfOwnerMatch` with the link and the installation owned by
the same user (`chown -h` changes the owner of a link itself). The web server's
user has to be able to enter every directory on the way to the installation.

Where links cannot be followed, skip step 4 and give the service its own
`ScriptAlias` in the server configuration. It has to come before the general
`ScriptAlias /cgi-bin/` line. Reload the web server afterwards.

```
ScriptAlias /cgi-bin/ucac5/ "/var/www/ucac5_online_search/cgi-bin/ucac5/"
<Directory "/var/www/ucac5_online_search/cgi-bin/ucac5">
    Require all granted
</Directory>
```

A 404 means that the link is missing or points to the wrong place.

### Other problems

The reason for a `# ERROR` reply is in the web server's error log. The service
runs the first `python3` in the `PATH` that the web server gives to CGI
scripts, which may differ from the one in your shell; with Apache,
`SetEnv PATH ...` in the `<Directory>` block of `cgi-bin` chooses another one.
The updater keeps the log of its last build and test in
`.git/ucac5_automated_update.log`.

## Updates

`git_ucac5_automated_update.sh` updates the installation, from cron or by hand,
as its owner. It fetches the latest commit and switches to it only if

- all the GitHub Actions tests of that commit have passed, and
- the commit builds and passes the tests on this host, including a search of
  the real catalog, in a scratch copy inside `.git`.

After the switch it tests once more and returns to the previous commit if
anything fails. It prints nothing when there is nothing to do, so cron sends
mail only about an update or a problem. A commit that has failed the tests on
the host is not tried again: once the cause is removed, run the script with
`--force`, which also skips the question to GitHub (the tests on the host still
run). With `--verbose` it also reports when there is nothing to do. To stop the
updates, remove the cron line.

A bare `git pull` checks nothing and does not rebuild the search program: use
the script. An update discards local changes to tracked files; fixes belong in
the repository.

## Replacing a hand-installed copy

Older installations are a directory `cgi-bin/ucac5/` that holds
`search_ucac5.py`, the compiled `search_ucac5` and a `files` link to a scratch
directory. To replace one:

1. Do steps 1-3 of the installation.

2. Try the new code under another name while the old one keeps serving:

   ```
   ln -sT /var/www/ucac5_online_search/cgi-bin/ucac5 /var/www/my.server.net/cgi-bin/ucac5_new
   tests/check_http.sh http://my.server.net/cgi-bin/ucac5_new/search_ucac5.py
   rm /var/www/my.server.net/cgi-bin/ucac5_new
   ```

3. Swap the directory for the link in one command, and check:

   ```
   mv /var/www/my.server.net/cgi-bin/ucac5 /var/www/ucac5_cgi_before_git && ln -sT /var/www/ucac5_online_search/cgi-bin/ucac5 /var/www/my.server.net/cgi-bin/ucac5
   tests/check_http.sh http://my.server.net/cgi-bin/ucac5/search_ucac5.py
   ```

   The old directory is moved out of `cgi-bin` rather than renamed in place:
   everything executable under `cgi-bin` can be started by its URL.

4. Set up the updater (step 6 of the installation).

To go back, remove the link (no `-r`, no trailing slash) and move the old
directory back:

```
rm /var/www/my.server.net/cgi-bin/ucac5 && mv /var/www/ucac5_cgi_before_git /var/www/my.server.net/cgi-bin/ucac5
```

The new code keeps no scratch files, so the old `files` link is not needed.

## Files

| | |
|---|---|
| `cgi-bin/ucac5/search_ucac5.py` | the CGI script: checks the request, runs the search program, reports errors |
| `src/search_ucac5.c` | the search program, built as `bin/search_ucac5` |
| `git_ucac5_automated_update.sh` | the updater |
| `tests/` | `test_offline.sh` (`make test`) uses a synthetic catalog of ten stars; `test_real_catalog.sh` (`make test-catalog`) searches the real one; `check_http.sh` checks a server; `data/ucac5_zones.md5` holds the checksums for `make verify-catalog` |

## Copyleft

Copyleft Kirill Sokolovsky <kirx@kirx.net>. The matching routine comes from VaST.

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
FITNESS FOR A PARTICULAR PURPOSE. See the file [COPYING](COPYING).
