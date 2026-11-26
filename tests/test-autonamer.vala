// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * Unit tests for the parts of auto-naming that don't talk to a server:
 * building the request, reading the reply and turning it into a filename.
 */

void check_slug (string input, string expected)
{
    var actual = AutoNamer.slugify (input);
    if (actual != expected)
        error ("slugify (\"%s\"): expected \"%s\", got \"%s\"", input, expected, actual);
}

void test_slugify_keeps_spaced_words ()
{
    check_slug ("Jordan Sample Explanation of Benefits", "Jordan Sample Explanation of Benefits");
}

void test_slugify_splits_joined_words ()
{
    check_slug ("BlueCross BlueShield", "Blue Cross Blue Shield");
    check_slug ("PacificPower Statement", "Pacific Power Statement");
    check_slug ("Invoice2024", "Invoice 2024");
}

void test_slugify_separators ()
{
    check_slug ("HX-200 cordless_drill", "HX 200 cordless drill");
    check_slug ("a__b--c", "a b c");
    check_slug ("  lots   of\tspace  ", "lots of space");
}

void test_slugify_drops_punctuation ()
{
    check_slug ("Bill: (final) / copy!", "Bill final copy");
    check_slug ("Emily R. Carter", "Emily R Carter");
}

void test_slugify_apostrophes ()
{
    check_slug ("Owner's Manual", "Owners Manual");
    check_slug ("Owner’s Manual", "Owners Manual");
}

void test_slugify_keeps_accented_letters ()
{
    check_slug ("Café Résumé Zoë", "Café Résumé Zoë");
}

void test_slugify_caps_length ()
{
    var s = AutoNamer.slugify (string.nfill (120, 'a'));
    assert_cmpint (s.char_count (), CompareOperator.EQ, 90);
}

void test_slugify_caps_length_on_character_boundary ()
{
    var input = new StringBuilder ();
    for (int i = 0; i < 120; i++)
        input.append ("é");
    var s = AutoNamer.slugify (input.str);
    assert_true (s.validate ());
    assert_cmpint (s.char_count (), CompareOperator.EQ, 90);
}

void check_date (string input, string expected)
{
    var actual = AutoNamer.normalize_date (input);
    if (actual != expected)
        error ("normalize_date (\"%s\"): expected \"%s\", got \"%s\"", input, expected, actual);
}

void test_dates ()
{
    check_date ("2026-10-30", "2026-10-30");
    check_date ("2026-10", "2026-10");
    check_date ("2026", "2026");
    check_date ("NONE", "");
    check_date ("", "");
    check_date ("2026/10/30", "");
    check_date ("30-10-2026", "");
    check_date ("October 30, 2026", "");
}

void check_parse (string content, string expected_date, string expected_person, string expected_desc)
{
    string date, person, desc;
    AutoNamer.parse_reply (content, out date, out person, out desc);
    if (date != expected_date || person != expected_person || desc != expected_desc)
        error ("parse (\"%s\"): expected \"%s\" | \"%s\" | \"%s\", got \"%s\" | \"%s\" | \"%s\"",
               content.escape (), expected_date, expected_person, expected_desc, date, person, desc);
}

void test_parse_reply ()
{
    check_parse ("2026-10-30|Jordan Sample|Explanation of Benefits from BlueCross",
                 "2026-10-30", "Jordan Sample", "Explanation of Benefits from Blue Cross");
    check_parse ("2024-03-13|Emily R. Carter|Patient Statement", "2024-03-13", "Emily R Carter", "Patient Statement");
    check_parse (" 2026-10-30 | Marcus Delgado | Power Bill ", "2026-10-30", "Marcus Delgado", "Power Bill");
}

void test_parse_reply_without_person ()
{
    check_parse ("NONE|NONE|Owner's Manual Cordless Drill", "", "", "Owners Manual Cordless Drill");
    check_parse ("2026|none|Tax Guide", "2026", "", "Tax Guide");
    check_parse ("2026|N/A|Tax Guide", "2026", "", "Tax Guide");
    check_parse ("2026||Tax Guide", "2026", "", "Tax Guide");
}

void test_parse_reply_extra_separators_stay_in_title ()
{
    check_parse ("2026|Jane Smith|Statement|Page 1", "2026", "Jane Smith", "Statement Page 1");
}

void test_parse_two_field_reply ()
{
    // The format before the person had a field of its own.
    check_parse ("2026-10-30|Power Bill", "2026-10-30", "", "Power Bill");
}

void test_parse_reply_without_separator ()
{
    check_parse ("Just A Title", "", "", "Just A Title");
}

void test_parse_reply_uses_first_line ()
{
    check_parse ("\n\n  2024|Jane Smith|Tax Return\nHere is why I chose it", "2024", "Jane Smith", "Tax Return");
}

void test_parse_empty_reply ()
{
    check_parse ("", "", "", "");
    check_parse ("\n  \n", "", "", "");
}

void test_parse_caps_person_length ()
{
    string date, person, desc;
    AutoNamer.parse_reply ("2026|%s|Letter".printf (string.nfill (60, 'a')), out date, out person, out desc);
    assert_cmpint (person.char_count (), CompareOperator.EQ, 40);
}

void check_name (string date, string person, string desc, string expected)
{
    var actual = AutoNamer.compose_name (date, person, desc);
    if (actual != expected)
        error ("compose_name: expected \"%s\", got \"%s\"", expected, actual);
}

void test_compose_name ()
{
    check_name ("2025-07-14", "Jane Smith", "Statement from Acme Bank", "2025-07-14 Jane Smith - Statement from Acme Bank");
    check_name ("", "Jane Smith", "Statement from Acme Bank", "Jane Smith - Statement from Acme Bank");
    check_name ("2025-07", "", "Statement from Acme Bank", "2025-07 Statement from Acme Bank");
    check_name ("", "", "Owners Manual", "Owners Manual");
}

void test_extract_content ()
{
    var body = """{"id":"x","choices":[{"index":0,"message":{"role":"assistant","content":"2026-10-30|Power Bill"},"finish_reason":"stop"}]}""";
    assert_cmpstr (AutoNamer.extract_content (body), CompareOperator.EQ, "2026-10-30|Power Bill");
}

void test_extract_content_unescapes ()
{
    var body = """{"choices":[{"message":{"content":"Café \"Quoted\"\nsecond\\line"}}]}""";
    assert_cmpstr (AutoNamer.extract_content (body), CompareOperator.EQ, "Café \"Quoted\"\nsecond\\line");
}

void test_extract_content_skips_empty ()
{
    var body = """{"choices":[{"message":{"content":""}},{"message":{"content":"2024|Tax Return"}}]}""";
    assert_cmpstr (AutoNamer.extract_content (body), CompareOperator.EQ, "2024|Tax Return");
}

void test_extract_content_out_of_tokens ()
{
    // What a reasoning model sends when it spends all its tokens thinking.
    var body = """{"choices":[{"message":{"content":"","reasoning":"Let me look at..."},"finish_reason":"length"}]}""";
    Test.expect_message (null, LogLevelFlags.LEVEL_WARNING, "*AutoNamer: reply carried no filename*");
    assert_null (AutoNamer.extract_content (body));
    Test.assert_expected_messages ();
}

void test_extract_content_error_reply ()
{
    var body = """{"error":{"message":"model not found"}}""";
    Test.expect_message (null, LogLevelFlags.LEVEL_WARNING, "*AutoNamer: no content field*");
    assert_null (AutoNamer.extract_content (body));
    Test.assert_expected_messages ();
}

void test_request_with_thinking_off ()
{
    var req = AutoNamer.build_request ("qwen3.5:4b", "QUJD", true);
    assert_true (req.contains ("\"model\":\"qwen3.5:4b\""));
    assert_true (req.contains ("\"stream\":false"));
    assert_true (req.contains ("\"temperature\":0"));
    assert_true (req.contains ("\"reasoning_effort\":\"none\""));
    assert_true (req.contains ("\"chat_template_kwargs\":{\"enable_thinking\":false}"));
    assert_true (req.contains ("\"url\":\"data:image/jpeg;base64,QUJD\""));
}

void test_request_plain ()
{
    var req = AutoNamer.build_request ("m", "QUJD", false);
    assert_false (req.contains ("reasoning_effort"));
    assert_false (req.contains ("chat_template_kwargs"));
}

void test_request_prompt_asks_for_person ()
{
    var req = AutoNamer.build_request ("m", "QUJD", true);
    assert_true (req.contains ("DATE|PERSON|TITLE"));
    assert_true (req.contains ("PERSON is the full name of the person the document is about, or NONE"));
    // Newlines in the prompt are escaped, not raw, so the JSON stays valid.
    assert_false (req.contains ("\n"));
}

void test_request_escapes_model_name ()
{
    var req = AutoNamer.build_request ("we\"ird\\name", "QUJD", false);
    assert_true (req.contains ("\"model\":\"we\\\"ird\\\\name\""));
}

int main (string[] args)
{
    Test.init (ref args);
    Test.add_func ("/slugify/keeps-spaced-words", test_slugify_keeps_spaced_words);
    Test.add_func ("/slugify/splits-joined-words", test_slugify_splits_joined_words);
    Test.add_func ("/slugify/separators", test_slugify_separators);
    Test.add_func ("/slugify/drops-punctuation", test_slugify_drops_punctuation);
    Test.add_func ("/slugify/apostrophes", test_slugify_apostrophes);
    Test.add_func ("/slugify/keeps-accented-letters", test_slugify_keeps_accented_letters);
    Test.add_func ("/slugify/caps-length", test_slugify_caps_length);
    Test.add_func ("/slugify/caps-length-on-character-boundary", test_slugify_caps_length_on_character_boundary);
    Test.add_func ("/date/formats", test_dates);
    Test.add_func ("/parse/reply", test_parse_reply);
    Test.add_func ("/parse/reply-without-person", test_parse_reply_without_person);
    Test.add_func ("/parse/extra-separators-stay-in-title", test_parse_reply_extra_separators_stay_in_title);
    Test.add_func ("/parse/two-field-reply", test_parse_two_field_reply);
    Test.add_func ("/parse/caps-person-length", test_parse_caps_person_length);
    Test.add_func ("/compose/name", test_compose_name);
    Test.add_func ("/parse/reply-without-separator", test_parse_reply_without_separator);
    Test.add_func ("/parse/uses-first-line", test_parse_reply_uses_first_line);
    Test.add_func ("/parse/empty-reply", test_parse_empty_reply);
    Test.add_func ("/extract/content", test_extract_content);
    Test.add_func ("/extract/unescapes", test_extract_content_unescapes);
    Test.add_func ("/extract/skips-empty", test_extract_content_skips_empty);
    Test.add_func ("/extract/out-of-tokens", test_extract_content_out_of_tokens);
    Test.add_func ("/extract/error-reply", test_extract_content_error_reply);
    Test.add_func ("/request/thinking-off", test_request_with_thinking_off);
    Test.add_func ("/request/plain", test_request_plain);
    Test.add_func ("/request/prompt-asks-for-person", test_request_prompt_asks_for_person);
    Test.add_func ("/request/escapes-model-name", test_request_escapes_model_name);
    return Test.run ();
}
