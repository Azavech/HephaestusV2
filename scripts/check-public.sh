#!/bin/bash
# Fails when the repository holds personal data (docs/ci.md › check-public.sh).
#
#   scripts/check-public.sh [<path>…]
#
# Scans the tracked files and the untracked files that .gitignore does not ignore, skipping binary
# files, or only the given paths (relative to the repository root). Prints `<path>:<line>: <rule>`
# for each finding, sorted by path and line, never the matched text. Exit status: 0 without
# findings, 1 with findings, 2 when a given path does not exist or is outside the repository.
set -euo pipefail

cd "$(dirname "$0")/.."

read -r -d '' program << 'PYTHON' || true
import os
import re
import subprocess
import sys

root = os.getcwd()

def usage_error(message):
    sys.stderr.write("check-public.sh: " + message + "\n")
    sys.exit(2)

paths = sys.argv[1:]
for path in paths:
    full = os.path.realpath(os.path.join(root, path))
    if not os.path.lexists(os.path.join(root, path)):
        usage_error(path + " does not exist")
    if full != root and not full.startswith(root + os.sep):
        usage_error(path + " is outside the repository")

listing = subprocess.run(
    ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--"] + (paths or ["."]),
    check=True, stdout=subprocess.PIPE).stdout
files = sorted(set(name for name in listing.decode("utf-8", "surrogateescape").split("\0") if name))

NAME = "[A-Za-z0-9._-]"
HOME_PATH = re.compile(r"/Users/(" + NAME + r"+)")
ALLOWED_HOMES = {"example", "Shared"}

EMAIL = re.compile(r"([A-Za-z0-9._%+-]+)@((?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,})")
ALLOWED_LOCALS = {"noreply", "no-reply"}
EXAMPLE_DOMAINS = ("example.com", "example.org", "example.net")
SCALE_SUFFIX = re.compile(r"[0-9]+x\.")

TEAM_SETTING = re.compile(r"DEVELOPMENT_TEAM[ \t]*[=:](.*)")
TEAM_KEYWORDS = ("DEVELOPMENT_TEAM", "TeamIdentifier", "teamID", "team-id", "team_id", "--team",
                 "Developer ID Application", "codesign")
TOKEN = re.compile(r"[A-Za-z0-9]+")

def email_allowed(local, domain):
    local = local.lower()
    domain = domain.lower()
    if local in ALLOWED_LOCALS:
        return True
    if any(domain == allowed or domain.endswith("." + allowed) for allowed in EXAMPLE_DOMAINS):
        return True
    if domain.endswith(".noreply.github.com"):
        return True
    return SCALE_SUFFIX.match(domain) is not None

def team_value_set(value):
    value = value.strip(" \t")
    if value.endswith(";"):
        value = value[:-1]
    value = value.strip(" \t\"'")
    return value != "" and not value.startswith("$")

def team_id_token(line):
    for token in TOKEN.findall(line):
        if (len(token) == 10 and re.fullmatch(r"[A-Z0-9]+", token)
                and re.search(r"[A-Z]", token) and re.search(r"[0-9]", token)):
            return True
    return False

def findings(line):
    rules = []
    if any(match.group(1) not in ALLOWED_HOMES for match in HOME_PATH.finditer(line)):
        rules.append("home-path")
    if any(not email_allowed(match.group(1), match.group(2)) for match in EMAIL.finditer(line)):
        rules.append("email")
    if any(team_value_set(match.group(1)) for match in TEAM_SETTING.finditer(line)):
        rules.append("team-setting")
    if any(keyword in line for keyword in TEAM_KEYWORDS) and team_id_token(line):
        rules.append("team-id")
    return rules

def read(name):
    full = os.path.join(root, name)
    if os.path.islink(full):
        return os.readlink(full).encode("utf-8", "surrogateescape")
    if not os.path.isfile(full):
        return None
    with open(full, "rb") as handle:
        return handle.read()

found = []
for name in files:
    data = read(name)
    # Binary files are skipped, as `git grep -I` does: a NUL byte in the first 8000 bytes.
    if data is None or b"\0" in data[:8000]:
        continue
    text = data.decode("utf-8", "replace")
    for number, line in enumerate(text.split("\n"), start=1):
        for rule in findings(line):
            found.append((name, number, rule))

for name, number, rule in sorted(found, key=lambda item: (item[0], item[1])):
    print("%s:%d: %s" % (name, number, rule))
sys.exit(1 if found else 0)
PYTHON

exec python3 -I -c "$program" "$@"
