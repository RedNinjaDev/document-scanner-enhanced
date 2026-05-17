[![License](https://img.shields.io/badge/License-GPL%20v3-blue.svg)](./COPYING)

# Document Scanner Enhanced

A fork of [GNOME Document Scanner](https://gitlab.gnome.org/GNOME/simple-scan)
(simple-scan) that adds **automatic page straightening** and **automatic
cropping** for scanners that produce a black background around the document.

## What's different from upstream

Two new switches in **Preferences → Postprocessing**:

| Option              | Default | What it does                                                                                                                 |
| ------------------- | ------- | ---------------------------------------------------------------------------------------------------------------------------- |
| **Auto-crop**       | On      | Detects the document (a brighter region against the black scanner bed) and applies its bounding rectangle via Custom Crop.   |
| **Auto-straighten** | Off     | Estimates the page skew within ±10° and rotates the raw scan so the document is square before crop runs.                     |

The auto-crop result is written into the page's **Custom Crop** rectangle, so
you can still drag the handles to nudge it on any page where the detector
guessed wrong. Both passes run once, right after the scan finishes — they
never re-process a page you've already touched.

The detector is tuned for the common case the upstream tool handles poorly:
**letter-sized white pages, mostly text with some images, scanned at any of
the standard 75 / 150 / 200 / 300 / 600 dpi options in either color or
grayscale.** It should also work fine for A4 / legal / mixed text-and-photo
pages — the only assumption is "white-ish document on dark-ish background."

Everything else (devices, DPI, brightness/contrast, JPEG quality, the
existing scripted postprocessing hook, save formats) is unchanged from
upstream simple-scan 50.0.

## Install dependencies

For Ubuntu / Debian:

```
sudo apt install -y meson valac gcc gettext itstool libfribidi-dev \
  libgirepository1.0-dev libgtk-4-dev libadwaita-1-dev libgusb-dev \
  libcolord-dev libpackagekit-glib2-dev libwebp-dev libsane-dev git
```

For Fedora:

```
sudo dnf install -y meson vala gettext itstool fribidi-devel gtk4-devel \
  libadwaita-devel gobject-introspection-devel libgusb-devel colord-devel \
  PackageKit-glib-devel libwebp-devel sane-backends-devel git
```

For Arch Linux:

```
sudo pacman -S meson vala gettext itstool fribidi gtk4 libadwaita \
  gobject-introspection libgusb colord libwebp sane git
```

## Build and run

```
meson setup --prefix $PWD/_install _build
ninja -C _build all install
XDG_DATA_DIRS=_install/share:$XDG_DATA_DIRS ./_install/bin/simple-scan-enhanced
```

A virtual SANE `test` device is useful when you don't have a scanner attached:

```
./_install/bin/simple-scan-enhanced --debug test
```

Note that the test backend renders a uniform pattern, not a document on a
black bed, so the detector will refuse to crop it (by design — it falls back
to "no crop" when nothing looks like a document, leaving the full page
intact).

## Debugging the detector

Run with `--debug`; the detector logs threshold, sample size, detected
bounding box, and skew angle for each scan. Logs also land in
`$HOME/.cache/simple-scan/`.

## License & attribution

GPL-3.0-or-later, same as upstream — see [`COPYING`](./COPYING).

Built on top of GNOME Document Scanner (simple-scan), © 2009-2018 Canonical
Ltd. and the GNOME contributors. Auto-crop / auto-straighten additions and
the rebrand are © 2026 Document Scanner Enhanced contributors. See
`NEWS` for upstream release notes prior to the fork.
