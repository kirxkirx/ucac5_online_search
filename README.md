[![test](https://github.com/kirxkirx/ucac5_online_search/actions/workflows/test.yml/badge.svg)](https://github.com/kirxkirx/ucac5_online_search/actions/workflows/test.yml)

# UCAC5 online search

The server side of the remote UCAC5 lookup of [VaST](https://github.com/kirxkirx/vast).
When VaST solves a plate and has no local copy of the
[UCAC5](https://vizier.cds.unistra.fr/viz-bin/VizieR?-source=I/340) catalog, it uploads the
positions of the detected stars to one of the servers running this code and
gets back the catalog stars found at these positions.

This is support infrastructure for VaST, not a general catalog service: it
answers exactly the question VaST asks. You are welcome to run a server of
your own.

## The interface

A search is a `multipart/form-data` POST to `/cgi-bin/ucac5/search_ucac5.py`:

```
curl -F file=@positions.txt -F brightmag=9 -F faintmag=16.5 -F searcharcsec=6 \
     http://my.server.net/cgi-bin/ucac5/search_ucac5.py
```

| field | meaning | default | limit |
|---|---|---|---|
| `file` | text file, one `RA Dec` pair in degrees per line; the first 1000 pairs are used | | 10 MB |
| `brightmag` | bright magnitude limit | 0 | not below 0 |
| `faintmag` | faint magnitude limit | 16 | not above 20 |
| `searcharcsec` | search radius, arcseconds | 10 | not above 60 |

The reply is plain text. The first line is a comment with the version of the
service; then comes one line per position that has a catalog star within the
search radius (the brightest one, if there are several):

```
# UCAC5 online search 1a2b3c4
75.328635 26.534227 0.593114 75.328814 26.534266 7.293000 2001.046000 0.100000 1.600000
```

The columns are the input RA and Dec, the distance to the catalog star in
arcseconds, the catalog RA and Dec in degrees at the catalog epoch, the UCAC
magnitude, the epoch (Julian year), and the proper motion in RA·cos(Dec) and
in Dec (mas/yr). A catalog star is considered only if it lies inside the
RA/Dec bounding box of the uploaded positions, so a single position finds
nothing: upload the whole field, as VaST does.

VaST accepts a reply when it has five lines or more, and otherwise tries the
next server. Every error reply is therefore a single line, `# ERROR: ...`,
with the matching HTTP status. A GET request returns the version line and
nothing else useful; it is a convenient way to see what a server runs.

## Requirements

- A web server that runs CGI scripts (tested with Apache 2.4) and follows a
  symbolic link in its `cgi-bin` directory.
- Python 3.6 or newer; only the standard library is used.
- A C compiler and `make`; `git`, `curl` (or `wget`) and `tar` for the updates.
- A little-endian machine with 5.6 GB of disk space for the catalog.

## Installation

Nothing in the repository is edited for a particular host. The one
host-specific item is a symbolic link named `catalog` that tells where the
catalog is.

1. Get the catalog: the 900 zone files `z001` ... `z900` of UCAC5 in one
   directory. `lib/install_local_copy_of_UCAC5.sh` of VaST downloads them; a
   copy from another server will do as well.

2. Clone the repository to a place **outside** of the directories the web
   server publishes, as the user who will own the installation (the web
   server's user, or anybody else: the web server only has to read the files):

   ```
   git clone https://github.com/kirxkirx/ucac5_online_search.git /var/www/ucac5_online_search
   cd /var/www/ucac5_online_search
   ```

3. Point it to the catalog, build, and test:

   ```
   ln -s /path/to/the/UCAC5/zone/files catalog
   make check
   ```

   `make check` runs the offline tests and one search of the real catalog.
   `make verify-catalog` compares all the zone files with their known
   checksums; it reads the whole catalog, so run it once after a download.

4. Make the service visible to the web server with one more symbolic link:

   ```
   ln -s /var/www/ucac5_online_search/cgi-bin/ucac5 /var/www/my.server.net/cgi-bin/ucac5
   ```

   The linked directory contains a single file, `search_ucac5.py`. The search
   program, the sources, the tests, the updater and `.git` stay outside of
   the web server's reach, so the installation does not depend on `.htaccess`
   rules.

5. Check it over HTTP:

   ```
   tests/check_http.sh http://my.server.net/cgi-bin/ucac5/search_ucac5.py
   ```

6. Let cron keep it up to date, as the owner of the installation. A line for
   the system-wide `/etc/crontab` (here the owner is `apache`):

   ```
   10 15 * * * apache cd /var/www/ucac5_online_search && ./git_ucac5_automated_update.sh
   ```

### If the web server answers 403

Apache has to be allowed to follow the link: the `cgi-bin` directory needs
`Options FollowSymLinks`, or `Options SymLinksIfOwnerMatch` with the link and
the installation owned by the same user. Where that cannot be arranged, give
the service its own `ScriptAlias` in the server configuration instead of the
link of step 4, before the general `ScriptAlias /cgi-bin/` line:

```
ScriptAlias /cgi-bin/ucac5/ "/var/www/ucac5_online_search/cgi-bin/ucac5/"
<Directory "/var/www/ucac5_online_search/cgi-bin/ucac5">
    Require all granted
</Directory>
```

## Updates

`git_ucac5_automated_update.sh` is the way to update an installation, from
cron or by hand. It fetches the latest commit and switches to it only if

- all the GitHub Actions tests of that commit have passed, and
- the commit builds and passes the tests on this host, including a search of
  the real catalog, in a scratch copy next to the running installation.

After the switch it tests once more and returns to the previous commit if
anything fails. It prints nothing when there is nothing to do, so cron sends
mail only about an update or a problem. Options: `--force` skips the question
to GitHub (the local tests still run), `--verbose` reports also when there is
nothing to do.

A bare `git pull` checks nothing and does not rebuild the search program:
use the script. Local changes to tracked files are discarded by an update;
fixes belong in the repository.

## Is a server alive, and what does it run?

```
tests/check_http.sh http://scan.sai.msu.ru/cgi-bin/ucac5/search_ucac5.py
```

uploads 635 test positions with the same `curl` options as VaST, compares the
reply with the known 607 matches, and prints the version the server reports.
Run it against each server to see whether they are in sync.

## Replacing a hand-installed copy

Older installations are a directory `cgi-bin/ucac5/` with `search_ucac5.py`,
the compiled `search_ucac5` and a `files` link to a scratch directory in it.
To replace one, do steps 1-3 above, then swap the directory for the link and
check:

```
mv /var/www/my.server.net/cgi-bin/ucac5 /var/www/ucac5_cgi_before_git
ln -s /var/www/ucac5_online_search/cgi-bin/ucac5 /var/www/my.server.net/cgi-bin/ucac5
tests/check_http.sh http://my.server.net/cgi-bin/ucac5/search_ucac5.py
```

Move the old directory out of `cgi-bin`, as above, rather than renaming it in
place: everything executable under `cgi-bin` can be started by its URL. To
go back, remove the link and move the directory back. The new code keeps no
scratch files, so the `files` link is not needed any more.

## Files

| | |
|---|---|
| `cgi-bin/ucac5/search_ucac5.py` | the CGI script: checks the request, starts the search program, formats errors |
| `src/search_ucac5.c` | the search program, built as `bin/search_ucac5` |
| `git_ucac5_automated_update.sh` | the updater |
| `tests/test_offline.sh` | tests with a synthetic catalog of ten stars (`make test`) |
| `tests/test_real_catalog.sh` | one search of the real catalog without a web server (`make test-catalog`) |
| `tests/check_http.sh` | the same search through a web server |
| `tests/data/ucac5_zones.md5` | checksums of the zone files (`make verify-catalog`) |

## Copyleft

Copyleft Kirill Sokolovsky <kirx@kirx.net>. The matching routine comes from VaST.

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
FITNESS FOR A PARTICULAR PURPOSE. See the file [COPYING](COPYING).
