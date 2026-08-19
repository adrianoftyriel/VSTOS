#!/usr/bin/env python3
"""Render a VSTOS template by substituting @KEY@ placeholders.

    render-template.py SRC DEST KEY=VALUE [KEY=VALUE ...]

Substitution is a single left-to-right pass, so a value that happens to contain
another key's placeholder text cannot be rewritten again by a later key. Doing it
with repeated str.replace() would allow exactly that, and the failure would be
invisible until something matched the wrong device.

Exits 3 if the template declares a placeholder no value was given for; the caller
turns that into an error naming the file, because an unrendered placeholder is a
silent misconfiguration rather than a crash.
"""
import pathlib
import re
import sys

PLACEHOLDER = re.compile(r"@[A-Z_][A-Z0-9_]*@")


def main(argv):
    if len(argv) < 3:
        sys.stderr.write(__doc__)
        return 2

    src, dest = argv[1], argv[2]
    subs = {}
    for pair in argv[3:]:
        key, sep, value = pair.partition("=")
        if not sep:
            sys.stderr.write("render-template: not a KEY=VALUE pair: %r\n" % pair)
            return 2
        subs["@%s@" % key] = value

    text = pathlib.Path(src).read_text()

    # Check the template, not the rendered output. Checking the output would flag
    # a placeholder that arrived as part of a *value*, which is a false alarm: the
    # question is whether every placeholder this template declares was given
    # something, and values are opaque once substituted.
    left = sorted(set(PLACEHOLDER.findall(text)) - set(subs))
    if left:
        sys.stderr.write("render-template: no value given for %s in %s\n" % (" ".join(left), src))
        return 3

    pathlib.Path(dest).write_text(PLACEHOLDER.sub(lambda m: subs.get(m.group(0), m.group(0)), text))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
