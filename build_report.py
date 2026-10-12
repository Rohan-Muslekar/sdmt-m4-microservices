#!/usr/bin/env python3
"""
build_report.py - render REPORT.md to a polished, self-contained, printable
HTML report.

Workflow: write REPORT.md, run this, open the HTML in Chrome, print to PDF
(Ctrl+P, Save as PDF, Background graphics ON). Save as 101006689-ms4-report.pdf.

The output is one self-contained file: screenshots are embedded as data URIs
and images referenced by ![caption](path) become numbered figures. Fonts come
from Google Fonts with system fallbacks, so it stays readable offline too.

    python3 build_report.py            # REPORT.md -> 101006689-ms4-report.html
    python3 build_report.py in.md out.html
"""
import base64
import mimetypes
import re
import sys
from pathlib import Path

import markdown  # pip install markdown  (3.x)

STUDENT_ID = "101006689"


def inline_images(html: str, base_dir: Path) -> str:
    """Replace <img src="local/path"> with a base64 data URI. Remote srcs kept."""
    def repl(match: "re.Match") -> str:
        src = match.group(1)
        if src.startswith(("http://", "https://", "data:")):
            return match.group(0)
        f = base_dir / src
        if not f.exists():
            print(f"  WARNING: image not found, left as link: {src}")
            return match.group(0)
        mime = mimetypes.guess_type(str(f))[0] or "image/png"
        b64 = base64.b64encode(f.read_bytes()).decode("ascii")
        return match.group(0).replace(f'src="{src}"', f'src="data:{mime};base64,{b64}"')
    return re.sub(r'<img[^>]*\ssrc="([^"]+)"', repl, html)


def wrap_figures(html: str) -> str:
    """Turn a standalone <p><img alt="cap" ...></p> into a numbered <figure>."""
    n = [0]

    def repl(match: "re.Match") -> str:
        img = match.group(1)
        alt = re.search(r'alt="([^"]*)"', img)
        cap = alt.group(1) if alt else ""
        n[0] += 1
        caption = f"<figcaption><b>Figure {n[0]}.</b> {cap}</figcaption>" if cap else ""
        return f"<figure>{img}{caption}</figure>"

    return re.sub(r'<p>(<img[^>]*>)</p>', repl, html)


def wrap_cover(html: str) -> str:
    """Wrap the metadata paragraphs between the title <h1> and the first <h2>
    in a styled cover block."""
    return re.sub(
        r'(</h1>)(.*?)(<h2)',
        lambda m: f'{m.group(1)}<div class="meta">{m.group(2)}</div>{m.group(3)}',
        html, count=1, flags=re.DOTALL,
    )


def render(md_path: Path, html_path: Path) -> None:
    text = md_path.read_text(encoding="utf-8")
    if "—" in text or "–" in text:
        raise SystemExit("REPORT.md contains an em/en dash. Replace with a hyphen.")

    body = markdown.markdown(
        text, extensions=["tables", "fenced_code", "sane_lists", "toc"]
    )
    body = body.replace("<table>", '<table cellspacing="0">')
    body = inline_images(body, md_path.parent)
    body = wrap_figures(body)
    body = wrap_cover(body)

    html = TEMPLATE.replace("{{BODY}}", body)
    html_path.write_text(html, encoding="utf-8")
    print(f"wrote {html_path}  ({len(html):,} bytes)")
    print("Next: open in Chrome, Ctrl+P, Save as PDF, Background graphics ON,")
    print(f"      save as {STUDENT_ID}-ms4-report.pdf")


TEMPLATE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Milestone 4 Report</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Fraunces:opsz,wght@9..144,500;9..144,600;9..144,700&family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;600&display=swap">
<style>
  :root {
    --navy: #0a2540;
    --navy-soft: #143a5c;
    --accent: #e8611a;
    --ink: #1a2530;
    --muted: #5b6b7a;
    --line: #d8e0e8;
    --bg: #eef2f6;
    --surface: #ffffff;
    --soft: #f5f8fb;
    --code-bg: #0d1b2a;
    --code-ink: #e6edf3;
    --code-key: #ffb27a;
    --good: #1f7a4d;
  }
  html { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
  * { box-sizing: border-box; }
  body {
    font-family: "Inter", system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
    color: var(--ink); background: var(--bg);
    line-height: 1.6; font-size: 11pt; margin: 0;
  }
  .page {
    max-width: 8.1in; margin: 0 auto; background: var(--surface);
    padding: 0.55in 0.7in 0.7in;
    box-shadow: 0 1px 6px rgba(10,37,64,.08);
  }

  /* Cover header */
  .page > h1:first-child {
    font-family: "Fraunces", Georgia, serif;
    font-weight: 700; font-size: 27pt; line-height: 1.1; color: #fff;
    background: linear-gradient(135deg, var(--navy) 0%, var(--navy-soft) 100%);
    margin: -0.55in -0.7in 0; padding: 0.5in 0.7in 0.2in;
    border-bottom: 5px solid var(--accent); text-wrap: balance;
  }
  /* metadata cover block (the **Course:** ... lines) */
  .meta {
    background: var(--navy); color: #d9e6f2;
    margin: 0 -0.7in 0.4em; padding: 16px 0.7in 18px;
  }
  .meta p { margin: 3px 0; font-size: 10.5pt; }
  .meta strong { color: #fff; font-weight: 600; }
  .meta a { color: #bfe0f0; border-bottom-color: #4a7c99; }
  hr { border: none; border-top: 2px solid var(--line); margin: 1.4em 0; }

  h2 {
    font-family: "Fraunces", Georgia, serif; font-weight: 600;
    font-size: 16pt; color: var(--navy); margin: 1.7em 0 0.6em;
    padding: 2px 0 5px 13px; border-bottom: 2px solid var(--line);
    border-left: 6px solid var(--accent);
  }
  h3 {
    font-family: "Inter", sans-serif; font-weight: 700;
    font-size: 12pt; color: var(--navy-soft); margin: 1.3em 0 0.3em;
  }
  p { margin: 0.55em 0; }
  strong { color: var(--navy-soft); }

  a { color: #0a5c8a; text-decoration: none; border-bottom: 1px solid #9cc4d9; }

  ul, ol { margin: 0.5em 0; padding-left: 1.3em; }
  li { margin: 0.25em 0; }

  code {
    font-family: "JetBrains Mono", Consolas, monospace; font-size: 9.2pt;
    background: var(--soft); border: 1px solid var(--line);
    padding: 1px 5px; border-radius: 4px; color: var(--navy-soft);
  }
  pre {
    background: var(--code-bg); color: var(--code-ink);
    border-radius: 8px; padding: 13px 15px; overflow-x: auto;
    margin: 0.8em 0; page-break-inside: avoid;
    box-shadow: 0 1px 3px rgba(10,37,64,.15);
    white-space: pre-wrap; overflow-wrap: anywhere;
  }
  pre code {
    font-family: "JetBrains Mono", Consolas, monospace; font-size: 8.8pt;
    background: none; border: none; padding: 0; color: var(--code-ink);
  }

  table {
    border-collapse: collapse; width: 100%; margin: 1em 0;
    font-size: 10pt; page-break-inside: avoid;
    border: 1px solid var(--line); border-radius: 8px; overflow: hidden;
    /* Fixed layout divides the width evenly instead of letting one long
       literal set a column's width and push the table past the page edge.
       A printed page cannot scroll, so every cell has to wrap instead. */
    table-layout: fixed;
  }
  table code {
    /* Break inside a long token like attributes.function="convert" rather
       than forcing the column wider than the page. */
    overflow-wrap: anywhere; word-break: break-word;
  }
  td, th { overflow-wrap: anywhere; }
  thead th {
    background: var(--navy); color: #fff; font-weight: 600;
    text-align: left; padding: 9px 11px;
  }
  tbody td { padding: 8px 11px; border-top: 1px solid var(--line); vertical-align: top; hyphens: auto; }
  tbody tr:nth-child(even) { background: var(--soft); }

  figure {
    margin: 1.1em 0; text-align: center; page-break-inside: avoid;
    background: var(--soft); border: 1px solid var(--line);
    border-radius: 8px; padding: 10px;
  }
  figure img {
    max-width: 100%; height: auto; border: 1px solid var(--line);
    border-radius: 4px; box-shadow: 0 1px 4px rgba(10,37,64,.12);
  }
  figcaption {
    font-size: 9pt; color: var(--muted); margin-top: 8px;
    font-style: italic; text-align: center;
  }
  figcaption b { color: var(--navy-soft); font-style: normal; }

  blockquote {
    border-left: 4px solid var(--accent); background: var(--soft);
    margin: 1em 0; padding: 8px 14px; color: var(--ink); border-radius: 0 6px 6px 0;
  }

  em { color: var(--muted); }

  @page { margin: 0.5in; }
  @media print {
    body { background: #fff; }
    .page { box-shadow: none; max-width: none; margin: 0; padding: 0 0.15in; }
    .page > h1:first-child { margin-top: 0; }
    h2 { break-after: avoid; }
    figure, table, pre { break-inside: avoid; }
  }
</style>
</head>
<body>
<div class="page">
{{BODY}}
</div>
</body>
</html>
"""


def main() -> None:
    args = sys.argv[1:]
    md = Path(args[0]) if args else Path("REPORT.md")
    out = Path(args[1]) if len(args) > 1 else Path(f"{STUDENT_ID}-ms4-report.html")
    if not md.exists():
        raise SystemExit(f"{md} not found")
    render(md, out)


if __name__ == "__main__":
    main()
