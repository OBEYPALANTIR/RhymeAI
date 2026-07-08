"""Federal contracts and grants — USAspending.gov (Treasury).

API docs: https://api.usaspending.gov/docs/endpoints
No API key required.
"""

from ..http import fetch_json

SOURCE = "USAspending.gov (federal contracts)"
SEARCH_URL = "https://api.usaspending.gov/api/v2/search/spending_by_award/"
WEB_URL = "https://www.usaspending.gov/search"

# A/B/C/D = definitive contract award types.
CONTRACT_TYPE_CODES = ["A", "B", "C", "D"]


def fetch(company, *, years=5, limit=50, today=None):
    import datetime
    end = today or datetime.date.today()
    start = end.replace(year=end.year - years)
    body = {
        "filters": {
            "recipient_search_text": [company],
            "award_type_codes": CONTRACT_TYPE_CODES,
            "time_period": [
                {"start_date": start.isoformat(), "end_date": end.isoformat()}
            ],
        },
        "fields": [
            "Award ID", "Recipient Name", "Award Amount", "Awarding Agency",
            "Awarding Sub Agency", "Description", "Start Date", "End Date",
        ],
        "sort": "Award Amount",
        "order": "desc",
        "limit": limit,
        "page": 1,
    }
    payload = fetch_json(SOURCE, SEARCH_URL, method="POST", body=body)
    return parse(payload)


def parse(payload):
    """Normalize a spending_by_award response into award records."""
    awards = []
    for row in payload.get("results", []) or []:
        amount = row.get("Award Amount")
        try:
            amount = float(amount) if amount is not None else 0.0
        except (TypeError, ValueError):
            amount = 0.0
        awards.append({
            "award_id": row.get("Award ID") or "",
            "recipient": row.get("Recipient Name") or "",
            "amount": amount,
            "agency": row.get("Awarding Agency") or "",
            "sub_agency": row.get("Awarding Sub Agency") or "",
            "description": (row.get("Description") or "").strip(),
            "start_date": row.get("Start Date") or "",
            "end_date": row.get("End Date") or "",
        })
    total = sum(a["amount"] for a in awards)
    return {
        "source": SOURCE,
        "url": WEB_URL,
        "awards": awards,
        "total_amount": total,
        "count": len(awards),
    }
