# Corporate Accountability Lens

Give it a company name. It cross-references five official U.S. government
public-record databases and produces one readable picture: **who they paid,
what they got, and what they were caught doing.**

| What you see | Official source | Key needed |
|---|---|---|
| Federal contracts (who's buying, for what, how much) | [USAspending.gov](https://www.usaspending.gov) (Treasury) | No |
| Lobbying spend, firms hired, issues lobbied | [Senate Lobbying Disclosure database](https://lda.senate.gov) | No |
| Corporate PACs + itemized political contributions | [FEC](https://www.fec.gov/data/) | Free key (DEMO_KEY works, rate-limited) |
| Annual reports, material events, exec-pay proxies, insider trades | [SEC EDGAR](https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany) | No |
| Environmental violations, enforcement actions, penalties | [EPA ECHO](https://echo.epa.gov) | No |

All of this is public record. The problem was never secrecy — it's that the
record is scattered across five unrelated databases nobody has time to
cross-reference. This closes that gap.

## Design principles

- **Primary sources only.** Every figure comes from an official government
  API and every report section links back to it so readers can verify claims
  themselves. No scraping, no third-party aggregators, no editorializing —
  the record speaks for itself.
- **Zero dependencies.** Pure Python 3.9+ standard library. Nothing to
  install, no supply chain, nothing phoning home.
- **Fails honestly.** If a source is down or rate-limited, the report says
  exactly which source failed and why, instead of silently showing an
  incomplete picture as if it were complete.

## Usage

```sh
cd accountability-lens

# Live lookup (needs internet)
python3 lens.py "Palantir"
python3 lens.py "Lockheed Martin" --html report.html --json data.json

# Sample report from bundled fictional data — works fully offline
python3 lens.py --demo --html demo.html
```

Options:

- `--html PATH` — also write a self-contained HTML report (no external
  scripts or fonts; safe to share as a file)
- `--json PATH` — also write the normalized raw data
- `--years N` — contract search window (default 5)
- `--limit N` — max records per source (default 50)
- `--fec-key KEY` — FEC API key; defaults to the `FEC_API_KEY` env var, then
  the shared `DEMO_KEY`. Get a free personal key at
  <https://api.data.gov/signup/>
- `--contact EMAIL` — contact address sent in the User-Agent to SEC EDGAR,
  per their [fair-access policy](https://www.sec.gov/os/accessing-edgar-data)

## Tests

```sh
python3 -m unittest discover tests -v
```

Fully offline — every parser is exercised against recorded API fixtures,
including empty payloads, null amounts, and HTML-escaping of untrusted data.

## Honest limitations

- Name matching is string-based. Companies hide behind subsidiaries and
  shell names; searching "Alphabet" won't surface "Google LLC" awards.
  Search variant names and check the source links.
- Itemized FEC results show the records returned per page, not lifetime
  totals — treat amounts as "at least this much," never "in total."
- These are U.S. federal databases; state-level contracts, lobbying, and
  enforcement are not covered (yet).
- The bundled demo data (`tests/fixtures/`) is **fictional** ("Example
  Corp") and exists to show the report format and pin down parser behavior.
