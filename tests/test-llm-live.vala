// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * Live auto-naming tests against a real model. Not part of the default test
 * run: they need a running server, and a model's answers can drift.
 *
 *   meson test -C _build --setup llm --suite llm --verbose
 *
 * LLM_ENDPOINT and LLM_MODEL choose the server and model (by default the
 * app's own defaults: Ollama on localhost with qwen3.5:4b), LLM_API_KEY an
 * API key. Each test is skipped when the server can't be reached.
 *
 * The documents are synthetic, with made-up names. The checks are the ones
 * that matter for a filename: the right date, the person's name and a dash
 * before the title, the sender, and words with spaces between them.
 */

using TestUtil;

string endpoint;
string model;
string api_key;
bool server_reachable;

bool can_reach (string url) throws Error
{
    var uri = Uri.parse (url, UriFlags.NONE);
    int port = uri.get_port ();
    if (port < 0)
        port = uri.get_scheme () == "https" ? 443 : 80;
    var client = new SocketClient () { timeout = 3 };
    var connection = client.connect_to_host (uri.get_host (), (uint16) port);
    connection.close ();
    return true;
}

string? name_document (string[] lines)
{
    if (!server_reachable)
    {
        Test.skip ("no server at %s".printf (endpoint));
        return null;
    }
    var name = suggest (text_document (lines), endpoint, model, api_key);
    Test.message ("suggested: %s", name ?? "(nothing)");
    if (name == null)
        error ("%s gave no usable name; is %s installed? See the warnings above", endpoint, model);
    return name;
}

void assert_contains (string name, string part)
{
    if (!name.contains (part))
        error ("\"%s\" does not contain \"%s\"", name, part);
}

void assert_words_are_spaced (string name)
{
    // Run-together words ("bluecrossclaimsummary") are what this guards against.
    foreach (var word in name.split (" "))
        if (word.length > 16)
            error ("\"%s\" has a run-together word: \"%s\"", name, word);
}

void test_insurance_claim ()
{
    var name = name_document ({
        "b44|BlueCross BlueShield",
        "28|Explanation of Benefits - Claim Summary",
        "24|Statement Date: October 30, 2026",
        "22|Member: Jordan Sample   ID: XYZ123456789",
        "22|Provider: Valley Family Clinic",
        "22|Amount billed: $412.00     Plan paid: $329.60",
        "b24|THIS IS NOT A BILL" });
    if (name == null) return;
    assert_true (name.has_prefix ("2026-10-30 Jordan Sample - "));
    assert_contains (name, "Blue Cross");
    assert_true (name.has_suffix (".pdf"));
    assert_words_are_spaced (name);
}

void test_dental_statement ()
{
    var name = name_document ({
        "b44|Bright Smile Dental",
        "28|Patient Statement",
        "22|Patient: Emily R. Carter",
        "24|Date: 2024-03-13",
        "22|Cleaning and exam   $180.00",
        "b24|Balance due: $36.00" });
    if (name == null) return;
    assert_true (name.has_prefix ("2024-03-13 Emily "));
    assert_contains (name, "Carter - ");
    assert_contains (name, "Dental");
    assert_words_are_spaced (name);
}

void test_power_bill ()
{
    var name = name_document ({
        "b44|PacificPower Electric",
        "28|Your Monthly Energy Statement",
        "22|Account holder: Marcus Delgado, 18 Elm St",
        "24|Billing period: Sep 12 - Oct 11, 2026",
        "22|Total amount due: $143.27",
        "22|Due by November 2, 2026" });
    if (name == null) return;
    assert_true (name.has_prefix ("2026-"));
    // The name straight after the date, then a dash.
    var after_date = name.substring (name.index_of (" ") + 1);
    assert_true (after_date.has_prefix ("Marcus Delgado - "));
    assert_contains (name, "Pacific Power");
    assert_words_are_spaced (name);
}

void test_receipt_has_no_person ()
{
    var name = name_document ({
        "b44|Corner Hardware",
        "28|Receipt",
        "24|03/15/2026  14:22",
        "22|Wood screws   $6.49",
        "22|Sandpaper     $4.99",
        "b24|Total  $11.48  VISA ****1234" });
    if (name == null) return;
    assert_true (name.has_prefix ("2026-03-15 "));
    // No person, so no dash.
    assert_false (name.contains (" - "));
    assert_contains (name, "Receipt");
    assert_contains (name, "Corner Hardware");
    assert_words_are_spaced (name);
}

void test_manual_has_no_date ()
{
    var name = name_document ({
        "b44|Owner's Manual",
        "28|Model HX-200 Cordless Drill",
        "22|Read all safety warnings before use." });
    if (name == null) return;
    assert_false (Regex.match_simple ("^[0-9]{4}", name));
    // No person, so no dash.
    assert_false (name.contains (" - "));
    assert_contains (name, "Manual");
    assert_contains (name, "Drill");
    assert_words_are_spaced (name);
}

int main (string[] args)
{
    Test.init (ref args);
    // A refused request or missing model is reported by the test that hit it,
    // with the server's answer in the warning, rather than aborting the run.
    Log.set_always_fatal (LogLevelFlags.LEVEL_CRITICAL | LogLevelFlags.LEVEL_ERROR);

    endpoint = Environment.get_variable ("LLM_ENDPOINT") ?? "http://localhost:11434/v1/chat/completions";
    model = Environment.get_variable ("LLM_MODEL") ?? "qwen3.5:4b";
    api_key = Environment.get_variable ("LLM_API_KEY") ?? "";
    try { server_reachable = can_reach (endpoint); }
    catch (Error e) { server_reachable = false; }

    Test.add_func ("/llm/insurance-claim", test_insurance_claim);
    Test.add_func ("/llm/dental-statement", test_dental_statement);
    Test.add_func ("/llm/power-bill", test_power_bill);
    Test.add_func ("/llm/receipt-has-no-person", test_receipt_has_no_person);
    Test.add_func ("/llm/manual-has-no-date", test_manual_has_no_date);
    return Test.run ();
}
