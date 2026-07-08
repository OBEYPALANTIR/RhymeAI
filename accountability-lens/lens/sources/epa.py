"""Environmental enforcement — EPA ECHO.

Docs: https://echo.epa.gov/tools/web-services
No API key required. Searches facilities by name and surfaces compliance
status, formal enforcement actions, and penalties.
"""

from ..http import fetch_json, qs

SOURCE = "EPA ECHO (environmental enforcement)"
BASE_URL = "https://echodata.epa.gov/echo/echo_rest_services.get_facility_info"
WEB_URL = "https://echo.epa.gov/facilities/facility-search"


def fetch(company, *, limit=50):
    url = BASE_URL + "?" + qs({
        "output": "JSON",
        "p_fn": company,
        "responseset": limit,
    })
    payload = fetch_json(SOURCE, url)
    return parse(payload)


def _num(value):
    try:
        return float(value) if value not in (None, "") else 0.0
    except (TypeError, ValueError):
        return 0.0


def parse(payload):
    """Normalize an ECHO facility search response.

    ECHO nests everything under Results; facility field names vary a little
    across endpoints, so read each one defensively.
    """
    results = (payload or {}).get("Results") or {}
    rows = results.get("Facilities") or []
    facilities = []
    for row in rows:
        facilities.append({
            "name": row.get("FacName") or row.get("CWPName") or "",
            "city": row.get("FacCity") or "",
            "state": row.get("FacState") or "",
            "in_violation": str(row.get("CurrVioFlag") or "").upper() in ("Y", "YES", "1"),
            "quarters_noncompliant": int(_num(row.get("FacQtrsWithNC"))),
            "formal_actions": int(_num(row.get("FacFormalActionCount"))),
            "penalties": _num(row.get("FacTotalPenalties")),
            "inspections": int(_num(row.get("FacInspectionCount"))),
        })
    return {
        "source": SOURCE,
        "url": WEB_URL,
        "facilities": facilities,
        "count": int(_num(results.get("QueryRows"))) or len(facilities),
        "total_penalties": sum(f["penalties"] for f in facilities),
        "facilities_in_violation": sum(1 for f in facilities if f["in_violation"]),
    }
