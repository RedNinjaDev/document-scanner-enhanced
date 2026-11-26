vala_args = [ '--pkg=posix', '--vapidir=' + meson.current_source_dir () ]
dependencies = [ glib_dep, gtk_dep, libadwaita_dep, zlib_dep, cairo_dep, gdk_pixbuf_dep, gusb_dep, sane_dep ]
if colord_dep.found ()
    vala_args += [ '-D', 'HAVE_COLORD' ]
    dependencies += colord_dep
endif
if packagekit_dep.found ()
    vala_args += [ '-D', 'HAVE_PACKAGEKIT' ]
    dependencies += packagekit_dep
endif
if webp_dep.found () and (not colord_dep.found () or webpmux_dep.found ()) # Webpmux only required if colord
    vala_args += [ '-D', 'HAVE_WEBP' ]
    dependencies += [ webp_dep, webpmux_dep ]
endif

app_c_args = [ '-DVERSION="@0@"'.format (meson.project_version ()),
               '-DGETTEXT_PACKAGE="simple-scan"',
               '-DLOCALE_DIR="@0@"'.format (localedir),
               '-DI_KNOW_THE_PACKAGEKIT_GLIB2_API_IS_SUBJECT_TO_CHANGE' ]

# The parts of the app the tests build against: scanned pages, document
# detection and auto-naming, without the user interface.
testable_sources = files ('config.vapi',
                          'autonamer.vala',
                          'document-detector.vala',
                          'page.vala',
                          'scanner.vala')

simple_scan = executable ('document-scanner-enhanced',
                          [ 'config.vapi',
                            'app-window.vala',
                            'authorize-dialog.vala',
                            'autonamer.vala',
                            'book.vala',
                            'book-view.vala',
                            'document-detector.vala',
                            'drivers-dialog.vala',
                            'page.vala',
                            'page-texture.vala',
                            'page-view.vala',
                            'postprocessor.vala',
                            'preferences-dialog.vala',
                            'reorder-pages-dialog.vala',
                            'simple-scan.vala',
                            'scanner.vala',
                            'screensaver.vala',
                            'autosave-manager.vala' ] + resources,
                          dependencies: dependencies,
                          vala_args: vala_args,
                          c_args: app_c_args,
                          link_args: [ '-lm' ],
                          install: true )
