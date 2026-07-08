#!/usr/bin/env python3
"""Entry point: python3 lens.py "Company Name" [--html report.html]"""

import sys

from lens.cli import main

if __name__ == "__main__":
    sys.exit(main())
