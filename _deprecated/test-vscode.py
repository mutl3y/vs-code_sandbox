"""
Playwright smoke test — proves VS Code Server web UI is reachable and renders.
"""

import re, sys, os
from playwright.sync_api import sync_playwright, expect

TOKEN = os.environ.get("VSCODE_TOKEN", "")
URL = f"https://192.168.0.29:8550/?tkn={TOKEN}&folder=/workspace"


def test_vscode_loads():
    with sync_playwright() as p:
        browser = p.chromium.launch(
            ignore_default_args=["--headless"],
            args=["--headless=new", "--no-sandbox", "--ignore-certificate-errors"],
        )
        ctx = browser.new_context(ignore_https_errors=True)
        page = ctx.new_page()

        print(f"\n[1] Navigating to {URL[:80]}...")
        resp = page.goto(URL, timeout=30_000, wait_until="domcontentloaded")
        print(f"[2] HTTP status: {resp.status}")
        assert resp.status == 200, f"Expected 200, got {resp.status}"

        print("[3] Waiting for VS Code workbench element...")
        # The workbench shell div is the root mount point for VS Code
        page.wait_for_selector(".monaco-workbench", timeout=30_000)
        print("[4] .monaco-workbench found — workbench rendered!")

        title = page.title()
        print(f"[5] Page title: '{title}'")

        # Screenshot proof
        shot = "/tmp/vscode-proof.png"
        page.screenshot(path=shot, full_page=False)
        print(f"[6] Screenshot saved: {shot}")

        browser.close()
        print("\n✓ VS Code Server web UI is fully operational.\n")


if __name__ == "__main__":
    test_vscode_loads()
