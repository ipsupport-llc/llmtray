# The App Store build's python-packages/sitecustomize.py (adr/0018 §3):
# Python imports it at startup, so every runner LLMTray starts -- the model
# server, image, music, embed and voice runners, a model download -- exits
# when its parent goes away. In the sandbox the app can see a runner an
# earlier LLMTray left behind but may not signal it (the standalone build's
# OrphanScan stops those instead), so none is left behind: a crashed or
# force-quit LLMTray takes its runners with it within half a second.
# Only for processes started with LLMTRAY_EXIT_WITH_PARENT=1
# (BundledRuntime sets it for the app, so its children inherit it).
import os

if os.environ.get("LLMTRAY_EXIT_WITH_PARENT") == "1":
    import threading
    import time

    def _watch(parent=os.getppid()):
        # Also a parent already gone at startup (launchd, pid 1, adopted
        # us): LLMTray's runners are never launchd's own children.
        while True:
            ppid = os.getppid()
            if ppid != parent or ppid == 1:
                os._exit(0)
            time.sleep(0.5)

    threading.Thread(target=_watch, name="llmtray-exit-with-parent", daemon=True).start()
