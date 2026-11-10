#!/usr/bin/env python3
"""CGI front end of the UCAC5 online search.

VaST (https://github.com/kirxkirx/vast) sends a list of star positions here
when it has no local copy of the UCAC5 catalog:

    curl -F file=@positions.txt -F brightmag=9 -F faintmag=16.5 \\
         -F searcharcsec=6 http://HOST/cgi-bin/ucac5/search_ucac5.py

The uploaded file has one "RA Dec" pair (degrees) per line. The reply is
plain text: a comment line starting with "#" that carries the version of
the service, then one line per matched star:

    input_RA input_Dec distance_arcsec cat_RA cat_Dec cat_mag epoch pmRA pmDE

VaST treats any reply of five or more lines as an answer, so every error
reply produced here is a single "#" line: the client then moves on to the
next server instead of taking an error page for search results.

This script contains no host-specific settings. It finds the search program
(bin/search_ucac5) and the catalog (the "catalog" symlink) in the directory
tree it is installed from, see README.md. It needs Python 3.6 or newer and
only the standard library.
"""

import math
import os
import random
import subprocess
import sys
import time
import traceback
from email import policy
from email.parser import BytesParser

# The directory tree this script belongs to: <root>/cgi-bin/ucac5/search_ucac5.py
# realpath() resolves the symlink through which the web server reaches the script.
ROOT_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.realpath(__file__))))
SEARCH_PROGRAM = os.path.join(ROOT_DIR, 'bin', 'search_ucac5')
CATALOG_DIR = os.path.join(ROOT_DIR, 'catalog')

MAX_UPLOAD_BYTES = 10000000
# The four form fields and the multipart framing add little to the upload
MAX_REQUEST_BYTES = MAX_UPLOAD_BYTES + 100000
MAX_NUMBER_LENGTH = 10
SEARCH_TIMEOUT_SEC = 300

# Limits on the search parameters (the same as in the original service)
MIN_BRIGHT_MAG = 0.0
MAX_FAINT_MAG = 20.0
MAX_SEARCH_RADIUS_ARCSEC = 60.0
DEFAULT_BRIGHT_MAG = '0'
DEFAULT_FAINT_MAG = '16'
DEFAULT_SEARCH_RADIUS_ARCSEC = '10'

# 5-minute load average per CPU core: wait above the first, refuse above the second
BUSY_LOAD_PER_CORE = 1.5
OVERLOAD_PER_CORE = 2.0
MAX_WAIT_FOR_LOWER_LOAD_SEC = 120


class RequestError(Exception):
    """A problem to report to the client: HTTP status line and a one-line message."""

    def __init__(self, status, message):
        Exception.__init__(self, message)
        self.status = status
        self.message = message


def send_reply(status, body):
    """Write the complete CGI response; body is bytes."""
    out = sys.stdout.buffer
    out.write(('Status: %s\r\nContent-Type: text/plain\r\n\r\n' % status).encode('ascii'))
    out.write(body)
    out.flush()


def send_error(status, message):
    """Error replies are one comment line, see the module docstring."""
    one_line = ' '.join(str(message).split())
    send_reply(status, ('# ERROR: %s\n' % one_line).encode('ascii', 'replace'))


def log(message):
    """One line to the web server's error log."""
    sys.stderr.write('search_ucac5.py: %s\n' % message)
    sys.stderr.flush()


def wait_for_lower_load():
    """Hold the request while the machine is busy; give up if it is overloaded."""
    try:
        cores = os.cpu_count() or 1
        deadline = time.time() + MAX_WAIT_FOR_LOWER_LOAD_SEC
        while True:
            load = os.getloadavg()[1]
            if load <= BUSY_LOAD_PER_CORE * cores:
                return
            if load > OVERLOAD_PER_CORE * cores or time.time() > deadline:
                raise RequestError('503 Service Unavailable',
                                   'the server is too busy (load %.1f), try another one' % load)
            time.sleep(random.uniform(1.0, 15.0))
    except (OSError, AttributeError):
        # no load information on this system: carry on
        return


def read_form():
    """Return the fields of a multipart/form-data POST as {name: bytes}."""
    content_type = os.environ.get('CONTENT_TYPE', '')
    if not content_type.lower().startswith('multipart/form-data'):
        raise RequestError('400 Bad Request', 'expecting a multipart/form-data upload')
    try:
        content_length = int(os.environ.get('CONTENT_LENGTH', ''))
    except ValueError:
        raise RequestError('411 Length Required', 'no Content-Length')
    if content_length < 0:
        raise RequestError('400 Bad Request', 'bad Content-Length')
    if content_length > MAX_REQUEST_BYTES:
        raise RequestError('413 Payload Too Large', 'the uploaded file is too large')
    body = sys.stdin.buffer.read(content_length)
    if len(body) != content_length:
        raise RequestError('400 Bad Request', 'incomplete request body')
    # The body of a form upload is a MIME multipart message without its header
    header = b'MIME-Version: 1.0\r\nContent-Type: ' + content_type.encode('latin-1') + b'\r\n\r\n'
    message = BytesParser(policy=policy.HTTP).parsebytes(header + body)
    fields = {}
    if message.is_multipart():
        for part in message.iter_parts():
            name = part.get_param('name', header='content-disposition')
            if name is not None and name not in fields:
                fields[name] = part.get_payload(decode=True) or b''
    return fields


def get_number(fields, name, default):
    """A form field as a finite float (the same length cut as the original service)."""
    if name in fields:
        text = fields[name].decode('latin-1').strip()
    else:
        text = default
    text = text[:MAX_NUMBER_LENGTH]
    try:
        value = float(text)
    except ValueError:
        raise RequestError('400 Bad Request', '%s is not a number' % name)
    if not math.isfinite(value):
        raise RequestError('400 Bad Request', '%s is not a finite number' % name)
    return value


def run_search_program(arguments, positions=None):
    """Run bin/search_ucac5 and return its standard output (bytes)."""
    if not os.access(SEARCH_PROGRAM, os.X_OK):
        log('%s is not found - run make in %s' % (SEARCH_PROGRAM, ROOT_DIR))
        raise RequestError('500 Internal Server Error', 'the search program is not installed')
    # The program gets the uploaded positions on its standard input and nothing
    # else from the request: no shell and no temporary files are involved.
    if positions is None:
        input_options = {'stdin': subprocess.DEVNULL}
    else:
        input_options = {'input': positions}
    try:
        result = subprocess.run([SEARCH_PROGRAM] + arguments,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                timeout=SEARCH_TIMEOUT_SEC, **input_options)
    except subprocess.TimeoutExpired:
        log('the search did not finish in %d seconds' % SEARCH_TIMEOUT_SEC)
        raise RequestError('504 Gateway Timeout', 'the search took too long')
    if result.returncode != 0:
        log('%s exited with code %d: %s' % (SEARCH_PROGRAM, result.returncode,
                                            result.stderr.decode('latin-1').strip()))
        raise RequestError('500 Internal Server Error', 'the catalog search failed')
    return result.stdout


def handle_request():
    method = os.environ.get('REQUEST_METHOD', 'GET').upper()

    if method in ('GET', 'HEAD'):
        # Not a search: tell which version is installed here
        version_line = run_search_program(['--version'])
        send_reply('200 OK', version_line
                   + b'# POST a multipart form with the fields file, brightmag, faintmag, searcharcsec\n')
        return

    if method != 'POST':
        raise RequestError('405 Method Not Allowed', 'use POST')

    fields = read_form()

    if 'file' not in fields:
        raise RequestError('400 Bad Request', 'no file field in the form')
    positions = fields['file']
    if len(positions) > MAX_UPLOAD_BYTES:
        raise RequestError('413 Payload Too Large', 'the uploaded file is too large')
    if b'\0' in positions:
        raise RequestError('400 Bad Request', 'the uploaded file is not a text file')

    bright_mag = max(get_number(fields, 'brightmag', DEFAULT_BRIGHT_MAG), MIN_BRIGHT_MAG)
    faint_mag = min(get_number(fields, 'faintmag', DEFAULT_FAINT_MAG), MAX_FAINT_MAG)
    search_radius_arcsec = min(get_number(fields, 'searcharcsec', DEFAULT_SEARCH_RADIUS_ARCSEC),
                               MAX_SEARCH_RADIUS_ARCSEC)

    if not os.path.isdir(CATALOG_DIR):
        log('%s is not a directory - make it a symlink to the UCAC5 zone files' % CATALOG_DIR)
        raise RequestError('500 Internal Server Error', 'the catalog is not installed')

    wait_for_lower_load()

    matches = run_search_program([CATALOG_DIR, repr(bright_mag), repr(faint_mag),
                                  repr(search_radius_arcsec)], positions)
    send_reply('200 OK', matches)


def main():
    try:
        handle_request()
    except RequestError as error:
        send_error(error.status, error.message)
    except Exception:
        # Never let the web server answer with its own (long) error page
        log(traceback.format_exc())
        send_error('500 Internal Server Error', 'internal error')


if __name__ == '__main__':
    main()
