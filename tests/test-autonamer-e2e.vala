// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * End-to-end tests for auto-naming: a scanned page goes through the real
 * request code and curl to a scripted fake server (fake-llm-server.py), and
 * the filename comes back the way the Save dialog would get it.
 */

using TestUtil;

class FakeServer
{
    private Subprocess process;
    private int port;
    private string log_path;
    private int lines_read = 0;

    public FakeServer () throws Error
    {
        var script = Environment.get_variable ("FAKE_LLM_SERVER");
        if (script == null)
            error ("FAKE_LLM_SERVER is not set; run this through meson test");
        var python = Environment.get_variable ("PYTHON") ?? "python3";

        log_path = Path.build_filename (DirUtils.make_tmp ("autonamer-e2e-XXXXXX"), "requests.log");
        FileUtils.set_contents (log_path, "");
        // The server exits when its stdin closes, so it never outlives this
        // process, even when a failed test aborts it.
        process = new Subprocess (SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_PIPE,
                                  python, script, log_path);
        var output = new DataInputStream (process.get_stdout_pipe ());
        port = int.parse (output.read_line ());
        if (port <= 0)
            error ("fake server did not report a port");
    }

    public string url (string path)
    {
        return "http://127.0.0.1:%d%s".printf (port, path);
    }

    // The requests received since the last call, one array of fields each.
    public string[,] new_requests (out int count)
    {
        string contents;
        try { FileUtils.get_contents (log_path, out contents); }
        catch (Error e) { error ("%s", e.message); }

        var lines = new GenericArray<string> ();
        foreach (var line in contents.split ("\n"))
            if (line != "")
                lines.add (line);

        count = lines.length - lines_read;
        var result = new string[count, 5];
        for (int i = 0; i < count; i++)
        {
            var fields = lines[lines_read + i].split ("\t");
            for (int f = 0; f < 5; f++)
                result[i, f] = f < fields.length ? fields[f] : "";
        }
        lines_read = lines.length;
        return result;
    }

    public void stop ()
    {
        process.force_exit ();
    }
}

const int PATH = 0;
const int AUTH = 1;
const int MODEL = 2;
const int FLAGS = 3;
const int IMAGE = 4;

FakeServer server;

Page small_document ()
{
    return text_document ({ "b40|BlueCross BlueShield", "24|Member: Jordan Sample" }, 700, 900);
}

void test_names_document ()
{
    var name = suggest (small_document (), server.url ("/ok"), "test-model");
    assert_cmpstr (name, CompareOperator.EQ, "2026-10-30 Jordan Sample - Explanation of Benefits from Blue Cross.pdf");

    int n;
    var req = server.new_requests (out n);
    assert_cmpint (n, CompareOperator.EQ, 1);
    assert_cmpstr (req[0, PATH], CompareOperator.EQ, "/ok");
    assert_cmpstr (req[0, MODEL], CompareOperator.EQ, "test-model");
    assert_cmpstr (req[0, AUTH], CompareOperator.EQ, "");
    assert_cmpstr (req[0, FLAGS], CompareOperator.EQ, "1");
    assert_cmpstr (req[0, IMAGE], CompareOperator.EQ, "700x900");
}

void test_undated_document ()
{
    var name = suggest (small_document (), server.url ("/nodate"), "test-model");
    assert_cmpstr (name, CompareOperator.EQ, "Owners Manual Cordless Drill.pdf");
    int n;
    server.new_requests (out n);
}

void test_uses_requested_extension ()
{
    var name = suggest (small_document (), server.url ("/ok"), "test-model", "", "png");
    assert_true (name.has_suffix (" from Blue Cross.png"));
    int n;
    server.new_requests (out n);
}

void test_sends_api_key ()
{
    suggest (small_document (), server.url ("/ok"), "test-model", "  sk-test-123 ");
    int n;
    var req = server.new_requests (out n);
    assert_cmpint (n, CompareOperator.EQ, 1);
    assert_cmpstr (req[0, AUTH], CompareOperator.EQ, "Bearer sk-test-123");
}

void test_retries_without_thinking_flags ()
{
    var name = suggest (small_document (), server.url ("/reject-flags"), "test-model");
    assert_cmpstr (name, CompareOperator.EQ, "2026-10-30 Jordan Sample - Explanation of Benefits from Blue Cross.pdf");

    int n;
    var req = server.new_requests (out n);
    assert_cmpint (n, CompareOperator.EQ, 2);
    assert_cmpstr (req[0, FLAGS], CompareOperator.EQ, "1");
    assert_cmpstr (req[1, FLAGS], CompareOperator.EQ, "0");
}

void test_downscales_large_scan ()
{
    // A letter page at 300 dpi is sent at 1024 pixels on its long side.
    var page = draw_page (2550, 3300, true, (cr) => { cr.set_source_rgb (1, 1, 1); cr.paint (); });
    suggest (page, server.url ("/ok"), "test-model");
    int n;
    var req = server.new_requests (out n);
    assert_cmpstr (req[0, IMAGE], CompareOperator.EQ, "791x1024");
}

void test_sends_cropped_area ()
{
    // An auto-cropped page is named from what is inside the crop.
    var page = draw_page (1600, 900, true, (cr) => { cr.set_source_rgb (1, 1, 1); cr.paint (); });
    page.set_custom_crop_region (100, 100, 500, 400);
    suggest (page, server.url ("/ok"), "test-model");
    int n;
    var req = server.new_requests (out n);
    assert_cmpstr (req[0, IMAGE], CompareOperator.EQ, "500x400");
}

void test_reasoning_model_out_of_tokens ()
{
    Test.expect_message (null, LogLevelFlags.LEVEL_WARNING, "*AutoNamer: reply carried no filename*");
    assert_null (suggest (small_document (), server.url ("/empty"), "test-model"));
    Test.assert_expected_messages ();
    int n;
    server.new_requests (out n);
    assert_cmpint (n, CompareOperator.EQ, 1);
}

void test_server_down ()
{
    // A port that was free a moment ago has nothing listening on it.
    int port = 0;
    try
    {
        var socket = new Socket (SocketFamily.IPV4, SocketType.STREAM, SocketProtocol.TCP);
        socket.bind (new InetSocketAddress (new InetAddress.loopback (SocketFamily.IPV4), 0), true);
        port = (int) ((InetSocketAddress) socket.get_local_address ()).port;
        socket.close ();
    }
    catch (Error e) { error ("%s", e.message); }

    Test.expect_message (null, LogLevelFlags.LEVEL_WARNING, "*AutoNamer: curl exited non-zero*");
    assert_null (suggest (small_document (), "http://127.0.0.1:%d/v1/chat/completions".printf (port), "test-model"));
    Test.assert_expected_messages ();
}

void test_blank_settings_send_nothing ()
{
    assert_null (suggest (small_document (), "  ", "test-model"));
    assert_null (suggest (small_document (), server.url ("/ok"), ""));
    int n;
    server.new_requests (out n);
    assert_cmpint (n, CompareOperator.EQ, 0);
}

int main (string[] args)
{
    Test.init (ref args);
    try { server = new FakeServer (); }
    catch (Error e) { error ("cannot start fake server: %s", e.message); }

    Test.add_func ("/autonamer-e2e/names-document", test_names_document);
    Test.add_func ("/autonamer-e2e/undated-document", test_undated_document);
    Test.add_func ("/autonamer-e2e/uses-requested-extension", test_uses_requested_extension);
    Test.add_func ("/autonamer-e2e/sends-api-key", test_sends_api_key);
    Test.add_func ("/autonamer-e2e/retries-without-thinking-flags", test_retries_without_thinking_flags);
    Test.add_func ("/autonamer-e2e/downscales-large-scan", test_downscales_large_scan);
    Test.add_func ("/autonamer-e2e/sends-cropped-area", test_sends_cropped_area);
    Test.add_func ("/autonamer-e2e/reasoning-model-out-of-tokens", test_reasoning_model_out_of_tokens);
    Test.add_func ("/autonamer-e2e/server-down", test_server_down);
    Test.add_func ("/autonamer-e2e/blank-settings-send-nothing", test_blank_settings_send_nothing);
    var result = Test.run ();
    server.stop ();
    return result;
}
