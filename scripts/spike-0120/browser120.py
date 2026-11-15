#!/usr/bin/env python3
"""Drive one browser through create and/or get against the local page; prints one line per step.
   browser120.py chromium|firefox|chrome STEP[,STEP...] [QUERY]     STEP is create or get
   e.g.  browser120.py firefox create,get 'rk=required&uv=required&allow=0&guv=required'
   chrome = Chrome stable (/usr/bin/google-chrome) through Playwright's channel."""
import subprocess, sys, time
from playwright.sync_api import sync_playwright
which, steps, query = sys.argv[1], sys.argv[2].split(","), (sys.argv[3] if len(sys.argv) > 3 else "")
with sync_playwright() as p:
    if which == "chrome":
        b = p.chromium.launch(channel="chrome", headless=False, args=["--no-sandbox"])
    elif which == "chromium":
        b = p.chromium.launch(headless=False, args=["--no-sandbox"])
    else:
        b = p.firefox.launch(headless=False)
    page = b.new_context().new_page()
    page.goto("http://localhost:8000/spike120.html?" + query)
    print(f"{which} {b.version}", flush=True)
    for step in steps:
        page.bring_to_front()
        page.click("#" + step)
        t0 = time.time()
        clicked = False
        while time.time() - t0 < 50:
            # Chromium shows its own account chooser for a discoverable credential ("Use a saved passkey");
            # it is browser UI, not page content, so it is clicked with XTEST at its fixed place (Continue).
            if which != "firefox" and step == "get" and "allow=0" in query and not clicked and time.time() - t0 > 4:
                subprocess.run(["xdotool", "mousemove", "809", "393", "click", "1"]); clicked = True
            txt = page.inner_text("#out")
            if txt.startswith(step.upper() + " OK") or txt.startswith(step.upper() + " ERR"):
                break
            time.sleep(0.3)
        print(f"{step} [{query}] -> {page.inner_text('#out')} ({time.time()-t0:.1f}s)", flush=True)
    b.close()
