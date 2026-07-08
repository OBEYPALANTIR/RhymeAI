"""Political contributions — Federal Election Commission.

API docs: https://api.open.fec.gov/developers/
Requires an API key; the public "DEMO_KEY" works with tight rate limits.
Get a free personal key at https://api.data.gov/signup/ and pass it with
--fec-key or the FEC_API_KEY environment variable.

Two views:
  * committees whose name matches the company (corporate PACs)
  * itemized individual contributions where the donor listed the company
    as their employer (schedule A)
"""

import os

from ..http import fetch_json, qs

SOURCE = "FEC (political contributions)"
BASE = "https://api.open.fec.gov/v1"
WEB_URL = "https://www.fec.gov/data/"


def api_key():
    return os.environ.get("FEC_API_KEY", "DEMO_KEY")


def fetch(company, *, key=None, per_page=50):
    key = key or api_key()
    pac_url = f"{BASE}/names/committees/?" + qs({"q": company, "api_key": key})
    pac_payload = fetch_json(SOURCE, pac_url)

    sched_a_url = f"{BASE}/schedules/schedule_a/?" + qs({
        "contributor_employer": company,
        "sort": "-contribution_receipt_amount",
        "per_page": per_page,
        "api_key": key,
    })
    contrib_payload = fetch_json(SOURCE, sched_a_url)
    return parse(pac_payload, contrib_payload)


def parse(pac_payload, contrib_payload):
    """Normalize committee-name matches and schedule A contributions."""
    pacs = []
    for row in pac_payload.get("results", []) or []:
        name = row.get("name") or ""
        cid = row.get("id") or ""
        if name:
            pacs.append({"id": cid, "name": name})

    contributions = []
    by_committee = {}
    for row in contrib_payload.get("results", []) or []:
        committee = (row.get("committee") or {})
        committee_name = committee.get("name") or "(unknown committee)"
        try:
            amount = float(row.get("contribution_receipt_amount") or 0.0)
        except (TypeError, ValueError):
            amount = 0.0
        contributions.append({
            "contributor": row.get("contributor_name") or "",
            "employer": row.get("contributor_employer") or "",
            "amount": amount,
            "date": (row.get("contribution_receipt_date") or "")[:10],
            "committee": committee_name,
            "party": committee.get("party_full") or "",
        })
        by_committee[committee_name] = by_committee.get(committee_name, 0.0) + amount

    top_recipients = sorted(by_committee.items(), key=lambda kv: -kv[1])
    return {
        "source": SOURCE,
        "url": WEB_URL,
        "pacs": pacs,
        "contributions": contributions,
        "top_recipients": [
            {"committee": name, "amount": amt} for name, amt in top_recipients
        ],
        "total_amount": sum(c["amount"] for c in contributions),
    }
