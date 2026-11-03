#!/usr/bin/env python3
"""Personal-build Qobuz sign-in helper.

Runs a local page that sends you to Qobuz's normal browser sign-in, receives the
callback on 127.0.0.1, exchanges it for a session token, validates the token, and
writes ios/Music/QobuzPersonalCredentials.json (git-ignored) for a personal device
build. The token is never printed. Mirrors QobuzStreamingClient's OAuth flow.
"""
import http.server
import json
import os
import re
import sys
import threading
import urllib.parse
import urllib.request
import uuid

PORT = 8766
PLAY_BASE = "https://play.qobuz.com"
API_BASE = "https://www.qobuz.com/api.json/0.2/"
OAUTH_PRIVATE_KEY = "6lz8C03UDIC7"  # Same public web-player constant the app uses.
USER_AGENT = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
              "(KHTML, like Gecko) Version/17.0 Safari/605.1.15")
OUTPUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ios", "Music",
                      "QobuzPersonalCredentials.json")


def fetch(url, headers=None, data=None, method=None):
    request = urllib.request.Request(url, data=data, method=method,
                                     headers={"User-Agent": USER_AGENT, **(headers or {})})
    with urllib.request.urlopen(request, timeout=20) as response:
        return response.read().decode("utf-8", "replace")


def discover_app_id():
    login_page = fetch(PLAY_BASE + "/login")
    bundle = re.search(r'<script src="(/resources/\d+\.\d+\.\d+-[a-z0-9]\d{3}/bundle\.js)"></script>', login_page)
    if not bundle:
        sys.exit("Could not find the Qobuz web-player bundle.")
    script = fetch(PLAY_BASE + bundle.group(1))
    app_id = re.search(r'production:\{api:\{appId:"(\d{9})",appSecret:"\w{32}"', script)
    if not app_id:
        sys.exit("Could not find the Qobuz app ID.")
    return app_id.group(1)


def exchange(code, app_id):
    query = urllib.parse.urlencode({"code": code, "private_key": OAUTH_PRIVATE_KEY})
    body = json.loads(fetch(API_BASE + "oauth/callback?" + query, headers={"X-App-Id": app_id}))
    token = body.get("token") or body.get("user_auth_token")
    user_id = int(body["user_id"])
    if not token or user_id <= 0:
        raise ValueError("Qobuz returned no session.")
    return token, user_id


def validate(token, user_id, app_id):
    headers = {"X-App-Id": app_id}
    if token.count(".") == 3:
        headers["Authorization"] = "Bearer " + token
    else:
        headers["X-User-Auth-Token"] = token
    account = json.loads(fetch(API_BASE + "user/login", headers=headers, data=b"", method="POST"))
    if str(account.get("user", {}).get("id")) != str(user_id):
        raise ValueError("Qobuz session belongs to a different account.")


def main():
    app_id = discover_app_id()
    redirect = f"http://127.0.0.1:{PORT}/callback"
    sign_in = "https://www.qobuz.com/signin/oauth?" + urllib.parse.urlencode(
        {"ext_app_id": app_id, "redirect_url": redirect})
    done = threading.Event()

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):  # Never log callback URLs (they carry the code).
            pass

        def reply(self, status, text):
            self.send_response(status)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(f"<html><body style='font:16px -apple-system'><p>{text}</p></body></html>".encode())

        def do_GET(self):
            parsed = urllib.parse.urlparse(self.path)
            if parsed.path == "/start":
                self.send_response(302)
                self.send_header("Location", sign_in)
                self.end_headers()
                return
            if parsed.path != "/callback":
                self.reply(404, "Not found.")
                return
            query = urllib.parse.parse_qs(parsed.query)
            code = (query.get("code_autorisation") or query.get("code") or [None])[0]
            if not code:
                self.reply(400, "Authorization code missing. Start again at /start.")
                return
            try:
                token, user_id = exchange(code, app_id)
                validate(token, user_id, app_id)
            except Exception as error:  # noqa: BLE001 - report without secrets
                print(f"Sign-in failed: {type(error).__name__}", flush=True)
                self.reply(500, "Qobuz sign-in failed. Start again at /start.")
                return
            payload = {"importID": str(uuid.uuid4()),
                       "credentials": {"userAuthToken": token, "userID": user_id}}
            fd = os.open(OUTPUT, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w") as handle:
                json.dump(payload, handle)
            print(f"Saved validated Qobuz session for user {user_id}.", flush=True)
            self.reply(200, "Qobuz sign-in complete. You can close this tab.")
            done.set()

    server = http.server.HTTPServer(("127.0.0.1", PORT), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    print(f"Open http://127.0.0.1:{PORT}/start to sign in.", flush=True)
    done.wait()
    server.shutdown()


if __name__ == "__main__":
    main()
