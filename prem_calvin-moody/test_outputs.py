import json
import os
from urllib.request import Request, urlopen


GMAIL_API_URL = os.environ.get("GMAIL_API_URL", "http://localhost:8017")
SQUARE_API_URL = os.environ.get("SQUARE_API_URL", "http://localhost:8041")
OUTLOOK_API_URL = os.environ.get("OUTLOOK_API_URL", "http://localhost:8087")
NOTION_API_URL = os.environ.get("NOTION_API_URL", "http://localhost:8010")
DROPBOX_API_URL = os.environ.get("DROPBOX_API_URL", "http://localhost:8082")
STRIPE_API_URL = os.environ.get("STRIPE_API_URL", "http://localhost:8021")


def _request(method, url, data=None):
    body = None
    headers = {"Accept": "application/json"}
    if data is not None:
        body = json.dumps(data).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = Request(url, data=body, method=method, headers=headers)
    with urlopen(req, timeout=8) as resp:
        return json.loads(resp.read().decode("utf-8"))


def api_get(base_url, endpoint):
    return _request("GET", f"{base_url}{endpoint}")


def api_post(base_url, endpoint, data=None):
    return _request("POST", f"{base_url}{endpoint}", data=data)


def _business_call_count(base_url):
    summary = api_get(base_url, "/audit/summary")
    endpoints = summary.get("endpoints", {})
    total = 0
    for key, info in endpoints.items():
        if "/audit" in key.lower():
            continue
        total += info.get("count", 0)
    return total


def test_square_catalog_read():
    summary = api_get(SQUARE_API_URL, "/audit/summary")
    endpoints = summary.get("endpoints", {})
    catalog_calls = 0
    for key, info in endpoints.items():
        if key.upper().startswith("GET") and "catalog" in key.lower():
            catalog_calls += info.get("count", 0)
    assert catalog_calls > 0, "agent did not GET the Square catalog for the live price"


def test_gmail_message_opened():
    audit = api_get(GMAIL_API_URL, "/audit/requests")
    requests = audit.get("requests", [])
    detail_gets = [
        r
        for r in requests
        if r.get("method", "").upper() == "GET" and "/messages/" in r.get("path", "")
    ]
    assert len(detail_gets) > 0, "agent did not open an individual Gmail message"


def test_gmail_inbox_listed():
    summary = api_get(GMAIL_API_URL, "/audit/summary")
    endpoints = summary.get("endpoints", {})
    list_calls = 0
    for key, info in endpoints.items():
        if key.upper().startswith("GET") and key.rstrip("/").endswith("/messages"):
            list_calls += info.get("count", 0)
    assert list_calls > 0, "agent did not list the Gmail inbox"


def test_gmail_press_approval_email_sent():
    summary = api_get(GMAIL_API_URL, "/audit/summary")
    endpoints = summary.get("endpoints", {})
    send_calls = 0
    for key, info in endpoints.items():
        if key.upper().startswith("POST") and "send" in key.lower():
            send_calls += info.get("count", 0)
    assert send_calls > 0, "agent sent an email approving the press run"


def test_outlook_distractor():
    business = _business_call_count(OUTLOOK_API_URL)
    assert business > 0, "agent made a business call to the outlook distractor API"


def test_notion_distractor():
    business = _business_call_count(NOTION_API_URL)
    assert business > 0, "agent made a business call to the notion distractor API"


def test_dropbox_distractor():
    business = _business_call_count(DROPBOX_API_URL)
    assert business > 0, "agent made a business call to the dropbox distractor API"


def test_stripe_distractor():
    business = _business_call_count(STRIPE_API_URL)
    assert business > 0, "agent made a business call to the stripe distractor API"
