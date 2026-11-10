#!/var/www/cgi-venv/bin/python3.12
import cgi, os
import cgitb; cgitb.enable()

import random
import string
import time
import sys 
import socket
import re

file_readwrite_buffer_size = 8192
MAX_FILE_SIZE = 10000000

def is_suspicious_filename(filename):
    MAX_LENGTH = 255
    SUSPICIOUS_EXTENSIONS = [
        '.php', '.py', '.pl', '.sh', '.rb', '.zip',
        '.gz', '.bz2', '.rar', '.7z', '.tar', '.exe',
        '.png', '.jpg', '.jpeg']
    
    unusual_chars_pattern = re.compile(r'[^a-zA-Z0-9._+\-]')

    if len(filename) > MAX_LENGTH:
        return True

    _, file_extension = os.path.splitext(filename)
    if file_extension.lower() in SUSPICIOUS_EXTENSIONS:
        return True

    if unusual_chars_pattern.search(filename):
        return True

    return False

def truncate_string(input_string, N):
    return input_string[:N]

def is_valid_string(s):
    if s.startswith("."):
        return False
    if ".." in s or "/" in s:
        return False
    return all(c.isalnum() or c == '_' or c == '.' for c in s)

def is_text_but_not_script(file_path):
    try:
        with open(file_path, 'rb') as file:
            snippet = file.read(1024)

        if b'\0' in snippet:
            return False

        script_patterns = [
            b'<?php', b'<?=', b'<?', b'#!/usr/bin/env python',
            b'#!/usr/bin/python', b'#!/usr/bin/env perl',
            b'#!/usr/bin/perl', b'#!/bin/sh', b'#!/bin/bash',
            b'#!/usr/bin/env sh', b'#!/usr/bin/env bash', b'#!/'
        ]

        return not any(pattern in snippet for pattern in script_patterns)
    except IOError:
        return False

def is_archive(filename):
    with open(filename, 'rb') as file:
        header = file.read(10)

    if header.startswith(b'\x50\x4B\x03\x04') or \
       header.startswith(b'\x1F\x8B') or \
       header.startswith(b'\x52\x61\x72\x21') or \
       header.startswith(b'\x37\x7A\xBC\xAF\x27\x1C') or \
       header.startswith(b'\x42\x5A\x68') or \
       header.startswith(b'\x75\x73\x74\x61'):
        return True

    return False

def fbuffer(f, chunk_size):
    total_size = 0
    while True:
        chunk = f.read(chunk_size)
        if not chunk:
            break
        total_size += len(chunk)
        if total_size > MAX_FILE_SIZE:
            raise ValueError("File size exceeds the limit")
        yield chunk

cgitb.enable(display=0, logdir='/var/www/scan.sai.msu.ru/cgi-bin/ucac5/files/log')

message = f'Starting program {sys.argv[0]} <br>'

emergency_load = 50.0
max_load = 40.0
load = 99.0
while load > max_load:
    load = 0.0
    if os.access('/proc/loadavg', os.R_OK):
        with open('/proc/loadavg', 'r') as procload:
            loadline = procload.readline()
        load = float(loadline.split()[1])
        if load > emergency_load:
            sys.exit(1)
        if load > max_load:
            random.seed()
            sleep_time = 60 * random.random()
            time.sleep(sleep_time)
             
form = cgi.FieldStorage()

brightmag = truncate_string(form.getvalue('brightmag', '0'), 10)
faintmag = truncate_string(form.getvalue('faintmag', '16'), 10)
searcharcsec = truncate_string(form.getvalue('searcharcsec', '10'), 10)

def is_number(s):
    try:
        float(s)
    except ValueError:
        return False
    return True

for parameter in [brightmag, faintmag, searcharcsec]:
    if not is_number(parameter):
        sys.exit(1)

brightmag = max(float(brightmag), 0)
faintmag = min(float(faintmag), 20)
searcharcsec = min(float(searcharcsec), 60)

fileitem = form['file']

pid = os.getpid()
JobID = str(pid)
random.seed()
JobID += ''.join(random.choice(string.ascii_letters) for _ in range(8))

if not is_valid_string(JobID):
    print("Content-Type: text/html\n")
    print("<html><body><p>Bad string JobID</p></body></html>")
    sys.exit(1)

dirname = 'files/' + JobID
os.mkdir(dirname)
dirname += '/'

safe_serverside_filename_for_original_lightcurve_file = 'input.txt'
fn = os.path.basename(safe_serverside_filename_for_original_lightcurve_file)
file_path = os.path.join(dirname, fn)

if os.path.exists(file_path):
    print("Content-Type: text/html\n")
    print("<html><body><p>ERROR!!! The output file already exist</p></body></html>")
    sys.exit(0)

try:
    with open(file_path, 'wb') as f:
        for chunk in fbuffer(fileitem.file, file_readwrite_buffer_size):
            f.write(chunk)
except ValueError as e:
    os.remove(file_path)
    print("Content-Type: text/html\n")
    print("<html><body><p>ERROR!!! The lightcurve file is too large</p></body></html>")
    sys.exit(1)
except IOError as e:
    print("I/O Error:", e)
    sys.exit(1)

if not os.path.exists(file_path):
    print("Content-Type: text/html\n")
    print(f"<html><body><p>ERROR: file_path does not exist {file_path}</p></body></html>")
    sys.exit(1)

if is_archive(file_path) or not is_text_but_not_script(file_path):
    os.remove(file_path)
    sys.exit(1)

fullhostname = socket.getfqdn()
syscmd = f'ls -lh {dirname}{fn} > {dirname}program.log'
CmdReturnStatus = os.system(syscmd)

syscmd = f'export PATH=$PWD:$PATH; cd {dirname}; if [ "{fn}" != "input.txt" ];then mv {fn} input.txt;fi; search_ucac5 {brightmag} {faintmag} {searcharcsec} &>> program.log'
CmdReturnStatus = os.system(f'echo "{syscmd}" >> {dirname}program.log')
CmdReturnStatus = os.system(syscmd)

if os.path.exists(file_path):
    os.remove(file_path)

with open(f'{dirname}output.txt', 'r') as f:
    for line in f:
        message += f'{line}'

print(f"Content-Type: text/txt\n\n{message}")

sys.exit(0)
