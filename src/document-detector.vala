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

public class DocumentDetectionResult : Object
{
    public bool found_document;
    public int crop_x;
    public int crop_y;
    public int crop_width;
    public int crop_height;
    public double document_fraction;
}

public class DocumentDetector
{
    private const int ANALYSIS_LONG_SIDE = 600;
    private const double MIN_DOCUMENT_FRACTION = 0.05;
    private const double MAX_DOCUMENT_FRACTION = 0.99;

    // Shrink the detected bbox by this fraction on every side so the
    // returned crop sits just inside the paper edge.
    private const double CROP_INSET_FRACTION = 0.005;

    // Floor for the document/background threshold (0..255). Otsu can drift
    // low on text-heavy pages, classifying middle-gray scanner artefacts
    // (e.g. the DS-720D end-of-sheet calibration strip at ~150) as part
    // of the document. Demanding at least this much luminance keeps those
    // strips out of the mask without rejecting any real paper.
    private const int MIN_DOCUMENT_LUMINANCE = 180;

    // A row (or column) is treated as "page-like" when at least this
    // fraction of its width (or height) is bright in the mask. Higher =
    // tighter band, fewer noisy edge rows included.
    private const double BAND_FILL_FRACTION = 0.20;

    // Maximum dark gap (as a fraction of the perpendicular dimension)
    // that is bridged when both ends are inside a bright band. Keeps
    // the longest-band scan from being split by full-width interior
    // dark features — header bars, ruled lines, banner backgrounds.
    private const double GAP_FILL_FRACTION = 0.05;

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
                buf[row + x] = (uchar) ((rgb[0] * 77 + rgb[1] * 150 + rgb[2] * 29) >> 8);
            }
        }
        return buf;
    }

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

    private static uint8[] threshold_mask (uint8[] lum, int threshold)
    {
        var m = new uint8[lum.length];
        for (int i = 0; i < lum.length; i++)
            m[i] = lum[i] > threshold ? 1 : 0;
        return m;
    }

    // Longest contiguous run of indices where values[i] >= threshold,
    // bridging interior dark gaps of length <= max_gap so that full-
    // width dark features inside a page don't split the band.
    private static void longest_band (int[] values, int len,
                                      int threshold, int max_gap,
                                      out int start, out int end)
    {
        bool[] passed = new bool[len];
        for (int i = 0; i < len; i++)
            passed[i] = values[i] >= threshold;

        int idx = 0;
        while (idx < len)
        {
            if (!passed[idx])
            {
                int j = idx;
                while (j < len && !passed[j]) j++;
                if (idx > 0 && j < len && passed[idx - 1] && passed[j]
                    && (j - idx) <= max_gap)
                {
                    for (int k = idx; k < j; k++) passed[k] = true;
                }
                idx = j;
            }
            else
            {
                idx++;
            }
        }

        start = -1; end = -1;
        int best_start = -1, best_len = 0;
        int cur_start = -1;
        for (int i = 0; i < len; i++)
        {
            if (passed[i])
            {
                if (cur_start == -1) cur_start = i;
            }
            else if (cur_start != -1)
            {
                int run = i - cur_start;
                if (run > best_len) { best_len = run; best_start = cur_start; }
                cur_start = -1;
            }
        }
        if (cur_start != -1)
        {
            int run = len - cur_start;
            if (run > best_len) { best_len = run; best_start = cur_start; }
        }
        if (best_start >= 0)
        {
            start = best_start;
            end = best_start + best_len - 1;
        }
    }

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

        // Use width/height-relative thresholds so the longest band picks
        // the page even when the calibration strip is also "bright": the
        // strip is a thin band so it loses to the page on row-count.
        int col_cut = (int) (h * BAND_FILL_FRACTION);
        int row_cut = (int) (w * BAND_FILL_FRACTION);
        int row_gap = (int) (h * GAP_FILL_FRACTION);
        int col_gap = (int) (w * GAP_FILL_FRACTION);

        longest_band (col_sum, w, col_cut, col_gap, out x0, out x1);
        longest_band (row_sum, h, row_cut, row_gap, out y0, out y1);

        return x0 >= 0 && y0 >= 0 && x1 > x0 && y1 > y0;
    }

    public static DocumentDetectionResult? detect (Page page)
    {
        if (!page.has_data)
            return null;
        if (page.width < 32 || page.height < 32)
            return null;

        int ds_w, ds_h, step;
        uint8[] lum = downsample_luminance (page, out ds_w, out ds_h, out step);
        if (ds_w < 16 || ds_h < 16)
            return null;

        int threshold = int.max (otsu_threshold (lum), MIN_DOCUMENT_LUMINANCE);

        // If we had to clamp the threshold higher than the brightest pixel
        // in the scan there is nothing bright enough to plausibly be paper
        // — fall back to no crop rather than guessing.
        int max_lum = 0;
        foreach (uint8 v in lum) if (v > max_lum) max_lum = v;
        if (max_lum < MIN_DOCUMENT_LUMINANCE)
        {
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
            result.found_document = false;
            return result;
        }

        int x0, y0, x1, y1;
        if (!bounding_box (mask, ds_w, ds_h, out x0, out y0, out x1, out y1))
        {
            result.found_document = false;
            return result;
        }

        int box_w_ds = x1 - x0 + 1;
        int box_h_ds = y1 - y0 + 1;
        int inset_x = (int) (box_w_ds * CROP_INSET_FRACTION);
        int inset_y = (int) (box_h_ds * CROP_INSET_FRACTION);

        int page_x0 = int.max (0, (x0 + inset_x) * step);
        int page_y0 = int.max (0, (y0 + inset_y) * step);
        int page_x1 = int.min (page.width - 1, (x1 - inset_x) * step);
        int page_y1 = int.min (page.height - 1, (y1 - inset_y) * step);

        result.found_document = true;
        result.crop_x = page_x0;
        result.crop_y = page_y0;
        result.crop_width = page_x1 - page_x0 + 1;
        result.crop_height = page_y1 - page_y0 + 1;

        return result;
    }
}
