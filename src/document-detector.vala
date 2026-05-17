// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * Copyright (C) 2026 Document Scanner Enhanced contributors
 *
 * Auto-crop and auto-straighten detection. Pure analysis: takes a Page,
 * returns crop rectangle in page coordinates and an estimated skew angle.
 * The caller decides what to do with the result.
 *
 * Assumes the scanner bed reads darker than the document. Optimized for the
 * common case of white letter-sized pages on a black flatbed, but works for
 * any "light document on dark background" combination.
 */

public class DocumentDetectionResult : Object
{
    /* True if a plausible document region was found. */
    public bool found_document;

    /* Page-coord bounding rectangle of the detected document. */
    public int crop_x;
    public int crop_y;
    public int crop_width;
    public int crop_height;

    /* Estimated page skew in degrees in page coords. Positive = the
     * document content tilts clockwise relative to the page axes, so
     * rotating the page counter-clockwise by this value straightens it. */
    public double skew_degrees;

    /* Fraction of the analysed image that was classified as "document".
     * Useful as a sanity check; very small or very large values usually
     * mean the detector did not find a real document. */
    public double document_fraction;
}

public class DocumentDetector
{
    /* Long-side pixel count we downsample the page to before analysis.
     * 600 is plenty for a stable bounding box / skew estimate and keeps
     * the cost trivial even on a 600dpi letter scan. */
    private const int ANALYSIS_LONG_SIDE = 600;

    /* Minimum document area as a fraction of the analysed image — below
     * this we assume nothing was on the bed and fall back to no crop. */
    private const double MIN_DOCUMENT_FRACTION = 0.05;

    /* Maximum document area as a fraction of the analysed image — above
     * this the bed isn't visible (e.g. a postcard-sized scan filling the
     * frame). The detection is meaningless then, so don't crop. */
    private const double MAX_DOCUMENT_FRACTION = 0.99;

    /* Skew search bounds. We only correct mild skew — anything bigger
     * is almost certainly the user wanting a 90° rotate, not a deskew. */
    private const double SKEW_RANGE_DEGREES = 10.0;

    /* Padding (in detected-document fraction) added on each side of the
     * crop, so we don't shave off the document's actual edge if the
     * threshold trimmed one row of pixels too aggressively. */
    private const double CROP_PADDING_FRACTION = 0.005;

    /* Build a downsampled luminance buffer of the page (page-coord).
     * Samples are pulled through Page.get_pixel_rgb so scan_direction
     * (the user's rotation) is honoured. */
    private static uint8[] downsample_luminance (Page page,
                                                 out int out_w,
                                                 out int out_h,
                                                 out int step)
    {
        int page_w = page.width;
        int page_h = page.height;
        int long_side = int.max (page_w, page_h);

        step = int.max (1, long_side / ANALYSIS_LONG_SIDE);
        out_w = page_w / step;
        out_h = page_h / step;

        var buf = new uint8[out_w * out_h];
        uchar[] rgb = new uchar[3];
        for (int y = 0; y < out_h; y++)
        {
            int sy = y * step;
            int row = y * out_w;
            for (int x = 0; x < out_w; x++)
            {
                page.get_pixel_rgb (x * step, sy, rgb);
                // Rec. 601 luma — fast integer approximation.
                buf[row + x] = (uchar) ((rgb[0] * 77 + rgb[1] * 150 + rgb[2] * 29) >> 8);
            }
        }
        return buf;
    }

    /* Otsu's method on an 8-bit luminance buffer. Returns the threshold
     * that maximises between-class variance. */
    private static int otsu_threshold (uint8[] buf)
    {
        int[] hist = new int[256];
        foreach (uint8 v in buf)
            hist[v]++;

        int total = buf.length;
        double sum_all = 0;
        for (int t = 0; t < 256; t++)
            sum_all += t * hist[t];

        double sum_bg = 0;
        int w_bg = 0;
        double max_var = -1;
        int best_t = 127;

        for (int t = 0; t < 256; t++)
        {
            w_bg += hist[t];
            if (w_bg == 0) continue;
            int w_fg = total - w_bg;
            if (w_fg == 0) break;

            sum_bg += t * hist[t];
            double mean_bg = sum_bg / w_bg;
            double mean_fg = (sum_all - sum_bg) / w_fg;
            double between = (double) w_bg * w_fg * (mean_bg - mean_fg) * (mean_bg - mean_fg);

            if (between > max_var)
            {
                max_var = between;
                best_t = t;
            }
        }
        return best_t;
    }

    /* Pack a thresholded mask into a 0/1 byte buffer where 1 = document
     * (the brighter region, since we assume light page on dark bed). */
    private static uint8[] threshold_mask (uint8[] lum, int threshold)
    {
        var m = new uint8[lum.length];
        for (int i = 0; i < lum.length; i++)
            m[i] = lum[i] > threshold ? 1 : 0;
        return m;
    }

    /* Find the bounding rectangle of the document by projecting the mask
     * onto each axis and trimming until the projection cross a fraction
     * of the maximum. This tolerates isolated speckles of misclassified
     * pixels (dust, edge noise) without needing morphology. */
    private static bool bounding_box (uint8[] mask, int w, int h,
                                      out int x0, out int y0,
                                      out int x1, out int y1)
    {
        int[] col_sum = new int[w];
        int[] row_sum = new int[h];

        for (int y = 0; y < h; y++)
        {
            int row = y * w;
            int rs = 0;
            for (int x = 0; x < w; x++)
            {
                int v = mask[row + x];
                col_sum[x] += v;
                rs += v;
            }
            row_sum[y] = rs;
        }

        int max_col = 0;
        for (int x = 0; x < w; x++) if (col_sum[x] > max_col) max_col = col_sum[x];
        int max_row = 0;
        for (int y = 0; y < h; y++) if (row_sum[y] > max_row) max_row = row_sum[y];

        // 10% of the maximum projection is the cut-off — it excludes
        // isolated noise but keeps real document rows even when a row
        // contains mostly black text.
        int col_cut = (int) (max_col * 0.10);
        int row_cut = (int) (max_row * 0.10);

        x0 = -1; x1 = -1; y0 = -1; y1 = -1;
        for (int x = 0; x < w; x++)
            if (col_sum[x] > col_cut) { x0 = x; break; }
        for (int x = w - 1; x >= 0; x--)
            if (col_sum[x] > col_cut) { x1 = x; break; }
        for (int y = 0; y < h; y++)
            if (row_sum[y] > row_cut) { y0 = y; break; }
        for (int y = h - 1; y >= 0; y--)
            if (row_sum[y] > row_cut) { y1 = y; break; }

        return x0 >= 0 && y0 >= 0 && x1 > x0 && y1 > y0;
    }

    /* Variance of the row-sum projection of the mask after rotating it
     * conceptually by `angle_deg` (we don't actually rotate — we shear
     * each row's mapping into the destination row). This is the standard
     * projection-profile skew metric. Higher = better aligned. */
    private static double projection_variance (uint8[] mask, int w, int h, double angle_deg)
    {
        double angle_rad = angle_deg * Math.PI / 180.0;
        double tan_a = Math.tan (angle_rad);

        // After rotation by -angle_deg about the image centre, a row r in the
        // mask projects to a row r' = r + (x - cx) * tan_a (approximation,
        // valid for small angles). Bin into an integer row index.
        int n_bins = h + (int) (Math.fabs (tan_a) * w) + 2;
        int[] proj = new int[n_bins];

        double cx = w / 2.0;
        for (int y = 0; y < h; y++)
        {
            int row = y * w;
            for (int x = 0; x < w; x++)
            {
                if (mask[row + x] == 0) continue;
                int yp = y + (int) ((x - cx) * tan_a) + n_bins / 4;
                if (yp >= 0 && yp < n_bins)
                    proj[yp]++;
            }
        }

        double sum = 0;
        int filled = 0;
        for (int i = 0; i < n_bins; i++)
            if (proj[i] > 0) { sum += proj[i]; filled++; }
        if (filled == 0) return 0;
        double mean = sum / filled;
        double var = 0;
        for (int i = 0; i < n_bins; i++)
            if (proj[i] > 0)
            {
                double d = proj[i] - mean;
                var += d * d;
            }
        return var / filled;
    }

    /* Estimate skew by scanning angles in two passes (coarse 1°, then
     * fine 0.1° near the peak) and picking the angle with the highest
     * projection-profile variance. */
    private static double estimate_skew (uint8[] mask, int w, int h)
    {
        double best_angle = 0;
        double best_var = projection_variance (mask, w, h, 0);

        for (double a = -SKEW_RANGE_DEGREES; a <= SKEW_RANGE_DEGREES; a += 1.0)
        {
            double v = projection_variance (mask, w, h, a);
            if (v > best_var) { best_var = v; best_angle = a; }
        }

        double coarse = best_angle;
        for (double a = coarse - 0.9; a <= coarse + 0.9; a += 0.1)
        {
            double v = projection_variance (mask, w, h, a);
            if (v > best_var) { best_var = v; best_angle = a; }
        }
        return best_angle;
    }

    /* Public entry point. Analyse `page` and return a detection result.
     * `want_skew` controls whether to spend time estimating skew. */
    public static DocumentDetectionResult? detect (Page page, bool want_skew)
    {
        if (!page.has_data)
            return null;
        if (page.width < 32 || page.height < 32)
            return null;

        int ds_w, ds_h, step;
        uint8[] lum = downsample_luminance (page, out ds_w, out ds_h, out step);
        if (ds_w < 16 || ds_h < 16)
            return null;

        int threshold = otsu_threshold (lum);

        // Guard against pages where Otsu can't find a real bimodal split
        // (e.g. uniform bed with no document). Demand a meaningful gap
        // between the threshold and absolute black.
        if (threshold < 32)
        {
            debug ("DocumentDetector: threshold %d too low; treating as no document", threshold);
            var r = new DocumentDetectionResult ();
            r.found_document = false;
            return r;
        }

        uint8[] mask = threshold_mask (lum, threshold);

        int total_doc = 0;
        foreach (uint8 v in mask) if (v != 0) total_doc++;
        double frac = (double) total_doc / mask.length;

        var result = new DocumentDetectionResult ();
        result.document_fraction = frac;

        if (frac < MIN_DOCUMENT_FRACTION || frac > MAX_DOCUMENT_FRACTION)
        {
            debug ("DocumentDetector: document fraction %.3f out of range, skipping crop", frac);
            result.found_document = false;
            // Still attempt skew if asked — but on a near-empty mask it's
            // meaningless, so just return zero.
            result.skew_degrees = 0;
            return result;
        }

        int x0, y0, x1, y1;
        if (!bounding_box (mask, ds_w, ds_h, out x0, out y0, out x1, out y1))
        {
            result.found_document = false;
            return result;
        }

        // Map bounding box back to page coordinates and apply a small
        // safety padding so we don't clip text right at the page edge.
        int box_w_ds = x1 - x0 + 1;
        int box_h_ds = y1 - y0 + 1;
        int pad_x = (int) (box_w_ds * CROP_PADDING_FRACTION);
        int pad_y = (int) (box_h_ds * CROP_PADDING_FRACTION);

        int page_x0 = int.max (0, (x0 - pad_x) * step);
        int page_y0 = int.max (0, (y0 - pad_y) * step);
        int page_x1 = int.min (page.width - 1, (x1 + pad_x) * step);
        int page_y1 = int.min (page.height - 1, (y1 + pad_y) * step);

        result.found_document = true;
        result.crop_x = page_x0;
        result.crop_y = page_y0;
        result.crop_width = page_x1 - page_x0 + 1;
        result.crop_height = page_y1 - page_y0 + 1;

        if (want_skew)
            result.skew_degrees = estimate_skew (mask, ds_w, ds_h);
        else
            result.skew_degrees = 0;

        debug ("DocumentDetector: threshold=%d frac=%.3f bbox=(%d,%d %dx%d) skew=%.2f°",
               threshold, frac,
               result.crop_x, result.crop_y, result.crop_width, result.crop_height,
               result.skew_degrees);

        return result;
    }

    /* Rotate the page's pixel buffer in place by `degrees` (counter-
     * clockwise positive), producing a new buffer that exactly fits
     * the rotated content. Source pixels outside the rotated frame
     * become white. The result is written back via Page.replace_image
     * with depth 8 and the source's color/grayscale-ness preserved.
     *
     * Small skew angles only — caller is expected to clamp.
     */
    public static void deskew (Page page, double degrees)
    {
        if (Math.fabs (degrees) < 0.05)
            return;

        int src_w = page.width;
        int src_h = page.height;
        bool color = page.is_color;
        int channels = color ? 3 : 1;

        double angle_rad = degrees * Math.PI / 180.0;
        double cos_a = Math.cos (angle_rad);
        double sin_a = Math.sin (angle_rad);

        int dst_w = (int) (Math.fabs (src_w * cos_a) + Math.fabs (src_h * sin_a) + 0.5);
        int dst_h = (int) (Math.fabs (src_w * sin_a) + Math.fabs (src_h * cos_a) + 0.5);

        var dst = new uchar[dst_w * dst_h * channels];

        double scx = src_w / 2.0;
        double scy = src_h / 2.0;
        double dcx = dst_w / 2.0;
        double dcy = dst_h / 2.0;

        uchar[] sample = new uchar[3];

        for (int dy = 0; dy < dst_h; dy++)
        {
            double oy = dy - dcy;
            for (int dx = 0; dx < dst_w; dx++)
            {
                double ox = dx - dcx;

                // Inverse rotation: source point that maps to (dx,dy)
                double sx = ox * cos_a + oy * sin_a + scx;
                double sy = -ox * sin_a + oy * cos_a + scy;

                int x0 = (int) Math.floor (sx);
                int y0 = (int) Math.floor (sy);
                int x1 = x0 + 1;
                int y1 = y0 + 1;
                double fx = sx - x0;
                double fy = sy - y0;

                // Bilinear sample of 4 neighbours. Out-of-range neighbours
                // contribute white so the corners outside the source are
                // padded with white instead of black.
                int r = 0, g = 0, b = 0;
                for (int j = 0; j < 2; j++)
                {
                    int yy = j == 0 ? y0 : y1;
                    double wy = j == 0 ? (1 - fy) : fy;
                    for (int i = 0; i < 2; i++)
                    {
                        int xx = i == 0 ? x0 : x1;
                        double wx = i == 0 ? (1 - fx) : fx;
                        double w = wx * wy;

                        if (xx < 0 || yy < 0 || xx >= src_w || yy >= src_h)
                        {
                            r += (int) (255 * w);
                            g += (int) (255 * w);
                            b += (int) (255 * w);
                        }
                        else
                        {
                            page.get_pixel_rgb (xx, yy, sample);
                            r += (int) (sample[0] * w);
                            g += (int) (sample[1] * w);
                            b += (int) (sample[2] * w);
                        }
                    }
                }

                int off = (dy * dst_w + dx) * channels;
                if (color)
                {
                    dst[off + 0] = (uchar) int.min (255, r);
                    dst[off + 1] = (uchar) int.min (255, g);
                    dst[off + 2] = (uchar) int.min (255, b);
                }
                else
                {
                    // Source was grayscale → R, G, B are equal, take any.
                    dst[off] = (uchar) int.min (255, r);
                }
            }
        }

        page.replace_image (dst_w, dst_h, channels, (owned) dst);
    }
}
