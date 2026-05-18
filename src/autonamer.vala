// SPDX-License-Identifier: GPL-3.0-or-later

public class AutoNamer
{
    private const int MAX_DESC_LEN = 60;
    private const int CURL_TIMEOUT_SEC = 15;
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

        string request = build_request (model, b64);

        string? body = yield run_curl (endpoint, api_key, request);
        if (body == null) return null;

        string? content = extract_content (body);
        if (content == null) return null;

        string date_part, desc_part;
        parse_date_and_desc (content, out date_part, out desc_part);
        if (desc_part == "") return null;

        string name = (date_part != "") ? @"$date_part $desc_part" : desc_part;
        return @"$name.$extension";
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

    private static string build_request (string model, string b64_jpeg)
    {
        const string PROMPT =
            "Analyze this scanned document and reply on EXACTLY ONE LINE in this format:\n" +
            "<date>|<description>\n" +
            "Where <date> is the document's most prominent date as YYYY-MM-DD (or YYYY-MM, or YYYY, or NONE if no date is visible),\n" +
            "and <description> is 3 to 6 separate English words with a SINGLE SPACE between each word, suitable as a filename: letters, digits and spaces only — no punctuation, no CamelCase, no underscores, no hyphens.\n" +
            "Reply with that single line only, no other text.";

        var sb = new StringBuilder ();
        sb.append ("{\"model\":");
        append_json_string (sb, model);
        sb.append (",\"stream\":false,\"temperature\":0,\"max_tokens\":80,");
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
    private static string? extract_content (string body)
    {
        try {
            var re = new Regex ("\"content\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"",
                                RegexCompileFlags.DOTALL);
            MatchInfo m;
            if (!re.match (body, 0, out m)) {
                warning ("AutoNamer: no content field in response: %s",
                         body.substring (0, int.min (body.length, 300)));
                return null;
            }
            return unescape_json_string (m.fetch (1));
        } catch (RegexError e) {
            warning ("AutoNamer: regex error: %s", e.message);
            return null;
        }
    }

    private static string unescape_json_string (string s)
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
                            uint code = (uint) s.substring (i + 2, 4).to_long (null, 16);
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

    // First non-empty line is expected to be "<date>|<description>".
    private static void parse_date_and_desc (string content,
                                             out string date_part,
                                             out string desc_part)
    {
        date_part = ""; desc_part = "";
        string? line = null;
        foreach (string raw in content.split ("\n")) {
            string l = raw.strip ();
            if (l != "") { line = l; break; }
        }
        if (line == null) return;

        int sep = line.index_of ("|");
        string raw_date = sep >= 0 ? line.substring (0, sep).strip () : "";
        string raw_desc = sep >= 0 ? line.substring (sep + 1).strip () : line;

        date_part = normalize_date (raw_date);
        desc_part = slugify (raw_desc);
    }

    private static string normalize_date (string raw)
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
    private static string slugify (string raw)
    {
        var sb = new StringBuilder ();
        unichar c;
        for (int i = 0; raw.get_next_char (ref i, out c); ) {
            if (c.isalnum () || c == ' ' || c == '-' || c == '_')
                sb.append_unichar (c);
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
        if (s.length > MAX_DESC_LEN)
            s = s.substring (0, MAX_DESC_LEN).strip ();
        return s;
    }
}
