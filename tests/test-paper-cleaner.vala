// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * Unit tests for the paper background cleaning applied when saving.
 */

void test_black_stays_black ()
{
    assert_cmpuint (PaperCleaner.map_value (0), CompareOperator.EQ, 0);
}

void test_near_white_becomes_white ()
{
    for (var v = PaperCleaner.WHITE_POINT; v <= 255; v++)
        assert_cmpuint (PaperCleaner.map_value ((uint8) v), CompareOperator.EQ, 255);
}

void test_curve_is_monotonic ()
{
    for (var v = 1; v < 256; v++)
        assert_true (PaperCleaner.map_value ((uint8) v) >= PaperCleaner.map_value ((uint8) (v - 1)));
}

// Light pencil sits around mid-grey; it must not come out lighter than it
// went in, or handwriting fades.
void test_pencil_does_not_fade ()
{
    for (var v = 60; v <= 180; v++)
        assert_true (PaperCleaner.map_value ((uint8) v) <= v);
}

// A pixbuf whose rowstride is padded past the last pixel, so the test also
// checks that clean () stays within each row.
Gdk.Pixbuf make_pixbuf (bool has_alpha, int width, int height)
{
    var image = new Gdk.Pixbuf (Gdk.Colorspace.RGB, has_alpha, 8, width, height);
    assert_true (image.rowstride >= width * image.n_channels);
    return image;
}

void set_pixel (Gdk.Pixbuf image, int x, int y, uint8[] values)
{
    unowned uint8[] pixels = image.get_pixels ();
    var o = y * image.rowstride + x * image.n_channels;
    for (var c = 0; c < values.length; c++)
        pixels[o + c] = values[c];
}

uint8 get_channel (Gdk.Pixbuf image, int x, int y, int c)
{
    unowned uint8[] pixels = image.get_pixels ();
    return pixels[y * image.rowstride + x * image.n_channels + c];
}

void test_clean_rgb ()
{
    var image = make_pixbuf (false, 3, 2);
    set_pixel (image, 0, 0, { 245, 241, 250 });  // grainy paper
    set_pixel (image, 1, 0, { 0, 0, 0 });        // printed text
    set_pixel (image, 2, 0, { 120, 160, 200 });  // blue table fill
    set_pixel (image, 0, 1, { 128, 128, 128 });  // pencil
    set_pixel (image, 1, 1, { 255, 255, 255 });
    set_pixel (image, 2, 1, { 230, 230, 230 });

    PaperCleaner.clean (image);

    for (var c = 0; c < 3; c++)
    {
        assert_cmpuint (get_channel (image, 0, 0, c), CompareOperator.EQ, 255);
        assert_cmpuint (get_channel (image, 1, 0, c), CompareOperator.EQ, 0);
        assert_cmpuint (get_channel (image, 1, 1, c), CompareOperator.EQ, 255);
    }
    assert_cmpuint (get_channel (image, 2, 0, 0), CompareOperator.EQ, PaperCleaner.map_value (120));
    assert_cmpuint (get_channel (image, 2, 0, 1), CompareOperator.EQ, PaperCleaner.map_value (160));
    assert_cmpuint (get_channel (image, 2, 0, 2), CompareOperator.EQ, PaperCleaner.map_value (200));
    assert_cmpuint (get_channel (image, 0, 1, 0), CompareOperator.LE, 128);
    assert_cmpuint (get_channel (image, 2, 1, 0), CompareOperator.EQ, PaperCleaner.map_value (230));
}

void test_clean_leaves_alpha ()
{
    var image = make_pixbuf (true, 2, 1);
    set_pixel (image, 0, 0, { 245, 245, 245, 7 });
    set_pixel (image, 1, 0, { 0, 0, 0, 250 });

    PaperCleaner.clean (image);

    assert_cmpuint (get_channel (image, 0, 0, 0), CompareOperator.EQ, 255);
    assert_cmpuint (get_channel (image, 0, 0, 3), CompareOperator.EQ, 7);
    assert_cmpuint (get_channel (image, 1, 0, 3), CompareOperator.EQ, 250);
}

int main (string[] args)
{
    Test.init (ref args);
    Test.add_func ("/paper-cleaner/black-stays-black", test_black_stays_black);
    Test.add_func ("/paper-cleaner/near-white-becomes-white", test_near_white_becomes_white);
    Test.add_func ("/paper-cleaner/curve-is-monotonic", test_curve_is_monotonic);
    Test.add_func ("/paper-cleaner/pencil-does-not-fade", test_pencil_does_not_fade);
    Test.add_func ("/paper-cleaner/clean-rgb", test_clean_rgb);
    Test.add_func ("/paper-cleaner/clean-leaves-alpha", test_clean_leaves_alpha);
    return Test.run ();
}
