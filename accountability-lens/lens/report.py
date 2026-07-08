"""Render a lens result as a terminal summary and a self-contained HTML page.

The HTML embeds all styling inline — no external scripts, fonts, or trackers.
Every section links to the official government database it came from so a
reader can verify each claim against the primary source.
"""

import html
import json


def money(amount):
    if amount is None:
        return "—"
    if amount >= 1_000_000_000:
        return f"${amount / 1_000_000_000:,.1f}B"
    if amount >= 1_000_000:
        return f"${amount / 1_000_000:,.1f}M"
    if amount >= 1_000:
        return f"${amount / 1_000:,.0f}K"
    return f"${amount:,.0f}"


def _esc(text):
    return html.escape(str(text if text is not None else ""))


def terminal_report(company, data, errors, generated_on):
    """Plain-text summary printed to stdout."""
    lines = []
    bar = "=" * 64
    lines.append(bar)
    lines.append(f"CORPORATE ACCOUNTABILITY LENS — {company}")
    lines.append(f"Public records as of {generated_on}")
    lines.append(bar)

    contracts = data.get("contracts")
    if contracts:
        lines.append("")
        lines.append(f"FEDERAL CONTRACTS ({contracts['source']})")
        lines.append(f"  {contracts['count']} awards shown, "
                     f"totaling {money(contracts['total_amount'])}")
        for a in contracts["awards"][:10]:
            desc = (a["description"][:60] + "…") if len(a["description"]) > 60 else a["description"]
            lines.append(f"  {money(a['amount']):>10}  {a['agency']}  {desc}")

    lobbying = data.get("lobbying")
    if lobbying:
        lines.append("")
        lines.append(f"LOBBYING ({lobbying['source']})")
        lines.append(f"  {lobbying['count']} filings on record; recent filings "
                     f"report {money(lobbying['total_reported'])}")
        for f in lobbying["filings"][:8]:
            issues = ", ".join(f["issues"][:4]) or "(issues not listed)"
            lines.append(f"  {f['year']} {f['period']:<12} "
                         f"{money(max(f['income'], f['expenses'])):>10}  via "
                         f"{f['registrant']} — {issues}")

    fec = data.get("fec")
    if fec:
        lines.append("")
        lines.append(f"POLITICAL MONEY ({fec['source']})")
        if fec["pacs"]:
            lines.append("  Committees matching the company name:")
            for p in fec["pacs"][:5]:
                lines.append(f"    {p['name']} ({p['id']})")
        if fec["top_recipients"]:
            lines.append(f"  Top recipients of employee/PAC dollars "
                         f"({money(fec['total_amount'])} in itemized "
                         f"contributions shown):")
            for r in fec["top_recipients"][:8]:
                lines.append(f"    {money(r['amount']):>10}  {r['committee']}")

    sec = data.get("sec")
    if sec:
        lines.append("")
        lines.append(f"SEC FILINGS ({sec['source']})")
        if sec["matched"]:
            ticker = f" [{sec['ticker']}]" if sec.get("ticker") else ""
            lines.append(f"  Matched: {sec['matched']}{ticker} — "
                         f"{sec['count']} filings on record")
            for f in sec["filings"][:8]:
                meaning = f" — {f['meaning']}" if f["meaning"] else ""
                lines.append(f"    {f['date']}  {f['form']:<8}{meaning}")
        else:
            lines.append("  No public-company match found (may be private).")

    epa = data.get("epa")
    if epa:
        lines.append("")
        lines.append(f"ENVIRONMENTAL ENFORCEMENT ({epa['source']})")
        lines.append(f"  {epa['count']} facilities; "
                     f"{epa['facilities_in_violation']} currently in violation; "
                     f"{money(epa['total_penalties'])} in penalties")
        flagged = [f for f in epa["facilities"]
                   if f["in_violation"] or f["penalties"] or f["formal_actions"]]
        for f in flagged[:8]:
            status = "IN VIOLATION" if f["in_violation"] else "past actions"
            lines.append(f"    {f['name']} ({f['city']}, {f['state']}) — "
                         f"{status}, {f['formal_actions']} formal actions, "
                         f"{money(f['penalties'])} penalties")

    if errors:
        lines.append("")
        lines.append("SOURCES UNAVAILABLE THIS RUN:")
        for source, detail in errors:
            lines.append(f"  {source}: {detail}")

    lines.append("")
    lines.append("Every line above comes from an official U.S. government")
    lines.append("database and can be independently verified at the source.")
    lines.append(bar)
    return "\n".join(lines)


_CSS = """
:root { color-scheme: light dark; --fg: #1a1a1a; --bg: #fdfdfb; --muted: #6b6b6b;
        --line: #e2e2dc; --accent: #8a3324; --card: #f6f6f2; }
@media (prefers-color-scheme: dark) {
  :root { --fg: #e8e8e4; --bg: #17181a; --muted: #9a9a94; --line: #33342f;
          --accent: #e0876f; --card: #1f2023; }
}
* { box-sizing: border-box; }
body { margin: 0 auto; max-width: 60rem; padding: 2rem 1.25rem 4rem;
       font: 16px/1.55 Georgia, 'Times New Roman', serif;
       color: var(--fg); background: var(--bg); }
h1 { font-size: 1.7rem; margin: 0 0 .25rem; }
h2 { font-size: 1.15rem; border-bottom: 1px solid var(--line);
     padding-bottom: .35rem; margin-top: 2.25rem; }
.sub { color: var(--muted); margin: 0 0 1.5rem; font-size: .95rem; }
.stat-row { display: flex; flex-wrap: wrap; gap: .75rem; margin: 1.25rem 0; }
.stat { background: var(--card); border: 1px solid var(--line);
        border-radius: 8px; padding: .7rem 1rem; min-width: 10rem; flex: 1; }
.stat b { display: block; font-size: 1.35rem; }
.stat span { color: var(--muted); font-size: .82rem; }
.tablewrap { overflow-x: auto; }
table { border-collapse: collapse; width: 100%; font-size: .9rem; }
th, td { text-align: left; padding: .4rem .6rem;
         border-bottom: 1px solid var(--line); vertical-align: top; }
th { color: var(--muted); font-weight: normal; font-variant: small-caps; }
td.num { text-align: right; white-space: nowrap; font-variant-numeric: tabular-nums; }
.viol { color: var(--accent); font-weight: bold; }
.src { font-size: .8rem; color: var(--muted); }
.src a { color: inherit; }
.notice { background: var(--card); border-left: 3px solid var(--accent);
          padding: .6rem .9rem; font-size: .88rem; margin: 1rem 0; }
footer { margin-top: 3rem; padding-top: 1rem; border-top: 1px solid var(--line);
         color: var(--muted); font-size: .85rem; }
"""


def _section(title, source_name, source_url, body_html):
    return (f"<h2>{_esc(title)}</h2>"
            f"<p class='src'>Source: <a href='{_esc(source_url)}'>"
            f"{_esc(source_name)}</a></p>{body_html}")


def _table(headers, rows):
    head = "".join(f"<th>{_esc(h)}</th>" for h in headers)
    body = "".join("<tr>" + "".join(cells) + "</tr>" for cells in rows)
    return (f"<div class='tablewrap'><table><thead><tr>{head}</tr></thead>"
            f"<tbody>{body}</tbody></table></div>")


def html_report(company, data, errors, generated_on):
    """Self-contained HTML report."""
    parts = [f"<style>{_CSS}</style>",
             f"<title>Accountability Lens — {_esc(company)}</title>",
             f"<h1>Corporate Accountability Lens: {_esc(company)}</h1>",
             f"<p class='sub'>Compiled from official U.S. government public "
             f"records · generated {_esc(generated_on)}</p>"]

    contracts = data.get("contracts")
    lobbying = data.get("lobbying")
    fec = data.get("fec")
    epa = data.get("epa")

    stats = []
    if contracts:
        stats.append((money(contracts["total_amount"]),
                      f"federal contract dollars ({contracts['count']} awards shown)"))
    if lobbying:
        stats.append((money(lobbying["total_reported"]),
                      f"lobbying spend in recent filings ({lobbying['count']} filings on record)"))
    if fec:
        stats.append((money(fec["total_amount"]),
                      "itemized political contributions shown"))
    if epa:
        stats.append((money(epa["total_penalties"]),
                      f"environmental penalties ({epa['facilities_in_violation']} facilities in violation)"))
    if stats:
        cells = "".join(f"<div class='stat'><b>{_esc(v)}</b>"
                        f"<span>{_esc(label)}</span></div>" for v, label in stats)
        parts.append(f"<div class='stat-row'>{cells}</div>")

    if contracts:
        rows = [[f"<td class='num'>{_esc(money(a['amount']))}</td>",
                 f"<td>{_esc(a['agency'])}</td>",
                 f"<td>{_esc(a['description'][:160])}</td>",
                 f"<td>{_esc(a['start_date'])}</td>"]
                for a in contracts["awards"][:25]]
        parts.append(_section(
            "Federal contracts", contracts["source"], contracts["url"],
            _table(["Amount", "Agency", "What for", "Start"], rows)))

    if lobbying:
        rows = [[f"<td>{_esc(f['year'])} {_esc(f['period'])}</td>",
                 f"<td class='num'>{_esc(money(max(f['income'], f['expenses'])))}</td>",
                 f"<td>{_esc(f['registrant'])}</td>",
                 f"<td>{_esc(', '.join(f['issues'][:6]))}</td>"]
                for f in lobbying["filings"][:25]]
        parts.append(_section(
            "Lobbying disclosures", lobbying["source"], lobbying["url"],
            _table(["Period", "Reported", "Lobbying firm", "Issues lobbied"], rows)))

    if fec:
        inner = ""
        if fec["pacs"]:
            items = "".join(f"<li>{_esc(p['name'])} "
                            f"<span class='src'>({_esc(p['id'])})</span></li>"
                            for p in fec["pacs"][:8])
            inner += f"<p>Committees matching the company name:</p><ul>{items}</ul>"
        if fec["top_recipients"]:
            rows = [[f"<td class='num'>{_esc(money(r['amount']))}</td>",
                     f"<td>{_esc(r['committee'])}</td>"]
                    for r in fec["top_recipients"][:15]]
            inner += _table(["Amount", "Recipient committee"], rows)
        parts.append(_section(
            "Political money", fec["source"], fec["url"],
            inner or "<p>No itemized records matched.</p>"))

    sec = data.get("sec")
    if sec and sec.get("matched"):
        ticker = f" [{sec['ticker']}]" if sec.get("ticker") else ""
        rows = []
        for f in sec["filings"][:20]:
            form = _esc(f["form"])
            if f["link"]:
                form = f"<a href='{_esc(f['link'])}'>{form}</a>"
            rows.append([f"<td>{_esc(f['date'])}</td>",
                         f"<td>{form}</td>",
                         f"<td>{_esc(f['meaning'])}</td>"])
        parts.append(_section(
            f"SEC filings — {sec['matched']}{ticker}", sec["source"], sec["url"],
            _table(["Filed", "Form", "What it is"], rows)))

    if epa:
        flagged = [f for f in epa["facilities"]
                   if f["in_violation"] or f["penalties"] or f["formal_actions"]]
        rows = []
        for f in flagged[:25]:
            status = ("<span class='viol'>in violation</span>"
                      if f["in_violation"] else "past actions")
            rows.append([f"<td>{_esc(f['name'])}</td>",
                         f"<td>{_esc(f['city'])}, {_esc(f['state'])}</td>",
                         f"<td>{status}</td>",
                         f"<td class='num'>{f['formal_actions']}</td>",
                         f"<td class='num'>{_esc(money(f['penalties']))}</td>"])
        body = (_table(["Facility", "Location", "Status", "Formal actions",
                        "Penalties"], rows)
                if rows else "<p>No facilities with violations or penalties "
                             "in the records returned.</p>")
        parts.append(_section(
            "Environmental enforcement", epa["source"], epa["url"], body))

    if errors:
        items = "".join(f"<li><b>{_esc(s)}</b>: {_esc(d)}</li>"
                        for s, d in errors)
        parts.append(f"<div class='notice'>Sources unavailable this run:"
                     f"<ul>{items}</ul>Re-run later or check the source "
                     f"website directly.</div>")

    parts.append(
        "<footer>Every figure on this page comes from an official U.S. "
        "government database — USAspending.gov, the Senate Lobbying "
        "Disclosure database, the Federal Election Commission, SEC EDGAR, "
        "and EPA ECHO — and links back to the primary source so you can "
        "verify it yourself. Public record, made legible.</footer>")
    return "\n".join(parts)


def json_report(company, data, errors, generated_on):
    return json.dumps({
        "company": company,
        "generated_on": generated_on,
        "data": data,
        "errors": [{"source": s, "detail": d} for s, d in errors],
    }, indent=2)
