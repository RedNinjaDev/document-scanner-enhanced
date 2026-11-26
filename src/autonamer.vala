// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * Copyright (C) 2026 RedNinjaDev
 * Author: RedNinjaDev <19934811+RedNinjaDev@users.noreply.github.com>
 *
 * This program is free software: you can redistribute it and/or modify it under
 * the terms of the GNU General Public License as published by the Free Software
 * Foundation, either version 3 of the License, or (at your option) any later
 * version. See http://www.gnu.org/copyleft/gpl.html the full text of the
 * license.
 */

public class AutoNamer
{
    internal const int MAX_DESC_LEN = 90;
    internal const int MAX_PERSON_LEN = 40;
    private const int CURL_TIMEOUT_SEC = 60;
    // Enough for a reasoning model that ignores the request to skip its
    // thinking: one measured a thousand tokens before answering.
    private const int MAX_RESPONSE_TOKENS = 2048;
    private const int ANALYSIS_MAX_SIDE = 1024;
    private const int JPEG_QUALITY = 70;

    public static async string? suggest_filename (Page first_page,
                                                  string endpoint,
                                                  string api_key,
                                                  string model,
                                                  string extension)
    {
        if (endpoint.strip () == "" || model.strip () == "")
            return null;

        string? b64 = encode_page_jpeg_base64 (first_page);
        if (b64 == null) return null;

        // Ask the model to answer without thinking first. Where that is
        // honoured the reply costs a couple of dozen tokens instead of a
        // thousand, which is the difference between waiting half a second
        // and ten for the save dialog. Endpoints that reject parameters they
        // do not recognise get one plain retry.
        string? body = yield run_curl (endpoint, api_key, build_request (model, b64, true));
        if (body != null && body.contains ("\"error\""))
            body = yield run_curl (endpoint, api_key, build_request (model, b64, false));
        if (body == null) return null;

        string? content = extract_content (body);
        if (content == null) return null;

        string date_part, person_part, desc_part;
        parse_reply (content, out date_part, out person_part, out desc_part);
        if (desc_part == "") return null;

        return compose_name (date_part, person_part, desc_part) + "." + extension;
    }

    private static string? encode_page_jpeg_base64 (Page page)
    {
        try {
            var pix = page.get_image (true);
            // Downscale to keep request payload small.
            int w = pix.get_width (), h = pix.get_height ();
            int long_side = int.max (w, h);
            if (long_side > ANALYSIS_MAX_SIDE) {
                double s = (double) ANALYSIS_MAX_SIDE / long_side;
                pix = pix.scale_simple ((int)(w*s), (int)(h*s), Gdk.InterpType.BILINEAR);
            }
            uint8[] bytes;
            pix.save_to_buffer (out bytes, "jpeg", "quality", JPEG_QUALITY.to_string (), null);
            return Base64.encode (bytes);
        } catch (Error e) {
            warning ("AutoNamer: failed to encode page: %s", e.message);
            return null;
        }
    }

    internal static string build_request (string model, string b64_jpeg, bool skip_thinking)
    {
        // Ask for a title, not a filename: small models told to produce
        // something "suitable as a filename" run the words together
        // ("bluecrossbillsummary"), which slugify cannot split again.
        const string PROMPT =
            "What is this scanned document? Reply with one line in the form DATE|PERSON|TITLE and nothing else.\n" +
            "DATE is the document's main date as YYYY-MM-DD (or YYYY-MM, or YYYY, or NONE).\n" +
            "PERSON is the full name of the person the document is about, or NONE if no person is named.\n" +
            "TITLE is 2 to 6 words in Title Case, separated by spaces, saying what the document is and who it is from.\n" +
            "Example: 2025-07-14|Jane Smith|Credit Card Statement from Acme Bank";

        var sb = new StringBuilder ();
        sb.append ("{\"model\":");
        append_json_string (sb, model);
        sb.append (",\"stream\":false,\"temperature\":0,\"max_tokens\":");
        sb.append (MAX_RESPONSE_TOKENS.to_string ());
        sb.append (",");
        // Servers differ in how they take this: vLLM and llama.cpp read the
        // chat template flag, Ollama only honours reasoning_effort.
        if (skip_thinking)
            sb.append ("\"chat_template_kwargs\":{\"enable_thinking\":false},\"reasoning_effort\":\"none\",");
        sb.append ("\"messages\":[{\"role\":\"user\",\"content\":[");
        sb.append ("{\"type\":\"text\",\"text\":");
        append_json_string (sb, PROMPT);
        sb.append ("},{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/jpeg;base64,");
        sb.append (b64_jpeg);
        sb.append ("\"}}]}]}");
        return sb.str;
    }

    private static void append_json_string (StringBuilder sb, string s)
    {
        sb.append_c ('"');
        for (int i = 0; i < s.length; i++) {
            char c = s[i];
            switch (c) {
                case '"':  sb.append ("\\\""); break;
                case '\\': sb.append ("\\\\"); break;
                case '\n': sb.append ("\\n");  break;
                case '\r': sb.append ("\\r");  break;
                case '\t': sb.append ("\\t");  break;
                default:
                    if ((uchar)c < 0x20) sb.append_printf ("\\u%04x", (uint)c);
                    else sb.append_c (c);
                    break;
            }
        }
        sb.append_c ('"');
    }

    private static async string? run_curl (string endpoint, string api_key, string request_body)
    {
        // Write request to a tempfile rather than passing 100KB+ on argv.
        FileIOStream? iostream = null;
        File? tmp = null;
        try {
            tmp = File.new_tmp ("dscanenh-XXXXXX.json", out iostream);
            var os = iostream.output_stream;
            os.write_all (request_body.data, null);
            os.close (null);
        } catch (Error e) {
            warning ("AutoNamer: cannot create temp file: %s", e.message);
            return null;
        }

        var argv = new GenericArray<string> ();
        argv.add ("curl");
        argv.add ("--silent");
        argv.add ("--show-error");
        argv.add ("--max-time"); argv.add (CURL_TIMEOUT_SEC.to_string ());
        argv.add ("--header"); argv.add ("Content-Type: application/json");
        if (api_key.strip () != "") {
            argv.add ("--header");
            argv.add (@"Authorization: Bearer $(api_key.strip ())");
        }
        argv.add ("--data-binary");
        argv.add ("@" + tmp.get_path ());
        argv.add (endpoint);

        string[] args = argv.data;
        try {
            var proc = new Subprocess.newv (
                args,
                SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
            Bytes? stdout_bytes, stderr_bytes;
            yield proc.communicate_async (null, null, out stdout_bytes, out stderr_bytes);
            tmp.delete_async.begin (Priority.DEFAULT, null);
            if (!proc.get_successful ()) {
                warning ("AutoNamer: curl exited non-zero: %s",
                         (string) stderr_bytes.get_data ());
                return null;
            }
            return (string) stdout_bytes.get_data ();
        } catch (Error e) {
            warning ("AutoNamer: curl failed: %s", e.message);
            try { tmp.delete (null); } catch (Error _e) {}
            return null;
        }
    }

    // Extract the assistant message content from a chat-completions response.
    // Looks for the first "content":"..." string. Robust enough for the shapes
    // OpenAI / Ollama / OpenRouter return for non-streamed responses.
    internal static string? extract_content (string body)
    {
        try {
            var re = new Regex ("\"content\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"",
                                RegexCompileFlags.DOTALL);
            MatchInfo m;
            if (re.match (body, 0, out m)) {
                // A reasoning model answers with an empty content field when
                // it runs out of tokens mid-thought, so keep looking.
                do {
                    var content = unescape_json_string (m.fetch (1));
                    if (content.strip () != "")
                        return content;
                } while (m.next ());

                warning ("AutoNamer: reply carried no filename, the model may have run out of tokens: %s",
                         body.substring (0, int.min (body.length, 300)));
                return null;
            }

            warning ("AutoNamer: no content field in response: %s",
                     body.substring (0, int.min (body.length, 300)));
            return null;
        } catch (RegexError e) {
            warning ("AutoNamer: regex error: %s", e.message);
            return null;
        }
    }

    internal static string unescape_json_string (string s)
    {
        var sb = new StringBuilder ();
        int i = 0;
        while (i < s.length) {
            char c = s[i];
            if (c == '\\' && i + 1 < s.length) {
                char n = s[i + 1];
                switch (n) {
                    case '"':  sb.append_c ('"');  i += 2; continue;
                    case '\\': sb.append_c ('\\'); i += 2; continue;
                    case '/':  sb.append_c ('/');  i += 2; continue;
                    case 'n':  sb.append_c ('\n'); i += 2; continue;
                    case 'r':  sb.append_c ('\r'); i += 2; continue;
                    case 't':  sb.append_c ('\t'); i += 2; continue;
                    case 'b':  sb.append_c ('\b'); i += 2; continue;
                    case 'f':  sb.append_c ('\f'); i += 2; continue;
                    case 'u':
                        if (i + 5 < s.length) {
                            uint code = uint.parse (s.substring (i + 2, 4), 16);
                            sb.append_unichar ((unichar) code);
                            i += 6; continue;
                        }
                        break;
                }
            }
            sb.append_c (c);
            i++;
        }
        return sb.str;
    }

    // The first non-empty line is expected to be "DATE|PERSON|TITLE". The
    // older "DATE|TITLE", or a bare title, is accepted too.
    internal static void parse_reply (string content,
                                      out string date_part,
                                      out string person_part,
                                      out string desc_part)
    {
        date_part = ""; person_part = ""; desc_part = "";
        string? line = null;
        foreach (string raw in content.split ("\n")) {
            string l = raw.strip ();
            if (l != "") { line = l; break; }
        }
        if (line == null) return;

        string[] fields = line.split ("|", 3);
        string raw_date = "", raw_person = "", raw_desc;
        if (fields.length == 3) {
            raw_date = fields[0]; raw_person = fields[1]; raw_desc = fields[2];
        } else if (fields.length == 2) {
            raw_date = fields[0]; raw_desc = fields[1];
        } else {
            raw_desc = fields[0];
        }

        date_part = normalize_date (raw_date.strip ());
        person_part = normalize_person (raw_person);
        desc_part = slugify (raw_desc);
    }

    // "2026-10-30 Jane Smith - Statement from Acme Bank", leaving out
    // whichever of the date and the person the document doesn't have.
    internal static string compose_name (string date, string person, string desc)
    {
        string name = desc;
        if (person != "") name = @"$person - $name";
        if (date != "") name = @"$date $name";
        return name;
    }

    internal static string normalize_person (string raw)
    {
        string p = raw.strip ();
        string up = p.up ();
        if (up == "NONE" || up == "N/A" || up == "UNKNOWN")
            return "";
        return slugify (p, MAX_PERSON_LEN);
    }

    internal static string normalize_date (string raw)
    {
        try {
            var re_ymd = new Regex ("^(\\d{4})-(\\d{2})-(\\d{2})$");
            var re_ym  = new Regex ("^(\\d{4})-(\\d{2})$");
            var re_y   = new Regex ("^(\\d{4})$");
            if (re_ymd.match (raw) || re_ym.match (raw) || re_y.match (raw))
                return raw;
        } catch (RegexError e) {
            warning ("AutoNamer: date regex error: %s", e.message);
        }
        return "";
    }

    // Strip everything that's not letter, digit, space, hyphen or underscore.
    // Insert spaces at camelCase boundaries (small models often ignore the
    // prompt's "spaces between words" instruction and mash them together).
    // Collapse runs of separators and clamp length.
    internal static string slugify (string raw, int max_len = MAX_DESC_LEN)
    {
        var sb = new StringBuilder ();
        unichar c;
        for (int i = 0; raw.get_next_char (ref i, out c); ) {
            if (c.isalnum () || c == ' ' || c == '-' || c == '_')
                sb.append_unichar (c);
            else if (c == '\'' || c == 0x2019)
                continue;  // Owner's -> Owners, not "Owner s"
            else
                sb.append_c (' ');
        }
        string s = sb.str;
        try {
            // Split camelCase / PascalCase: lower→Upper and letter→digit, digit→letter
            s = (new Regex ("([a-z])([A-Z])")).replace (s, s.length, 0, "\\1 \\2");
            s = (new Regex ("([A-Za-z])([0-9])")).replace (s, s.length, 0, "\\1 \\2");
            s = (new Regex ("([0-9])([A-Za-z])")).replace (s, s.length, 0, "\\1 \\2");
            // Treat _ and - as word separators
            s = (new Regex ("[_-]+")).replace (s, s.length, 0, " ");
            // Collapse whitespace
            s = (new Regex ("\\s+")).replace (s, s.length, 0, " ");
        } catch (RegexError e) {}
        s = s.strip ();
        // Count characters, not bytes, so an accented letter is never cut in half.
        if (s.char_count () > max_len)
            s = s.substring (0, s.index_of_nth_char (max_len)).strip ();
        return s;
    }
}
