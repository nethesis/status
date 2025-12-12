#!/usr/bin/env python3
import sys
try:
    import requests
    response = requests.get('http://localhost:5000/health', timeout=5)
    sys.exit(0 if response.status_code == 200 else 1)
except Exception:
    sys.exit(1)
