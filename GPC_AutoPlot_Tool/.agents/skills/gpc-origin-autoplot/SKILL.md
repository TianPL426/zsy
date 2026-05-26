# GPC-Origin AutoPlot Skill

Use this skill when maintaining or running the GPC-Origin AutoPlot workflow in `GPC_AutoPlot_Tool`.

## Purpose

The workflow converts LabSolutions GPC txt reports into CSV files and Origin 2021 overlay plots using the user's Origin template.

## Entry Point

Run:

```powershell
powershell -ExecutionPolicy Bypass -File run_autoplot.ps1
```

The double-click launcher is:

```text
运行自动作图.bat
```

## Directory Contract

Only work inside `GPC_AutoPlot_Tool`.

- `00_input_txt`: user-provided LabSolutions txt files
- `01_origin_template/GPCnew.otpu`: required Origin template
- `05_runs`: timestamped run outputs

Each run creates:

- `input_txt_copy`
- `processed_csv`
- `origin_project`
- `export_figures`
- `logs`

Default input mode is root-level txt only. Read only `00_input_txt/*.txt` and ignore all subfolders. The optional `-InputFolder` parameter can select another input folder, but it must also be scanned non-recursively: root txt files only, child folders ignored.

## Extraction Contract

Extract only `[GPC Slice Data Table(Detector A)]`.

Use `R.Time` as X and `Height` as Y.

Start after the table header and stop at an empty line or the next section beginning with `[`.

Do not read the whole txt document by fixed columns. Do not read `[Molecular Weight Distribution Table(Detector A)]`.

## Filename Parsing

Prefer txt-header metadata first. Read `Data File Name`, take the basename only, remove `.lcd`, and support both:

- `timeh-sample-category-...`
- `sample-timeh-category-...`

Examples:

- `576h-41w-pure-26.5.15.lcd` -> sample `41w`, time `576`, category `pure`
- `2w-120h-ps-26-1-10.lcd` -> sample `2w`, time `120`, category `ps`, date `20260110`

Ignore trailing date/replicate segments after the category.

If `Data File Name` is missing or cannot be parsed, support both external naming styles.

Style 1:

`sample-timeh-category`

Examples:

- `2590-28h-pure.txt` -> sample `2590`, time `28`, category `pure`
- `13000-72h-ps.txt` -> sample `13000`, time `72`, category `ps`

Style 2:

`timeh-category`

Examples:

- `0h-Ps.txt` -> effective sample name, time `0`, category `ps`
- `46h-pure.txt` -> effective sample name, time `46`, category `pure`

For prefixless file names, use `-SampleName`:

```powershell
powershell -ExecutionPolicy Bypass -File run_autoplot.ps1 -SampleName "2w"
```

For external fallback names, the `h` after numeric time is optional: both `572h-pure.txt` and `572-pure.txt` are valid.

Do not invent sample name `Sample`. If metadata and external file name cannot supply a sample, require `-SampleName`.

Default execution is single-sample mode. Resolve the sample in this order:

1. `Data File Name`
2. external txt file name
3. `-SampleName` only as a fallback when both parsed sources are unavailable

`-SampleName` does not override parsed sample names by default. Use `-SampleName "<name>" -ForceSampleName` only when the user intentionally wants to force every input file to one sample. If metadata reveals multiple samples, stop before output generation unless the user explicitly passes `-AllowMultiSample` or intentionally uses `-ForceSampleName`.

At startup, print and log the current input mode, the exact txt files to process, ignored subfolders, and per-file parsing results.

If a single txt extraction fails, mark it skipped and continue with the remaining valid files. Stop the run only if all txt extraction fails, no Stock Solution exists, no valid ps or pure data exists, a template is missing, or Origin plotting fails.

Category parsing is case-insensitive and normalized to lower case. `Ps`, `PS`, and `ps` all become `ps`; `Pure`, `PURE`, and `pure` all become `pure`.

Normalize `pu` to `pure`, so names like `2590-11h-pu.txt` are included in Pure outputs and C-T Pure data.

With `-SampleName "2w"`, a prefixless `0h-Ps.txt` file is the Stock Solution for sample `2w`, and must appear first in both `2w-ps` and `2w-pure` plots.

Never hard-code sample names, categories, or times.

## Final Stock Solution Rule

Choose Stock Solution in this priority order:

1. sample-specific `C0`
2. sample-specific `sample-0h-ps`
3. shared prefixless `C0`
4. shared prefixless `0h-ps` / `0-ps`

A prefixless external input name such as `0h-ps.txt` may be shared by all detected samples in the batch unless a sample has a higher-priority dedicated Stock Solution.

The selected Stock Solution must be the first curve in every plot for that sample, including:

- sample `ps` plot
- sample `pure` plot
- any other sample category plot

Legend text must be exactly:

`Stock Solution`

Never display `sample-0h-ps` as `0 h`.

Example:

`2590-0h-ps.csv` must be first in both `2590-ps` and `2590-pure` plots.

The pure plot must use `2590-0h-ps.csv` as Stock Solution, not `2590-0h-pure.csv`.

By default, skip `sample-0h-pure` to avoid duplicating the Stock Solution.

If none of the supported Stock Solution sources exists, stop that sample and log the error.

## Plotting Contract

For each sample-category graph:

1. First curve: Stock Solution.
2. Remaining curves: same category, sorted by numeric time ascending.
3. Legends match curve order.
4. Legends show `Stock Solution`, then `2 h`, `5 h`, etc.
5. No CSV file names in legends.

Each CSV imports to one Origin workbook:

- A = X
- B = Y

Use the validated two-dimensional COM array import. After import, verify A/B numeric counts.

Use Origin 2021 and `01_origin_template/GPCnew.otpu`. If template creation fails, stop. Never use matplotlib for final plots.

After adding curves, rescale and verify final plot count equals expected curve count. Export `.opju`, `.png`, and `.tif` only after validation passes.

Before saving each GPC project and exporting images, set all generated GPC graph-page text to `Times New Roman`. Change font family only; do not alter font size or any other template styling.

## C-T Time Ratio Graph

Also generate one C-T time-ratio graph per sample using Origin 2021.

The C-T graph must explicitly use:

`01_origin_template/C-T-.otpu`

Do not guess templates. Do not use `GPCnew.otpu` for this graph. Do not fall back to an Origin default blank graph.

Keep the combined source file:

`origin_project/<sample>/time_seconds_percent_<sample>.csv`

For Origin C-T plotting, also write split check files:

- `origin_project/<sample>/C-T_PS_<sample>.csv`
- `origin_project/<sample>/C-T_Pure_<sample>.csv`

Each split file must contain exactly two numeric columns:

- A/X = `Time_s`
- B/Y = `Percent_decimal`

The PS file contains only PS rows and starts with Stock Solution `0,1`. The Pure file contains only Pure rows and also starts with `0,1`; this Pure baseline still comes from the same sample `sample-0h-ps` C0.

Output:

- `origin_project/<sample>/<sample>_GPC.opju`
- `export_figures/<sample>/C-T/<sample>_C-T.png`
- `export_figures/<sample>/C-T/<sample>_C-T.tif`

C-T is integrated into `<sample>_GPC.opju` under a root-level `Total` folder. Each sample has only one Origin project file, `<sample>_GPC.opju`.

Inside the sample GPC project, create `Total` alongside `Ps` and `Pure`. `Total` contains:

- `PS` workbook
- `Pure` workbook
- `C-T` graph page

Do not mix PS and Pure in one workbook. The C-T graph must have exactly two curves in one layer, from PS and Pure respectively, with legends `PS` and `Pure`.

Before plotting, validate both split CSV files exist, have only the two required columns, and have non-empty numeric B values. After plotting, rescale and verify the single GPC OPJU plus C-T PNG/TIFF exist.

## Height Sum Summary

For every extracted CSV, calculate `Height_Sum` as the sum of the Y column (`Height` from the txt source).

Write these files in each run:

- `export_figures/height_sum_summary.csv`
- `export_figures/height_sum_summary.xlsx` if Excel COM is available
- `export_figures/<sample>/height_sum_summary_<sample>.csv`

Use columns:

`Sample, Category, Time_h, Txt_File, Csv_File, Height_Sum`

Sort by sample, category, and numeric time ascending.

## Height Sum vs C0

For each sample, create a C0 comparison table next to the sample `.opju`:

- `origin_project/<sample>/height_sum_vs_C0_<sample>.csv`
- `origin_project/<sample>/height_sum_vs_C0_<sample>.xlsx` if Excel COM is available

C0 detection:

1. Prefer a same-sample file with `C0` or `c0` in its file name.
2. Otherwise use `sample-0h-ps`.

Never share C0 between samples. Both ps and pure records compare against the same sample C0.

Columns:

`Sample, Category, Time_h, Txt_File, Csv_File, Height_Sum, C0_File, C0_Height_Sum, Difference_vs_C0, Ratio_vs_C0, Percent_vs_C0`

If `C0_Height_Sum` is zero, output `NA` for ratio and percent and log the issue.

## Time Seconds Percent Output

For each sample, create one additional file next to the sample `.opju`:

- `origin_project/<sample>/time_seconds_percent_<sample>.csv`
- `origin_project/<sample>/time_seconds_percent_<sample>.xlsx` if Excel COM is available

This file is derived from `height_sum_vs_C0_<sample>.csv` and must contain exactly two columns:

`Time_s, Percent_decimal`

Rules:

- `Time_s = Time_h * 3600`.
- Prefer `Ratio_vs_C0` for `Percent_decimal`.
- If only `Percent_vs_C0` is usable, use `Percent_vs_C0 / 100`.
- Values must be decimal ratios such as `1.0000` or `0.8563`, not percent values such as `100` or `85.63`.
- Merge ps and pure results into one sample file, never separate ps/pure files.
- Sort rows by category order (`ps`, then `pure`, then other categories), and by numeric time ascending within each category.
- The CSV must not contain source columns such as sample, category, time_h, txt, or csv.
- Keep only one 0-second Stock Solution row per sample.
- Skip rows with unusable ratio/percent values and log the skipped source file, time, and reason.

## One Origin Project Per Sample

Each sample gets one `.opju`:

`origin_project/<sample>/<sample>_GPC.opju`

Do not create separate category `.opju` files.

Inside the `.opju`, create category folders:

- `Ps` for ps
- `Pure` for pure
- capitalized category name for other categories

Each folder contains that category's imported workbooks and overlay GPC graph.

## Metadata-Based Naming

Use `Data File Name` as the first source for sample/date naming. Example:

- `576h-41w-ps-26.5.15.lcd` -> sample `41w`, date `20260515`
- `Output Time 12:06:30` -> `1206`

Run folders are:

- `YYYYMMDD_HHMM-<sample>_GPC_Run` when date and time are available
- `YYYYMMDD-<sample>_GPC_Run` when only date is available
- `YYYYMMDD_HHMM-MultiSample_GPC_Run` for multi-sample batches

Use the final effective sample name for all OPJU, PNG, TIFF, CSV, XLSX, and archive file names. Parsed metadata and external txt names take precedence over `-SampleName`; only `-ForceSampleName` may override them.

The launcher `运行自动作图.bat` must not hard-code a real sample such as `41w`.

## Successful Run Archive

Only after `.opju`, PNG, TIFF, and height summary outputs are verified, move processed txt files from `00_input_txt` root into sample-specific archive folders directly under `00_input_txt`:

`00_input_txt/YYYYMMDD-<sample>`

If an archive folder already exists, use a numeric suffix such as `YYYYMMDD-<sample>-1`.

Do not read or reprocess txt files inside any child folder of `00_input_txt`.
