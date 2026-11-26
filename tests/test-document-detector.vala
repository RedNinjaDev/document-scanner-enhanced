// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * Unit tests for document detection, straightening and the auto-crop /
 * auto-straighten step the app runs on each new scan.
 */

using TestUtil;

// Allowed error, in pixels of a 1200x1800 scan, for a detected paper edge.
// Detection works on a downsampled copy and insets the crop slightly.
const int EDGE_TOLERANCE = 20;

void assert_near (int actual, int expected, int tolerance, string what)
{
    if ((actual - expected).abs () > tolerance)
        error ("%s: expected %d (±%d), got %d", what, expected, tolerance, actual);
}

void assert_crop_matches_paper (int x, int y, int w, int h, PaperScan scan)
{
    assert_near (x, scan.paper_x, EDGE_TOLERANCE, "left edge");
    assert_near (y, scan.paper_y, EDGE_TOLERANCE, "top edge");
    assert_near (x + w, scan.paper_x + scan.paper_width, EDGE_TOLERANCE, "right edge");
    assert_near (y + h, scan.paper_y + scan.paper_height, EDGE_TOLERANCE, "bottom edge");
}

void test_finds_paper_on_dark_bed ()
{
    var scan = new PaperScan ();
    var r = DocumentDetector.detect (scan.draw (), false);
    assert_nonnull (r);
    assert_true (r.found_document);
    assert_crop_matches_paper (r.crop_x, r.crop_y, r.crop_width, r.crop_height, scan);
    assert_cmpfloat (r.skew_degrees, CompareOperator.EQ, 0);
}

void test_crop_sits_inside_paper ()
{
    var scan = new PaperScan ();
    var r = DocumentDetector.detect (scan.draw (), false);
    assert_true (r.crop_x >= scan.paper_x);
    assert_true (r.crop_y >= scan.paper_y);
    assert_true (r.crop_x + r.crop_width <= scan.paper_x + scan.paper_width);
    assert_true (r.crop_y + r.crop_height <= scan.paper_y + scan.paper_height);
}

void test_banner_does_not_split_paper ()
{
    var scan = new PaperScan () { banner = true };
    var r = DocumentDetector.detect (scan.draw (), false);
    assert_true (r.found_document);
    assert_crop_matches_paper (r.crop_x, r.crop_y, r.crop_width, r.crop_height, scan);
}

void test_greyscale_scan ()
{
    var scan = new PaperScan () { color = false };
    var r = DocumentDetector.detect (scan.draw (), false);
    assert_true (r.found_document);
    assert_crop_matches_paper (r.crop_x, r.crop_y, r.crop_width, r.crop_height, scan);
}

void test_background_luminance_is_bed ()
{
    var scan = new PaperScan () { bed = 0.2 };
    var r = DocumentDetector.detect (scan.draw (), false);
    assert_near (r.background_luminance, 51, 5, "background luminance");
}

void test_white_lid_is_left_alone ()
{
    // A flatbed with a white lid: the paper is indistinguishable from the bed.
    var scan = new PaperScan () { bed = 1.0 };
    var page = scan.draw ();
    var r = DocumentDetector.detect (page, false);
    assert_nonnull (r);
    assert_false (r.found_document);
}

void test_white_lid_tilted_page_is_straightened_with_white_corners ()
{
    // With no bed to see, skew comes from the lines of text, and the corners
    // revealed by rotating are filled to match the paper, not black.
    var page = new PaperScan () { bed = 1.0, angle_degrees = 4 }.draw ();
    var r = DocumentDetector.detect (page, true);
    assert_false (r.found_document);
    assert_cmpfloat (Math.fabs (Math.fabs (r.skew_degrees) - 4), CompareOperator.LT, 0.3);
    assert_cmpint (r.background_luminance, CompareOperator.GT, 200);

    DocumentDetector.deskew (page, r.skew_degrees, r.background_luminance);
    assert_cmpint (luminance_at (page, 0, 0), CompareOperator.GT, 200);
    assert_cmpint (luminance_at (page, page.width - 1, page.height - 1), CompareOperator.GT, 200);
}

void test_empty_bed_finds_nothing ()
{
    var page = draw_page (1200, 1800, true, (cr) =>
    {
        cr.set_source_rgb (0.08, 0.08, 0.08);
        cr.paint ();
    });
    var r = DocumentDetector.detect (page, true);
    assert_nonnull (r);
    assert_false (r.found_document);
}

void test_tiny_page_is_not_analysed ()
{
    var page = draw_page (20, 20, true, (cr) => { cr.paint (); });
    assert_null (DocumentDetector.detect (page, true));
}

void test_page_without_data_is_not_analysed ()
{
    var page = new Page (1200, 1800, 150, ScanDirection.TOP_TO_BOTTOM);
    assert_null (DocumentDetector.detect (page, true));
}

void test_straight_paper_has_no_skew ()
{
    var r = DocumentDetector.detect (new PaperScan ().draw (), true);
    assert_cmpfloat (Math.fabs (r.skew_degrees), CompareOperator.LT, 0.15);
}

void check_skew_is_measured_and_corrected (double angle)
{
    var page = new PaperScan () { angle_degrees = angle }.draw ();
    var r = DocumentDetector.detect (page, true);
    assert_true (r.found_document);
    // The search steps in 0.1° and the page then needs to be within one step.
    if (Math.fabs (Math.fabs (r.skew_degrees) - Math.fabs (angle)) > 0.15)
        error ("paper turned %.1f°, measured skew %.2f°", angle, r.skew_degrees);

    DocumentDetector.deskew (page, r.skew_degrees, r.background_luminance);
    var after = DocumentDetector.detect (page, true);
    if (Math.fabs (after.skew_degrees) > 0.15)
        error ("paper turned %.1f° is still %.2f° off after straightening", angle, after.skew_degrees);
}

void test_skew_clockwise ()
{
    check_skew_is_measured_and_corrected (4.0);
}

void test_skew_anticlockwise ()
{
    check_skew_is_measured_and_corrected (-2.5);
}

void test_skew_between_search_steps ()
{
    check_skew_is_measured_and_corrected (6.33);
}

void test_skew_near_limit ()
{
    check_skew_is_measured_and_corrected (8.0);
}

void test_deskew_fills_corners_with_bed ()
{
    var page = new PaperScan () { angle_degrees = 5 }.draw ();
    var r = DocumentDetector.detect (page, true);
    DocumentDetector.deskew (page, r.skew_degrees, r.background_luminance);
    // The corners revealed by rotating the image match the dark bed, so they
    // don't show up as bright triangles or get mistaken for paper.
    assert_cmpint (luminance_at (page, 0, 0), CompareOperator.LT, 40);
    assert_cmpint (luminance_at (page, page.width - 1, page.height - 1), CompareOperator.LT, 40);
}

void test_deskew_grows_canvas_and_keeps_channels ()
{
    var page = new PaperScan () { color = false }.draw ();
    DocumentDetector.deskew (page, 5.0, 20);
    assert_cmpint (page.width, CompareOperator.GT, 1200);
    assert_cmpint (page.height, CompareOperator.GT, 1800);
    assert_false (page.is_color);
}

void test_deskew_ignores_tiny_angles ()
{
    var page = new PaperScan ().draw ();
    DocumentDetector.deskew (page, 0.01, 20);
    assert_cmpint (page.width, CompareOperator.EQ, 1200);
    assert_cmpint (page.height, CompareOperator.EQ, 1800);
}

void test_auto_process_off_changes_nothing ()
{
    var page = new PaperScan () { angle_degrees = 4 }.draw ();
    assert_null (DocumentDetector.auto_process (page, false, false));
    assert_false (page.has_crop);
    assert_cmpint (page.width, CompareOperator.EQ, 1200);
}

void test_auto_process_crop_only ()
{
    var scan = new PaperScan ();
    var page = scan.draw ();
    var r = DocumentDetector.auto_process (page, true, false);
    assert_true (r.found_document);
    assert_true (page.has_crop);
    assert_cmpint (page.width, CompareOperator.EQ, 1200);
    assert_crop_matches_paper (page.crop_x, page.crop_y, page.crop_width, page.crop_height, scan);
}

void test_auto_process_crop_leaves_tilted_page_unrotated ()
{
    var page = new PaperScan () { angle_degrees = 4 }.draw ();
    DocumentDetector.auto_process (page, true, false);
    assert_true (page.has_crop);
    assert_cmpint (page.width, CompareOperator.EQ, 1200);
    assert_cmpint (page.height, CompareOperator.EQ, 1800);
}

void test_auto_process_straighten_only ()
{
    var page = new PaperScan () { angle_degrees = 4 }.draw ();
    DocumentDetector.auto_process (page, false, true);
    assert_false (page.has_crop);
    assert_cmpint (page.width, CompareOperator.GT, 1200);
    var after = DocumentDetector.detect (page, true);
    assert_cmpfloat (Math.fabs (after.skew_degrees), CompareOperator.LT, 0.15);
}

void test_auto_process_straighten_and_crop ()
{
    var scan = new PaperScan () { angle_degrees = -3 };
    var page = scan.draw ();
    DocumentDetector.auto_process (page, true, true);
    assert_true (page.has_crop);
    // Once straight, the crop is the size of the paper itself.
    assert_near (page.crop_width, scan.paper_width, 2 * EDGE_TOLERANCE, "crop width");
    assert_near (page.crop_height, scan.paper_height, 2 * EDGE_TOLERANCE, "crop height");
}

void test_auto_process_straight_page_is_only_cropped ()
{
    var page = new PaperScan ().draw ();
    DocumentDetector.auto_process (page, true, true);
    assert_true (page.has_crop);
    assert_cmpint (page.width, CompareOperator.EQ, 1200);
}

void test_auto_process_white_lid_is_not_cropped ()
{
    var page = new PaperScan () { bed = 1.0 }.draw ();
    DocumentDetector.auto_process (page, true, true);
    assert_false (page.has_crop);
    assert_cmpint (page.width, CompareOperator.EQ, 1200);
}

int main (string[] args)
{
    Test.init (ref args);
    Test.add_func ("/detector/finds-paper-on-dark-bed", test_finds_paper_on_dark_bed);
    Test.add_func ("/detector/crop-sits-inside-paper", test_crop_sits_inside_paper);
    Test.add_func ("/detector/banner-does-not-split-paper", test_banner_does_not_split_paper);
    Test.add_func ("/detector/greyscale-scan", test_greyscale_scan);
    Test.add_func ("/detector/background-luminance-is-bed", test_background_luminance_is_bed);
    Test.add_func ("/detector/white-lid-is-left-alone", test_white_lid_is_left_alone);
    Test.add_func ("/detector/white-lid-tilted-page-is-straightened-with-white-corners", test_white_lid_tilted_page_is_straightened_with_white_corners);
    Test.add_func ("/detector/empty-bed-finds-nothing", test_empty_bed_finds_nothing);
    Test.add_func ("/detector/tiny-page-is-not-analysed", test_tiny_page_is_not_analysed);
    Test.add_func ("/detector/page-without-data-is-not-analysed", test_page_without_data_is_not_analysed);
    Test.add_func ("/skew/straight-paper-has-no-skew", test_straight_paper_has_no_skew);
    Test.add_func ("/skew/clockwise", test_skew_clockwise);
    Test.add_func ("/skew/anticlockwise", test_skew_anticlockwise);
    Test.add_func ("/skew/between-search-steps", test_skew_between_search_steps);
    Test.add_func ("/skew/near-limit", test_skew_near_limit);
    Test.add_func ("/deskew/fills-corners-with-bed", test_deskew_fills_corners_with_bed);
    Test.add_func ("/deskew/grows-canvas-and-keeps-channels", test_deskew_grows_canvas_and_keeps_channels);
    Test.add_func ("/deskew/ignores-tiny-angles", test_deskew_ignores_tiny_angles);
    Test.add_func ("/auto-process/off-changes-nothing", test_auto_process_off_changes_nothing);
    Test.add_func ("/auto-process/crop-only", test_auto_process_crop_only);
    Test.add_func ("/auto-process/crop-leaves-tilted-page-unrotated", test_auto_process_crop_leaves_tilted_page_unrotated);
    Test.add_func ("/auto-process/straighten-only", test_auto_process_straighten_only);
    Test.add_func ("/auto-process/straighten-and-crop", test_auto_process_straighten_and_crop);
    Test.add_func ("/auto-process/straight-page-is-only-cropped", test_auto_process_straight_page_is_only_cropped);
    Test.add_func ("/auto-process/white-lid-is-not-cropped", test_auto_process_white_lid_is_not_cropped);
    return Test.run ();
}
