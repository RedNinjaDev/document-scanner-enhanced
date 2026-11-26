[![License](https://img.shields.io/badge/License-GPL%20v3-blue.svg)](COPYING)

# Document Scanner Enhanced

*Document Scanner Enhanced* is a fork of GNOME
[Document Scanner](https://gitlab.gnome.org/GNOME/simple-scan) (simple-scan), a document
scanning application that captures images from [image scanners](https://en.wikipedia.org/wiki/Image_scanner)
with suitable [SANE drivers](http://sane-project.org/) installed.

It has its own application ID, so it installs alongside the stock Document Scanner rather than
replacing it, and keeps its own settings.

## What it adds

All three are under Preferences → Postprocessing, and all are off until you turn them on.

* **Auto-Crop** puts a Custom Crop around the document detected on each new scan. The crop stays
  fully adjustable afterwards.
* **Auto-Straighten** rotates each new scan to correct skew of up to about ten degrees, before any
  auto-crop is applied. Unlike the crop, the rotation cannot be undone.
* **Auto-Name on Save** sends the first page to a vision-capable model behind an OpenAI-compatible
  chat completions endpoint and pre-fills the Save dialog with the document's date, the person it
  is about (when one is named), who it is from and what it is, like
  `2024-03-13 Emily Carter Bright Smile Dental Statement.pdf`. The default is a local
  [Ollama](https://ollama.com) running `qwen3.5:4b`; the endpoint, API key and model are
  configurable.

Auto-Crop detects the document as the brighter region against the scanner bed, so it needs a
background darker than the paper, such as the black backing of many sheet-fed scanners. Against a
white flatbed lid there is nothing to crop and the page is left uncropped. Auto-Straighten works
either way: it measures the skew from the paper's edges or, against a white lid, from the lines of
text.

# Building from source

The build needs GTK 4.15.2 or later and libadwaita 1.8 or later, so a recent distribution such as
Ubuntu 26.04.

Install the dependencies

For Ubuntu/Debian:

```
sudo apt install -y meson valac gcc gettext itstool libfribidi-dev libgirepository1.0-dev libgtk-4-dev libadwaita-1-dev libgusb-dev libcolord-dev libpackagekit-glib2-dev libwebp-dev libsane-dev git ca-certificates curl
```

For Fedora:

```
sudo dnf install -y meson vala gettext itstool fribidi-devel gtk4-devel libadwaita-devel gobject-introspection-devel libgusb-devel colord-devel PackageKit-glib-devel libwebp-devel sane-backends-devel git curl
```

For Arch Linux:

```
sudo pacman -S meson vala gettext itstool fribidi gtk4 libadwaita gobject-introspection libgusb colord libwebp sane git curl
```

Get the source:

```
git clone https://github.com/RedNinjaDev/document-scanner-enhanced.git
cd document-scanner-enhanced
```

Build and run without installing:

```
meson setup --prefix $PWD/_install _build
ninja -C _build all install
XDG_DATA_DIRS=_install/share:$XDG_DATA_DIRS ./_install/bin/document-scanner-enhanced
```

Or install system-wide, after which it appears in the application menu as
*Document Scanner Enhanced*:

```
meson setup --prefix /usr/local _build
ninja -C _build
sudo ninja -C _build install
```

A Flatpak manifest is in `build-aux/flatpak/`, but a sandboxed build only sees the SANE backends
bundled with it, not proprietary drivers installed on the host.

# Tests

```
meson test -C _build
```

runs the unit tests (document detection, straightening, and turning a model's reply into a
filename), end-to-end tests of auto-naming against a scripted fake model server, and checks of the
settings schema, desktop file and AppStream metadata. They need no scanner, model or network.

```
meson test -C _build --setup llm --suite llm --verbose
```

runs live auto-naming tests on synthetic documents against a real model and prints the names it
suggests. They are left out of the default run because a model's answers can drift. They use the
app's default Ollama endpoint and model; set `LLM_ENDPOINT`, `LLM_MODEL` and `LLM_API_KEY` to try
another. Each test is skipped when the server can't be reached.

The tests are in `tests/`. Pages are drawn with Cairo, so no sample scans are needed.

# Debugging

There is a `--debug` command line switch to enable more verbose logging:
```
$ document-scanner-enhanced --debug
```

Log messages can also be found in the `$HOME/.cache/document-scanner-enhanced` folder.

If you don't have a scanner ready, you can use a virtual `test` scanner:
```
$ document-scanner-enhanced --debug test
```

This app works by using the [SANE API](http://sane-project.org/html/) to
capture images. Drivers have many options and are of differing quality - it
is useful to work out if any issues are caused by the app or the drivers. To
confirm it is a driver issue you can use the graphical tool (XSane) or the
command line
[scanimage](http://www.sane-project.org/man/scanimage.1.html) provided
by the SANE project - these allow to to easily see and control all the
settings your driver provides.

To enable debug traces on SANE's backend loader, set the `SANE_DEBUG_DLL`
environment variable:

```
$ export SANE_DEBUG_DLL=255
```

# Issues and translations

Report problems with the added features on
[GitHub](https://github.com/RedNinjaDev/document-scanner-enhanced/issues). Problems that also
happen in the stock Document Scanner belong
[upstream](https://gitlab.gnome.org/GNOME/simple-scan/-/work_items).

Translations come from upstream's [GNOME translation project](https://l10n.gnome.org/module/simple-scan/).
Strings added or changed by this fork appear in English.
