#!/usr/bin/env python3
"""Run a CGI script the way a web server would, without a web server.

Usage: cgi_request.py SCRIPT [--method METHOD] [--file PATH] [--field NAME=VALUE ...]
                      [--content-type TYPE] [--content-length N]

With --file and/or --field a multipart/form-data body is built as curl -F
builds it (the file goes into the form field "file"). --content-type and
--content-length override the request headers, to imitate broken requests.
The complete response of the script (header and body) goes to standard
output; the exit code is that of the script.
"""

import argparse
import os
import subprocess
import sys

BOUNDARY = '------------------------cgirequestboundary7f3a'


def multipart_body(file_path, fields):
    parts = []
    if file_path is not None:
        with open(file_path, 'rb') as upload:
            content = upload.read()
        parts.append(('Content-Disposition: form-data; name="file"; filename="%s"\r\n'
                      'Content-Type: text/plain\r\n\r\n' % os.path.basename(file_path)).encode('ascii') + content)
    for field in fields:
        name, _, value = field.partition('=')
        parts.append(('Content-Disposition: form-data; name="%s"\r\n\r\n%s' % (name, value)).encode('ascii'))
    delimiter = ('--' + BOUNDARY + '\r\n').encode('ascii')
    body = b''.join(delimiter + part + b'\r\n' for part in parts)
    return body + ('--' + BOUNDARY + '--\r\n').encode('ascii')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('script')
    parser.add_argument('--method', default=None)
    parser.add_argument('--file', default=None)
    parser.add_argument('--field', action='append', default=[])
    parser.add_argument('--content-type', default=None)
    parser.add_argument('--content-length', default=None)
    args = parser.parse_args()

    script = os.path.abspath(args.script)
    has_form = args.file is not None or args.field
    body = multipart_body(args.file, args.field) if has_form else b''
    method = args.method or ('POST' if has_form else 'GET')

    # A minimal CGI environment; PATH is kept so that "env python3" works as it does under the web server
    environment = {
        'PATH': os.environ.get('PATH', '/usr/bin:/bin'),
        'GATEWAY_INTERFACE': 'CGI/1.1',
        'SERVER_PROTOCOL': 'HTTP/1.1',
        'SERVER_SOFTWARE': 'cgi_request.py',
        'SERVER_NAME': 'localhost',
        'SERVER_PORT': '80',
        'REMOTE_ADDR': '127.0.0.1',
        'REQUEST_METHOD': method,
        'SCRIPT_NAME': '/cgi-bin/ucac5/' + os.path.basename(script),
        'SCRIPT_FILENAME': script,
        'QUERY_STRING': '',
        'PYTHONDONTWRITEBYTECODE': '1',
    }
    if method == 'POST':
        environment['CONTENT_TYPE'] = 'multipart/form-data; boundary=' + BOUNDARY
        environment['CONTENT_LENGTH'] = str(len(body))
    if args.content_type is not None:
        environment['CONTENT_TYPE'] = args.content_type
    if args.content_length is not None:
        environment['CONTENT_LENGTH'] = args.content_length

    # The web server starts a CGI script in the directory of the script
    result = subprocess.run([script], input=body, env=environment, cwd=os.path.dirname(script))
    sys.exit(result.returncode)


if __name__ == '__main__':
    main()
