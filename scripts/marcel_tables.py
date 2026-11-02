#!/usr/bin/env python3
"""Writes data/marcel.txt, the Marcel 1.1.0 tables storage.goose identifies content types with.

The source is tables.rs of basecamp/once-campfire-rust (crates/storage/src/tables.rs, MIT), which
reference-tools/storage/dump_tables.rb dumped from the reference image's Marcel bundle:

    python3 scripts/marcel_tables.py path/to/tables.rs > data/marcel.txt

Each line is one record, fields separated by tabs (a type may end in a space):
    e <extension> <type>            Marcel::EXTENSIONS
    t <type> <extension>...         Marcel::TYPE_EXTS, the extensions in order
    p <type> <parent>...            Marcel::TYPE_PARENTS
    m <type>                        a Marcel::MAGIC entry, in table order, with its matches after it:
    n <depth> <offset> <end> <hex>  a match in preorder: depth 0 for the entry's own, <end> the
                                    range's end or -, <hex> the value's bytes or - for none
"""
import re
import sys


def unescape(literal):
    out = bytearray()
    i = 0
    while i < len(literal):
        c = literal[i]
        if c != "\\":
            out += c.encode()
            i += 1
            continue
        n = literal[i + 1]
        if n == "x":
            out.append(int(literal[i + 2:i + 4], 16))
            i += 4
        else:
            out.append({"n": 10, "r": 13, "t": 9, "0": 0, "\\": 92, '"': 34, "'": 39}[n])
            i += 2
    return bytes(out)


class Matches:
    def __init__(self, text):
        self.text, self.at = text, 0

    def skip(self, token):
        while self.text[self.at] in " \n":
            self.at += 1
        assert self.text.startswith(token, self.at), (token, self.text[self.at:self.at + 40])
        self.at += len(token)

    def peek(self, token):
        while self.text[self.at] in " \n":
            self.at += 1
        return self.text.startswith(token, self.at)

    def number(self):
        while self.text[self.at] == " ":
            self.at += 1
        m = re.compile(r"\d+").match(self.text, self.at)
        self.at = m.end()
        return int(m.group())

    def list(self, depth, out):
        self.skip("&[")
        while not self.peek("]"):
            self.skip("Match {")
            self.skip("offset:")
            offset = self.number()
            self.skip(",")
            self.skip("range_end:")
            if self.peek("None"):
                self.skip("None")
                end = "-"
            else:
                self.skip("Some(")
                end = str(self.number())
                self.skip(")")
            self.skip(",")
            self.skip("value:")
            if self.peek("None"):
                self.skip("None")
                value = "-"
            else:
                self.skip('Some(b"')
                m = re.compile(r'((?:[^"\\]|\\.)*)"').match(self.text, self.at)
                self.at = m.end()
                value = unescape(m.group(1)).hex() or "="
                self.skip(")")
            self.skip(",")
            self.skip("children:")
            out.append(f"n\t{depth}\t{offset}\t{end}\t{value}")
            self.list(depth + 1, out)
            self.skip("}")
            if self.peek(","):
                self.skip(",")
        self.skip("]")


def section(text, name):
    start = text.index(f"pub static {name}:")
    start = text.index("= &[\n", start) + 5
    return text[start:text.index("\n];", start)]


def main():
    text = open(sys.argv[1], encoding="utf-8").read()
    lines = []
    for ext, kind in re.findall(r'\("([^"]*)", "([^"]*)"\)', section(text, "EXTENSIONS")):
        lines.append(f"e\t{ext}\t{kind}")
    for name, letter in (("TYPE_EXTS", "t"), ("TYPE_PARENTS", "p")):
        for kind, values in re.findall(r'\("([^"]*)", &\[([^\]]*)\]\)', section(text, name)):
            lines.append("\t".join([letter, kind] + re.findall(r'"([^"]*)"', values)))
    for row in section(text, "MAGIC").split("\n"):
        m = re.match(r'\s*\("([^"]*)", ', row)
        lines.append(f"m\t{m.group(1)}")
        Matches(row[m.end():]).list(0, lines)
    for line in lines:
        assert "\n" not in line and all(part for part in line.split("\t")), line
    sys.stdout.write("".join(line + "\n" for line in lines))


if __name__ == "__main__":
    main()
