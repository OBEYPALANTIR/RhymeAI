"""Corporate filings — SEC EDGAR.

Docs: https://www.sec.gov/search-filings/edgar-application-programming-interfaces
No API key, but the SEC requires a descriptive User-Agent identifying the
requester (their fair-access policy). Pass a contact email via --contact or
the LENS_CONTACT environment variable.

Flow: resolve the company name to a CIK via the public ticker file, then pull
the submissions feed for recent filings (10-K annual reports, 8-K material
events, DEF 14A proxy statements with executive pay, etc.).
"""

import os

from ..http import fetch_json

SOURCE = "SEC EDGAR (corporate filings)"
TICKERS_URL = "https://www.sec.gov/files/company_tickers.json"
SUBMISSIONS_URL = "https://data.sec.gov/submissions/CIK{cik:010d}.json"
WEB_URL = "https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany"

INTERESTING_FORMS = {
    "10-K": "Annual report",
    "10-Q": "Quarterly report",
    "8-K": "Material event",
    "DEF 14A": "Proxy statement (includes executive compensation)",
    "4": "Insider trade",
    "S-1": "IPO registration",
    "SC 13D": "Activist stake disclosure",
}


def _headers():
    contact = os.environ.get("LENS_CONTACT", "accountability-lens user")
    return {"User-Agent": f"accountability-lens/0.1 ({contact})"}


def fetch(company, *, max_filings=25):
    tickers = fetch_json(SOURCE, TICKERS_URL, headers=_headers())
    cik, matched_name, ticker = match_company(tickers, company)
    if cik is None:
        return parse(None, None, None, max_filings=max_filings)
    submissions = fetch_json(
        SOURCE, SUBMISSIONS_URL.format(cik=cik), headers=_headers())
    return parse(submissions, matched_name, ticker, max_filings=max_filings)


def match_company(tickers_payload, company):
    """Find the best CIK match for a company name in the SEC ticker file.

    The file is {"0": {"cik_str": ..., "ticker": ..., "title": ...}, ...}.
    Prefer the shortest title containing the query (usually the parent
    entity rather than a trust or spin-off).
    """
    needle = company.strip().lower()
    if not needle:
        return None, None, None
    candidates = []
    for row in (tickers_payload or {}).values():
        title = (row.get("title") or "").strip()
        if needle in title.lower():
            candidates.append((len(title), row))
    if not candidates:
        return None, None, None
    _, best = min(candidates, key=lambda c: c[0])
    return int(best["cik_str"]), best.get("title"), best.get("ticker")


def parse(submissions, matched_name, ticker, *, max_filings=25):
    """Normalize an EDGAR submissions feed into recent-filing records."""
    if not submissions:
        return {
            "source": SOURCE, "url": WEB_URL, "matched": None,
            "ticker": None, "filings": [], "count": 0,
        }
    recent = (submissions.get("filings") or {}).get("recent") or {}
    forms = recent.get("form") or []
    dates = recent.get("filingDate") or []
    accessions = recent.get("accessionNumber") or []
    docs = recent.get("primaryDocument") or []
    cik = submissions.get("cik")

    filings = []
    for i, form in enumerate(forms):
        if len(filings) >= max_filings:
            break
        date = dates[i] if i < len(dates) else ""
        accession = (accessions[i] if i < len(accessions) else "").replace("-", "")
        doc = docs[i] if i < len(docs) else ""
        link = ""
        if cik and accession and doc:
            link = (f"https://www.sec.gov/Archives/edgar/data/"
                    f"{int(cik)}/{accession}/{doc}")
        filings.append({
            "form": form,
            "meaning": INTERESTING_FORMS.get(form, ""),
            "date": date,
            "link": link,
        })
    return {
        "source": SOURCE,
        "url": WEB_URL,
        "matched": matched_name or submissions.get("name"),
        "ticker": ticker,
        "filings": filings,
        "count": len(forms),
    }
