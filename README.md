# Codespace Desktop — real Ubuntu (GNOME) in a GitHub Codespace

The real Ubuntu desktop (GNOME + Ubuntu dock + Yaru theme + Firefox) in a browser tab, on Codespaces' free
tier. No KVM, no Windows — plain Linux. **Apache Guacamole on port 8080 is the main door** (best client — clipboard,
display-update resizing); noVNC on 6080 is the fallback. Both come through
Codespaces' own port forwarding (signed into your GitHub), so no tunnels
and nothing exposed to the internet.

## Why it's built this way — the 32 GB problem
Free Codespaces machines have a **32 GB disk**, and the default "universal"
image squats ~10 GB of it on preinstalled toolchains. This repo instead uses
the lean `base:ubuntu` image (~2 GB) and installs only the desktop stack
(GNOME + Guacamole build ~6.5 GB all-in), leaving ~25–26 GB actually usable — versus the
~10 GB a dockur/Windows codespace leaves you.

Free-tier quotas (GitHub Free, personal account): **120 core-hours/month**
(= 60 hours on the 2-core machine) and **15 GB-month of storage**. Storage is
metered on space you actually use, so: keep what you install + save under
~15 GB, delete codespaces you stop using (a stopped one still meters
storage), and set Settings → Codespaces → retention to a few days.
Treat the codespace as disposable — this repo IS the machine; anything
precious gets committed/pushed or saved to Drive.

## Use it
1. Put these files in a GitHub repo (`.devcontainer/` + this README).
2. Repo page → **Code → Codespaces → Create codespace on main**.
   First build runs `.devcontainer/setup.sh` automatically (~4–6 min).
3. In the codespace terminal: `~/start-desktop.sh`
   It prints your desktop URL and VNC password.
4. Open the URL (or Ports tab → 6080). Enter the VNC password. Fullscreen
   the tab (F11) — desktop is 1920×1080, your Fortis panel's native size.

## Session limits (Codespaces rules, not ours)
- Auto-stops after **30 min idle**; max continuous run ~12 h. After a
  stop/start, re-run `~/start-desktop.sh` — files in the workspace survive,
  the desktop process doesn't.
- When the monthly core-hours run out (no payment method on file), it just
  stops — no surprise bill.

## Change the resolution
Edit `W`/`H` at the top of `~/start-desktop.sh` inside the codespace
(1536×864 or 1366×768 if you run ChromeOS scaled), then re-run it.
