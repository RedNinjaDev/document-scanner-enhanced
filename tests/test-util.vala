// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * Helpers shared by the tests: synthetic scanned pages drawn with Cairo, so
 * the tests need neither a scanner nor sample images on disk.
 */

namespace TestUtil
{
    public delegate void Painter (Cairo.Context cr);

    // Draws a page with paint and returns it as a scanned Page, in colour
    // (three channels) or greyscale (one channel), 8 bits per sample.
    public Page draw_page (int width, int height, bool color, Painter paint)
    {
        var surface = new Cairo.ImageSurface (Cairo.Format.RGB24, width, height);
        var cr = new Cairo.Context (surface);
        paint (cr);
        surface.flush ();

        unowned uchar[] data = surface.get_data ();
        int stride = surface.get_stride ();
        int channels = color ? 3 : 1;
        var pixels = new uchar[width * height * channels];
        for (int y = 0; y < height; y++)
        {
            for (int x = 0; x < width; x++)
            {
                // RGB24 stores each pixel as a native-endian 0x00RRGGBB word.
                uint32 v = *((uint32*) (&data[y * stride + x * 4]));
                uchar r = (uchar) ((v >> 16) & 0xFF);
                uchar g = (uchar) ((v >> 8) & 0xFF);
                uchar b = (uchar) (v & 0xFF);
                int o = (y * width + x) * channels;
                if (color)
                {
                    pixels[o] = r;
                    pixels[o + 1] = g;
                    pixels[o + 2] = b;
                }
                else
                {
                    pixels[o] = (uchar) ((r * 77 + g * 150 + b * 29) >> 8);
                }
            }
        }

        return new Page.from_data (width, height, width * channels, channels, 8, 150,
                                   ScanDirection.TOP_TO_BOTTOM, null, pixels,
                                   false, null, 0, 0, 0, 0);
    }

    // A sheet of paper lying on the scanner bed, as a sheet-fed scanner with
    // a dark backing sees it. The paper carries lines of "text" and,
    // optionally, a dark banner across its full width, like a letterhead.
    public class PaperScan
    {
        public int width = 1200;
        public int height = 1800;
        public double bed = 0.08;          // bed brightness, 0 black .. 1 white
        public int paper_x = 150;
        public int paper_y = 200;
        public int paper_width = 900;
        public int paper_height = 1300;
        public double angle_degrees = 0;   // clockwise rotation of the paper
        public bool banner = false;
        public bool color = true;

        public Page draw ()
        {
            return draw_page (width, height, color, (cr) =>
            {
                cr.set_source_rgb (bed, bed, bed);
                cr.paint ();

                cr.translate (paper_x + paper_width / 2.0, paper_y + paper_height / 2.0);
                cr.rotate (angle_degrees * Math.PI / 180.0);
                cr.translate (-paper_width / 2.0, -paper_height / 2.0);

                cr.set_source_rgb (1, 1, 1);
                cr.rectangle (0, 0, paper_width, paper_height);
                cr.fill ();

                cr.set_source_rgb (0.15, 0.15, 0.15);
                for (int i = 0; i < 20; i++)
                {
                    double line_width = paper_width * (0.5 + 0.3 * ((i * 7) % 5) / 4.0);
                    cr.rectangle (paper_width * 0.1, paper_height * (0.25 + i * 0.035),
                                  line_width, paper_height * 0.012);
                }
                cr.fill ();

                if (banner)
                {
                    cr.set_source_rgb (0.1, 0.1, 0.3);
                    cr.rectangle (0, paper_height * 0.12, paper_width, paper_height * 0.03);
                    cr.fill ();
                }
            });
        }
    }

    // A white page with lines of real text on it, for the auto-naming tests.
    // Each line is "size|text"; a size starting with "b" is bold.
    public Page text_document (string[] lines, int width = 1275, int height = 1650)
    {
        return draw_page (width, height, true, (cr) =>
        {
            cr.set_source_rgb (1, 1, 1);
            cr.paint ();
            cr.set_source_rgb (0, 0, 0);

            double y = 150;
            foreach (var line in lines)
            {
                var parts = line.split ("|", 2);
                bool bold = parts[0].has_prefix ("b");
                double size = double.parse (bold ? parts[0].substring (1) : parts[0]);
                cr.select_font_face ("DejaVu Sans", Cairo.FontSlant.NORMAL,
                                     bold ? Cairo.FontWeight.BOLD : Cairo.FontWeight.NORMAL);
                cr.set_font_size (size);
                y += size * 1.2;
                cr.move_to (110, y);
                cr.show_text (parts[1]);
                y += size * 0.9;
            }
        });
    }

    // Runs AutoNamer.suggest_filename to completion and returns its answer.
    public string? suggest (Page page, string endpoint, string model,
                            string api_key = "", string extension = "pdf")
    {
        var loop = new MainLoop ();
        string? result = null;
        AutoNamer.suggest_filename.begin (page, endpoint, api_key, model, extension, (obj, res) =>
        {
            result = AutoNamer.suggest_filename.end (res);
            loop.quit ();
        });
        loop.run ();
        return result;
    }

    // Luminance of one pixel of a page.
    public int luminance_at (Page page, int x, int y)
    {
        var rgb = new uchar[3];
        page.get_pixel_rgb (x, y, rgb);
        return (rgb[0] * 77 + rgb[1] * 150 + rgb[2] * 29) >> 8;
    }
}
