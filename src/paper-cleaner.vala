// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * Cleans up the paper background of a scanned page before it is saved.
 *
 * Scanned paper is rarely pure white: it carries a faint tint and a grainy
 * texture that JPEG spends most of its bytes reproducing. Pushing near-white
 * pixels to pure white removes that grain, and darkening the midtones a
 * little keeps light pencil from fading along with it. On a typical colour
 * form this makes the saved file 15-20% smaller with no visible loss
 * to print or handwriting. Photos and tinted paper lose their lightest
 * shades, which is why this is a setting.
 */

namespace PaperCleaner
{
    // Channel values at or above this become pure white (about 94%).
    public const int WHITE_POINT = 240;

    // Exponent applied after stretching to the white point; above 1 darkens
    // midtones. Matches ImageMagick's "-level 0%,94%,0.8".
    public const double MIDTONE_EXPONENT = 1.25;

    // Maps a single channel value through the cleaning curve.
    public uint8 map_value (uint8 v)
    {
        var x = double.min ((double) v / WHITE_POINT, 1.0);
        return (uint8) Math.round (255.0 * Math.pow (x, MIDTONE_EXPONENT));
    }

    // Cleans an 8-bit RGB(A) pixbuf in place. The alpha channel, if any, is
    // left untouched.
    public void clean (Gdk.Pixbuf image)
    {
        var table = new uint8[256];
        for (var v = 0; v < 256; v++)
            table[v] = map_value ((uint8) v);

        unowned uint8[] pixels = image.get_pixels ();
        var width = image.width;
        var height = image.height;
        var rowstride = image.rowstride;
        var n_channels = image.n_channels;
        var color_channels = image.has_alpha ? n_channels - 1 : n_channels;

        for (var y = 0; y < height; y++)
        {
            var offset = y * rowstride;
            for (var x = 0; x < width; x++)
            {
                var o = offset + x * n_channels;
                for (var c = 0; c < color_channels; c++)
                    pixels[o + c] = table[pixels[o + c]];
            }
        }
    }
}
