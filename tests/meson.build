# Tests. Run with:
#
#   meson test -C _build                                   unit, e2e and data checks
#   meson test -C _build --setup llm --suite llm --verbose live tests against a model
#
# The live tests are left out of the default run because they need a model
# server and its answers can drift; see test-llm-live.vala.

python = find_program ('python3')

test_util = files ('test-util.vala')

test_env = environment ()
test_env.set ('FAKE_LLM_SERVER', meson.current_source_dir () / 'fake-llm-server.py')
test_env.set ('PYTHON', python.full_path ())

tests = {
  'test-autonamer': 'unit',
  'test-document-detector': 'unit',
  'test-autonamer-e2e': 'e2e',
  'test-llm-live': 'llm',
}

foreach name, suite : tests
  exe = executable (name,
                    [ name + '.vala', test_util ] + testable_sources,
                    dependencies: dependencies,
                    vala_args: vala_args,
                    c_args: app_c_args + [ '-w' ],
                    link_args: [ '-lm' ])
  test (name.substring (5), exe,
        args: [ '--tap' ],
        protocol: 'tap',
        env: test_env,
        suite: suite,
        timeout: suite == 'llm' ? 300 : 60)
endforeach

glib_compile_schemas = find_program ('glib-compile-schemas')
test ('validate-schema', glib_compile_schemas,
      args: [ '--strict', '--dry-run', meson.project_source_root () / 'data' ],
      suite: 'data')

desktop_file_validate = find_program ('desktop-file-validate', required: false)
if desktop_file_validate.found ()
  test ('validate-desktop-file', desktop_file_validate,
        args: [ meson.project_build_root () / 'data' / 'io.github.RedNinjaDev.DocumentScannerEnhanced.desktop' ],
        suite: 'data')
endif

add_test_setup ('default', exclude_suites: [ 'llm' ], is_default: true)
add_test_setup ('llm')
