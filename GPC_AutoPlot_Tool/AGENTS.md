# GPC-Origin AutoPlot Tool Rules

This tool automates LabSolutions GPC txt extraction and Origin 2021 plotting.

## Fixed Folders

All work must stay inside `GPC_AutoPlot_Tool`.

- Input txt: `00_input_txt`
- Origin template: `01_origin_template/GPCnew.otpu`
- Run outputs: `05_runs/YYYYMMDD_HHMMSS_GPC_Run`
- Scripts: `scripts`
- Logs: `logs`

Do not access paths outside `GPC_AutoPlot_Tool`. Do not modify input txt files or the Origin template.

By default, read only root-level `.txt` files directly inside `00_input_txt`. Ignore every child folder under the input folder, including historical archive folders. An optional `-InputFolder` may point at a different input folder; in that mode, still read only root-level `.txt` files from that folder and ignore all child folders.

## Extraction

Read only `[GPC Slice Data Table(Detector A)]`.

Use:

- X = `R.Time`
- Y = `Height`

Start after the header:

`Peak# Slice# R.Time Volume M.W. Height Sub Total % Area`

Stop at an empty line or the next section title beginning with `[`.

CSV output must contain only:

- `X`
- `Y`

## File Name Parsing

Prefer txt-header metadata first. Read `Data File Name`, take the basename from the path, remove `.lcd`, and support both `timeh-sample-category-...` and `sample-timeh-category-...`.

Examples:

- `576h-41w-ps-26.5.15.lcd` -> sample `41w`, time `576`, category `ps`
- `2w-120h-ps-26-1-10.lcd` -> sample `2w`, time `120`, category `ps`, date `20260110`

Ignore trailing date/replicate segments after the category.

If `Data File Name` is absent or cannot be parsed, support both external file name formats.

Format 1, with sample prefix:

`sample-timeh-category.txt`

Examples:

- `2590-28h-pure.txt`: sample `2590`, time `28`, category `pure`
- `13000-72h-ps.txt`: sample `13000`, time `72`, category `ps`

Format 2, without sample prefix:

`timeh-category.txt`

Examples:

- `0h-Ps.txt`: time `0`, category `ps`
- `46h-pure.txt`: time `46`, category `pure`

For prefixless names, use the optional `-SampleName` parameter as the sample name:

```powershell
powershell -ExecutionPolicy Bypass -File run_autoplot.ps1 -SampleName "2w"
```

For external fallback names, the `h` after numeric time is optional: both `572h-ps.txt` and `572-ps.txt` are valid.

Do not invent sample name `Sample`. If metadata and the external file name cannot provide a sample, require `-SampleName`.

Default execution is single-sample mode. Use sample names in this priority order:

1. `Data File Name`
2. external txt file name
3. `-SampleName` only as a fallback when neither source can supply a sample

`-SampleName` must not override parsed sample names by default. Only `-SampleName "<name>" -ForceSampleName` may force every input file to one sample. If multiple metadata sample names are detected, stop before creating outputs unless the user explicitly passes `-AllowMultiSample` or intentionally uses `-ForceSampleName`.

At run start, print and log:

- current input mode (`root txt only`)
- txt files to process
- ignored subfolders
- per-file parse result

If one txt extraction fails, log it as skipped and continue with other valid txt files. Stop only when there are no valid records, Stock Solution is missing, valid ps/pure data is missing, a required template is missing, or Origin plotting fails.

Normalize category case: `Ps`, `PS`, and `ps` all become `ps`; `Pure`, `PURE`, and `pure` all become `pure`.

Also normalize `pu` to `pure`, so files such as `2590-11h-pu.txt` are treated as Pure data.

For prefixless files, `0h-ps.txt` or `0h-Ps.txt` is the Stock Solution for the effective sample name. For example, with `-SampleName "2w"`, `0h-Ps.txt` is the Stock Solution for sample `2w`.

Do not hard-code sample names, categories, or time points.

## Stock Solution Rule

Final fixed rule:

Prefer, in order:

1. sample-specific `C0`
2. sample-specific `sample-0h-ps`
3. shared prefixless `C0`
4. shared prefixless `0h-ps` / `0-ps`

If a batch contains an external input name such as `0h-ps.txt`, that prefixless Stock Solution may be shared by every detected sample unless a sample has its own higher-priority Stock Solution. It must be the first curve in every category plot for the same sample, including both the `ps` plot and the `pure` plot.

Its legend must be exactly:

`Stock Solution`

Never label `sample-0h-ps` as `0 h`.

For example, `2590-0h-ps.csv` must be first in both:

- `2590-ps`
- `2590-pure`

The pure plot must use `2590-0h-ps.csv` as Stock Solution, not `2590-0h-pure.csv`.

By default, do not plot `sample-0h-pure`, to avoid duplicating the Stock Solution. If none of the four Stock Solution sources above exists, stop that sample and log an error.

## Plot Order

Each plot order is:

1. Stock Solution
2. Other curves in that category sorted by numeric time ascending

Legends must match curve order:

`Stock Solution`, then `2 h`, `5 h`, etc.

Do not show CSV file names or file extensions in legends.

## Origin Rules

Use Origin 2021 COM automation and the template:

`01_origin_template/GPCnew.otpu`

If the template cannot be called successfully, stop and report the error. Do not fall back to a default blank Origin graph.

Each CSV gets one workbook:

- Column A = X = R.Time
- Column B = Y = Height

After each import, verify A and B non-empty numeric counts. If B is empty, stop before plotting.

Each category plot must put all curves in one graph layer. The final plot count must equal:

`1 Stock Solution + number of other category time points`

If counts differ, stop and do not export images.

Before saving each sample GPC `.opju` and exporting GPC PNG/TIFF files, normalize every generated GPC graph page to `Times New Roman`. Only change the font family; preserve font sizes, legends, axes, ranges, line styles, symbols, and template layout.

## C-T Time Ratio Graph

In addition to the GPC overlay graph, each sample must get one time-ratio graph generated by Origin 2021.

Use the template explicitly:

`01_origin_template/C-T-.otpu`

Do not guess templates. Do not fall back to `GPCnew.otpu` or to a default blank Origin graph. If `C-T-.otpu` is missing or cannot create a graph page, stop and report the error.

The earlier combined two-column file is still kept:

`origin_project/<sample>/time_seconds_percent_<sample>.csv`

For Origin C-T plotting, split that comparison data into two separate two-column CSV files:

- `origin_project/<sample>/C-T_PS_<sample>.csv`
- `origin_project/<sample>/C-T_Pure_<sample>.csv`

Both split files must contain exactly:

- A/X = `Time_s`
- B/Y = `Percent_decimal`

The PS file contains only PS data and must start with `0,1` for Stock Solution. The Pure file contains only Pure data and must also start with `0,1`; this Pure baseline still comes from the same sample `sample-0h-ps` C0, not from `sample-0h-pure`.

Do not create a separate C-T OPJU. Integrate C-T into the same sample GPC project:

- `origin_project/<sample>/<sample>_GPC.opju`
- `export_figures/<sample>/C-T/<sample>_C-T.png`
- `export_figures/<sample>/C-T/<sample>_C-T.tif`

Inside `<sample>_GPC.opju`, create a root-level `Total` folder alongside `Ps` and `Pure`. It must contain:

- `PS` workbook
- `Pure` workbook
- `C-T` graph page

Do not mix PS and Pure into one workbook. The C-T graph must have exactly two curves in one layer:

- `PS`, from the `PS` workbook
- `Pure`, from the `Pure` workbook

Legends must be `PS` and `Pure`. Before plotting, verify each split CSV exists, has only `Time_s` and `Percent_decimal`, both columns are numeric, and B has non-empty data. After plotting, rescale and verify PNG/TIFF exist in addition to the single sample GPC OPJU.

## Height Summary

Every run must calculate `Height_Sum` for every extracted CSV. This is the sum of the Y column, which comes from LabSolutions `Height`.

Write:

- `export_figures/height_sum_summary.csv`
- `export_figures/height_sum_summary.xlsx` when Excel COM is available
- `export_figures/<sample>/height_sum_summary_<sample>.csv`

Summary columns:

`Sample, Category, Time_h, Txt_File, Csv_File, Height_Sum`

## Height Sum Compared With C0

For each sample, write a C0 comparison table in the same folder as that sample's `.opju`:

- `origin_project/<sample>/height_sum_vs_C0_<sample>.csv`
- `origin_project/<sample>/height_sum_vs_C0_<sample>.xlsx` when Excel COM is available

C0 selection priority:

1. Any file for the same sample whose file name contains `C0` or `c0`.
2. If no explicit C0 exists, use `sample-0h-ps`.

Do not share C0 across samples. Compare both ps and pure records against the same sample C0.

Columns:

`Sample, Category, Time_h, Txt_File, Csv_File, Height_Sum, C0_File, C0_Height_Sum, Difference_vs_C0, Ratio_vs_C0, Percent_vs_C0`

If C0 height sum is zero, write `NA` for ratio and percent and log a warning.

## Time Seconds Percent Output

For each sample, create one combined two-column file next to the sample `.opju`:

- `origin_project/<sample>/time_seconds_percent_<sample>.csv`
- `origin_project/<sample>/time_seconds_percent_<sample>.xlsx` when Excel COM is available

This file must contain exactly these columns:

`Time_s, Percent_decimal`

Rules:

- `Time_s = Time_h * 3600`.
- Prefer `Ratio_vs_C0` as `Percent_decimal`.
- If only `Percent_vs_C0` is usable, write `Percent_vs_C0 / 100`.
- Output decimal ratios such as `0.8563`, not percent values such as `85.63`.
- Merge ps and pure records into the same file for the sample.
- Sort internally by category (`ps` first, `pure` second, other categories after), then numeric time ascending.
- Do not output `Sample`, `Category`, `Time_h`, `Csv_File`, or `Txt_File` in this two-column file.
- Keep only one 0-second Stock Solution row per sample.
- Skip rows with unusable ratio/percent values and log the skipped source file, time, and reason.

## One OPJU Per Sample

Do not create separate `<sample>_ps_GPC.opju` and `<sample>_pure_GPC.opju` files.

Create one project per sample:

`origin_project/<sample>/<sample>_GPC.opju`

Inside the Origin project, create folders by category. For `ps` use `Ps`; for `pure` use `Pure`. Put each category's workbooks and graph in its folder.

## Metadata-Based Naming

Prefer `Data File Name` metadata for output naming. Parse sample, date, and output time from the txt content when available:

- `576h-41w-ps-26.5.15.lcd` -> sample `41w`, date `20260515`
- `Output Time 12:06:30` -> time `1206`

Run folder naming:

- single sample with time: `YYYYMMDD_HHMM-<sample>_GPC_Run`
- single sample without time: `YYYYMMDD-<sample>_GPC_Run`
- multiple samples: use `MultiSample`

Use the final effective sample name for OPJU, PNG, TIFF, CSV, XLSX, and archive folder names. `Data File Name` and external txt names decide that sample before `-SampleName` fallback is considered. Only `-ForceSampleName` may override parsed sample names.

The launcher `运行自动作图.bat` must not hard-code a real sample such as `41w`.

## Input Archive

After a successful run only, move processed root-level txt files into one archive folder per sample directly under `00_input_txt`:

`00_input_txt/YYYYMMDD-<sample>`

If the same folder already exists, append a numeric suffix such as `YYYYMMDD-<sample>-1`.

The script must only read root-level txt files in `00_input_txt` and must not reprocess historical txt files in any child folder.
