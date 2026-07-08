"""Lobbying filings — U.S. Senate Lobbying Disclosure Act database.

API docs: https://lda.senate.gov/api/
No API key required (anonymous requests are rate-limited; be gentle).
"""

from ..http import fetch_json, qs

SOURCE = "Senate LDA (lobbying disclosures)"
BASE_URL = "https://lda.senate.gov/api/v1/filings/"
WEB_URL = "https://lda.senate.gov/filings/public/filing/search/"


def fetch(company, *, year=None, page_size=25):
    url = BASE_URL + "?" + qs({
        "client_name": company,
        "filing_year": year,
        "page_size": page_size,
        "ordering": "-dt_posted",
    })
    payload = fetch_json(SOURCE, url)
    return parse(payload)


def _money(value):
    try:
        return float(value) if value is not None else 0.0
    except (TypeError, ValueError):
        return 0.0


def parse(payload):
    """Normalize an LDA filings response."""
    filings = []
    for row in payload.get("results", []) or []:
        issues = []
        for act in row.get("lobbying_activities", []) or []:
            issue = act.get("general_issue_code_display") or act.get(
                "general_issue_code") or ""
            if issue and issue not in issues:
                issues.append(issue)
        filings.append({
            "year": row.get("filing_year"),
            "period": row.get("filing_period_display")
                      or row.get("filing_period") or "",
            "type": row.get("filing_type_display")
                    or row.get("filing_type") or "",
            "registrant": (row.get("registrant") or {}).get("name") or "",
            "client": (row.get("client") or {}).get("name") or "",
            "income": _money(row.get("income")),
            "expenses": _money(row.get("expenses")),
            "issues": issues,
        })
    total_reported = sum(max(f["income"], f["expenses"]) for f in filings)
    return {
        "source": SOURCE,
        "url": WEB_URL,
        "filings": filings,
        "total_reported": total_reported,
        "count": payload.get("count", len(filings)),
    }
