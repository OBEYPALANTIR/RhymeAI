"""Command-line interface.

    python3 lens.py "Company Name"                # live report to terminal
    python3 lens.py "Company Name" --html out.html
    python3 lens.py --demo                        # bundled sample data, offline
"""

import argparse
import datetime
import json
import os
import sys

from .http import SourceUnavailable
from .report import terminal_report, html_report, json_report
from .sources import usaspending, lobbying, fec, sec, epa

FIXTURE_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "tests", "fixtures")

DEMO_COMPANY = "Example Corp"


def _load_fixture(name):
    with open(os.path.join(FIXTURE_DIR, name), encoding="utf-8") as fh:
        return json.load(fh)


def gather_demo():
    """Build a report from bundled fixture data — works fully offline."""
    data = {
        "contracts": usaspending.parse(_load_fixture("usaspending.json")),
        "lobbying": lobbying.parse(_load_fixture("lda.json")),
        "fec": fec.parse(_load_fixture("fec_committees.json"),
                         _load_fixture("fec_schedule_a.json")),
        "sec": sec.parse(_load_fixture("sec_submissions.json"),
                         "EXAMPLE CORP", "XMPL"),
        "epa": epa.parse(_load_fixture("echo.json")),
    }
    return data, []


def gather_live(company, args):
    """Query every source, collecting per-source errors instead of dying."""
    data = {}
    errors = []
    steps = [
        ("contracts", lambda: usaspending.fetch(
            company, years=args.years, limit=args.limit)),
        ("lobbying", lambda: lobbying.fetch(company, page_size=args.limit)),
        ("fec", lambda: fec.fetch(company, key=args.fec_key,
                                  per_page=args.limit)),
        ("sec", lambda: sec.fetch(company)),
        ("epa", lambda: epa.fetch(company, limit=args.limit)),
    ]
    for key, step in steps:
        try:
            data[key] = step()
        except SourceUnavailable as e:
            errors.append((e.source, e.detail))
        except Exception as e:  # a single flaky source must not kill the run
            errors.append((key, f"unexpected error: {e}"))
    return data, errors


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="lens",
        description="Corporate Accountability Lens — cross-reference official "
                    "public government records for any company.")
    parser.add_argument("company", nargs="?",
                        help="company name to look up")
    parser.add_argument("--demo", action="store_true",
                        help="render a sample report from bundled data "
                             "(no network needed)")
    parser.add_argument("--html", metavar="PATH",
                        help="also write a self-contained HTML report")
    parser.add_argument("--json", metavar="PATH",
                        help="also write raw normalized data as JSON")
    parser.add_argument("--years", type=int, default=5,
                        help="how many years of contracts to search (default 5)")
    parser.add_argument("--limit", type=int, default=50,
                        help="max records per source (default 50)")
    parser.add_argument("--fec-key",
                        help="FEC API key (default: FEC_API_KEY env var, "
                             "then DEMO_KEY). Free at api.data.gov/signup")
    parser.add_argument("--contact",
                        help="contact email sent in the User-Agent to SEC "
                             "EDGAR per their fair-access policy "
                             "(default: LENS_CONTACT env var)")
    args = parser.parse_args(argv)

    if not args.demo and not args.company:
        parser.error("give a company name, or --demo for a sample report")
    if args.contact:
        os.environ["LENS_CONTACT"] = args.contact

    company = DEMO_COMPANY if args.demo else args.company
    generated_on = datetime.date.today().isoformat()

    if args.demo:
        data, errors = gather_demo()
    else:
        print(f"Searching public records for “{company}”…", file=sys.stderr)
        data, errors = gather_live(company, args)

    print(terminal_report(company, data, errors, generated_on))

    if args.html:
        with open(args.html, "w", encoding="utf-8") as fh:
            fh.write(html_report(company, data, errors, generated_on))
        print(f"\nHTML report written to {args.html}", file=sys.stderr)
    if args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            fh.write(json_report(company, data, errors, generated_on))
        print(f"JSON data written to {args.json}", file=sys.stderr)

    if not data:
        return 1
    return 0
