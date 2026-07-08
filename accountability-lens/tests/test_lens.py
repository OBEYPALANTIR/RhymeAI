"""Offline tests: every parser and both report renderers, against fixtures.

Run from accountability-lens/:  python3 -m unittest discover tests -v
"""

import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from lens.report import terminal_report, html_report, json_report, money
from lens.sources import usaspending, lobbying, fec, sec, epa

FIXTURES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")


def load(name):
    with open(os.path.join(FIXTURES, name), encoding="utf-8") as fh:
        return json.load(fh)


class TestUSASpending(unittest.TestCase):
    def test_parse(self):
        out = usaspending.parse(load("usaspending.json"))
        self.assertEqual(out["count"], 4)
        self.assertAlmostEqual(out["total_amount"], 588_750_000.0)
        top = out["awards"][0]
        self.assertEqual(top["agency"], "Department of Defense")
        self.assertEqual(top["amount"], 480_000_000.0)

    def test_null_amount_is_zero(self):
        out = usaspending.parse(load("usaspending.json"))
        nih = [a for a in out["awards"] if "NIH" in a["sub_agency"] or
               a["sub_agency"].startswith("National Institutes")][0]
        self.assertEqual(nih["amount"], 0.0)

    def test_empty_payload(self):
        out = usaspending.parse({})
        self.assertEqual(out["count"], 0)
        self.assertEqual(out["total_amount"], 0.0)


class TestLobbying(unittest.TestCase):
    def test_parse(self):
        out = lobbying.parse(load("lda.json"))
        self.assertEqual(out["count"], 34)  # API-reported total
        self.assertEqual(len(out["filings"]), 2)
        # income-only and expenses-only filings both counted
        self.assertAlmostEqual(out["total_reported"], 890_000 + 1_200_000)
        self.assertIn("Budget/Appropriations", out["filings"][0]["issues"])

    def test_empty_payload(self):
        out = lobbying.parse({})
        self.assertEqual(out["filings"], [])


class TestFEC(unittest.TestCase):
    def test_parse(self):
        out = fec.parse(load("fec_committees.json"), load("fec_schedule_a.json"))
        self.assertEqual(len(out["pacs"]), 1)
        self.assertAlmostEqual(out["total_amount"], 14_900.0)
        # two Jane Doe contributions to the same committee aggregate
        self.assertEqual(out["top_recipients"][0]["committee"],
                         "SENATE LEADERSHIP FUND")
        self.assertAlmostEqual(out["top_recipients"][0]["amount"], 9_900.0)

    def test_empty_payloads(self):
        out = fec.parse({}, {})
        self.assertEqual(out["total_amount"], 0.0)
        self.assertEqual(out["top_recipients"], [])


class TestSEC(unittest.TestCase):
    def test_match_company_prefers_shortest_title(self):
        tickers = {
            "0": {"cik_str": 111, "ticker": "XMPL", "title": "Example Corp"},
            "1": {"cik_str": 222, "ticker": "XMPLW",
                  "title": "Example Corp Warrant Trust II"},
        }
        cik, name, ticker = sec.match_company(tickers, "example corp")
        self.assertEqual(cik, 111)
        self.assertEqual(ticker, "XMPL")

    def test_match_company_no_hit(self):
        self.assertEqual(sec.match_company({}, "nothing"), (None, None, None))

    def test_parse(self):
        out = sec.parse(load("sec_submissions.json"), "EXAMPLE CORP", "XMPL")
        self.assertEqual(out["matched"], "EXAMPLE CORP")
        self.assertEqual(out["count"], 5)
        annual = out["filings"][0]
        self.assertEqual(annual["form"], "10-K")
        self.assertIn("Annual report", annual["meaning"])
        self.assertIn("/1234567/", annual["link"])
        self.assertNotIn("-", annual["link"].split("/")[-2])  # accession de-dashed

    def test_parse_no_match(self):
        out = sec.parse(None, None, None)
        self.assertIsNone(out["matched"])
        self.assertEqual(out["filings"], [])


class TestEPA(unittest.TestCase):
    def test_parse(self):
        out = epa.parse(load("echo.json"))
        self.assertEqual(out["count"], 3)
        self.assertEqual(out["facilities_in_violation"], 1)
        self.assertAlmostEqual(out["total_penalties"], 246_500.0)
        gary = out["facilities"][0]
        self.assertTrue(gary["in_violation"])
        self.assertEqual(gary["formal_actions"], 2)

    def test_empty_payload(self):
        out = epa.parse({})
        self.assertEqual(out["facilities"], [])
        self.assertEqual(out["count"], 0)


class TestReports(unittest.TestCase):
    def setUp(self):
        self.data = {
            "contracts": usaspending.parse(load("usaspending.json")),
            "lobbying": lobbying.parse(load("lda.json")),
            "fec": fec.parse(load("fec_committees.json"),
                             load("fec_schedule_a.json")),
            "sec": sec.parse(load("sec_submissions.json"),
                             "EXAMPLE CORP", "XMPL"),
            "epa": epa.parse(load("echo.json")),
        }

    def test_money_formatting(self):
        self.assertEqual(money(480_000_000), "$480.0M")
        self.assertEqual(money(1_500_000_000), "$1.5B")
        self.assertEqual(money(62_000), "$62K")
        self.assertEqual(money(950), "$950")
        self.assertEqual(money(None), "—")

    def test_terminal_report(self):
        text = terminal_report("Example Corp", self.data, [], "2026-07-08")
        self.assertIn("FEDERAL CONTRACTS", text)
        self.assertIn("Department of Defense", text)
        self.assertIn("SENATE LEADERSHIP FUND", text)
        self.assertIn("IN VIOLATION", text)

    def test_terminal_report_shows_source_errors(self):
        text = terminal_report("Example Corp", {}, [("FEC", "rate limited")],
                               "2026-07-08")
        self.assertIn("SOURCES UNAVAILABLE", text)
        self.assertIn("rate limited", text)

    def test_html_report(self):
        page = html_report("Example Corp", self.data, [], "2026-07-08")
        self.assertIn("<title>Accountability Lens — Example Corp</title>", page)
        self.assertIn("Department of Defense", page)
        self.assertIn("in violation", page)
        self.assertIn("usaspending.gov", page.lower())
        # untrusted strings must be escaped
        evil = dict(self.data)
        evil["contracts"] = usaspending.parse({"results": [{
            "Award ID": "X", "Recipient Name": "<script>alert(1)</script>",
            "Award Amount": 1.0,
            "Awarding Agency": "<img src=x onerror=alert(1)>",
            "Description": "", "Start Date": "", "End Date": "",
        }]})
        page = html_report("<b>Co</b>", evil, [], "2026-07-08")
        self.assertNotIn("<script>alert", page)
        self.assertNotIn("<img src=x", page)
        self.assertNotIn("<b>Co</b>", page)

    def test_json_report_roundtrip(self):
        raw = json_report("Example Corp", self.data, [("EPA", "down")],
                          "2026-07-08")
        parsed = json.loads(raw)
        self.assertEqual(parsed["company"], "Example Corp")
        self.assertEqual(parsed["errors"][0]["source"], "EPA")
        self.assertAlmostEqual(
            parsed["data"]["contracts"]["total_amount"], 588_750_000.0)


if __name__ == "__main__":
    unittest.main()
