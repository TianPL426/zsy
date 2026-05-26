GPC-Origin 自动作图工具使用说明

一、放置输入文件

请把 LabSolutions 导出的 GPC txt 文件放到：

GPC_AutoPlot_Tool\00_input_txt

文件名必须包含“样品名称-时间h-类别”，例如：

2590-0h-ps.txt
2590-2h-ps.txt
2590-28h-pure.txt
13000-72h-ps.txt

脚本会自动识别：
样品名称 = 时间标志之前的部分
时间 = “数字+h” 中的数字
类别 = 时间标志之后的部分

二、Origin 模板

Origin 模板必须放在：

GPC_AutoPlot_Tool\01_origin_template\GPCnew.otpu

所有图都必须用这个模板生成。如果模板无法调用，脚本会停止并报错，不会退回生成 Origin 默认空白图。

三、如何运行

双击：

运行自动作图.bat

也可以在 PowerShell 中运行：

powershell -ExecutionPolicy Bypass -File run_autoplot.ps1

默认情况下，bat 文件不再写死任何样品名，也不会默认强制使用 41w。

四、输出结果在哪里

每次运行都会在下面目录中新建一个独立结果文件夹：

GPC_AutoPlot_Tool\05_runs\YYYYMMDD_HHMMSS_GPC_Run

每个 run 文件夹包含：

input_txt_copy      原始 txt 的留档副本
processed_csv       从 txt 提取出的 X/Y 数据
origin_project      可修改 Origin 工程 .opju，每个样品一个工程
export_figures      导出的 PNG 和 TIFF 图片
logs                运行日志

五、输出文件说明

.opju 是可修改的 Origin 工程文件，可继续在 Origin 中编辑图形。
.png 是普通图片，适合快速查看或放入文档。
.tif 是 TIFF 图片，适合论文、报告或高质量归档。

每次运行还会生成 Height 求和汇总：

export_figures\height_sum_summary.csv
export_figures\height_sum_summary.xlsx
export_figures\样品名称\height_sum_summary_样品名称.csv

Height_Sum 是每个 CSV 中 Y 列，也就是 txt 中 Height 数据的总和。

每个样品还会在 GPC project 文件夹中生成相对 C0 的比较表：

origin_project\样品名称\height_sum_vs_C0_样品名称.csv
origin_project\样品名称\height_sum_vs_C0_样品名称.xlsx

C0 识别优先级：

1. 文件名中包含 C0 或 c0 的文件优先作为该样品 C0；
2. 如果没有明确 C0 文件，则使用该样品的“样品名-0h-ps”作为 C0。

比较表包含 Height_Sum、C0_Height_Sum、Difference_vs_C0、Ratio_vs_C0、Percent_vs_C0，用于查看每个时间点相对 C0 的变化。

六、Stock Solution 规则

这是固定规则：

样品名-0h-ps.txt

会被识别为该样品的 Stock Solution。

例如：

2590-0h-ps.txt

会同时作为：

2590-ps 图的第一条曲线
2590-pure 图的第一条曲线
2590-其它类别图的第一条曲线

这条曲线在所有图中的图例都显示为：

Stock Solution

注意：

1. Stock Solution 只能来自“样品名-0h-ps”。
2. pure 图中的 Stock Solution 也必须来自“样品名-0h-ps”。
3. pure 图中的 Stock Solution 不能来自“样品名-0h-pure”。
4. “样品名-0h-ps”在图例中必须显示为 Stock Solution，绝不能显示为 0 h。
5. 默认不绘制 pure-0h，避免和 Stock Solution 重复。
6. 每个样品必须有“样品名-0h-ps.txt”。如果没有，脚本会报错并停止该样品作图。

七、Origin 工程结构

每个样品只生成一个可修改的 Origin 工程：

origin_project\样品名称\样品名称_GPC.opju

工程内部会按类别创建 Origin 文件夹，例如：

Ps
Pure

【新增：C-T 合并进 GPC 工程】
1. 每个样品最终只生成一个 Origin 工程文件：样品名_GPC.opju。
2. 不再单独生成 样品名_C-T.opju。
3. 样品名_GPC.opju 内部包含三个并列文件夹：Ps、Pure、Total。
4. Total 文件夹中保存 C-T 的 PS 工作簿、Pure 工作簿和 C-T 图。
5. C-T 的 PNG/TIFF 图片仍然导出到 export_figures\样品名\C-T。

【新增：GPC 图字体与元数据命名】
1. 每个样品的 GPC 图在保存 .opju、导出 PNG/TIFF 之前，会把所有 GPC 图页文字统一改为 Times New Roman。
2. 只改字体，不改字号，也不改坐标范围、刻度、图例、颜色、线宽和模板排版。
3. 结果文件夹优先使用 txt 文件中 Data File Name 解析出的日期、时间和样品名命名。
4. 例如 Data File Name 中含有 576h-41w-ps-26.5.15.lcd，且 Output Time 为 12:06:30，则 run 文件夹命名为：
   20260515_1206-41w_GPC_Run
5. 输出文件也优先使用 Data File Name 解析出的样品名，例如 41w_GPC.opju、41w_ps_GPC.png。
6. 样品名优先级为：Data File Name > 外部 txt 文件名 > -SampleName 备用值。
7. -SampleName 默认只作为无法解析样品名时的备用值，不会覆盖已经解析出的样品名。
8. 如果确实需要强制统一样品名，必须同时使用 -ForceSampleName，例如：
   powershell -ExecutionPolicy Bypass -File run_autoplot.ps1 -SampleName "41w" -ForceSampleName

【新增：单样品模式】
1. 默认情况下，一次运行只允许处理一个样品。
2. 如果 Data File Name 中同时解析出多个样品名，脚本会停止并提示检查元数据，不会静默拆成多个样品文件夹。
3. 如果这些文件实际属于同一个样品，请在运行命令中显式使用 -SampleName 和 -ForceSampleName 强制统一样品名。
4. 例如：
   powershell -ExecutionPolicy Bypass -File run_autoplot.ps1 -SampleName "41w" -ForceSampleName
5. 只有用户显式使用 -AllowMultiSample 时，才允许一次运行处理多个样品。

Ps 文件夹中放 PS 组工作簿和 PS 叠加图。
Pure 文件夹中放 Pure 组工作簿和 Pure 叠加图。

八、输入 txt 归档

只有当本次运行成功生成 .opju、PNG、TIFF 和 Height 汇总后，脚本才会把本次处理过的 txt 按样品移动到：

00_input_txt\YYYYMMDD-样品名称

例如：

00_input_txt\20260513-2590
00_input_txt\20260513-13000

如果当天同一样品已经有同名归档文件夹，会自动编号，例如：

00_input_txt\20260513-2590-1

下次运行时，脚本只读取 00_input_txt 根目录下的 txt，不会读取任何子文件夹中的历史 txt。

九、常见错误

1. 提示找不到 Stock Solution：
   请检查该样品是否有“样品名-0h-ps.txt”，例如 2590-0h-ps.txt。

2. 提示文件名无法解析：
   请检查文件名是否为“样品名-时间h-类别.txt”，例如 13000-24h-pure.txt。

3. 提示模板不存在或调用失败：
   请确认 GPCnew.otpu 位于 GPC_AutoPlot_Tool\01_origin_template。

4. 提示 B 列为空：
   说明数据导入 Origin 工作簿失败或 CSV 数据异常。请检查 txt 中 [GPC Slice Data Table(Detector A)] 是否包含 R.Time 和 Height 数据。

5. Origin 没有启动：
   请确认电脑已安装 Origin 2021，并且 COM 自动化可用。

十、安全说明

脚本只读取 GPC_AutoPlot_Tool\00_input_txt 根目录中的 txt 文件。
脚本不会修改输入 txt。
脚本不会修改 Origin 模板。
脚本不会删除文件。
每次运行都会新建 run 文件夹，不覆盖旧结果。

【新增输出：Time_s 与 Percent_decimal】

【文件名没有样品名称时】

脚本现在优先读取 txt 文件头中的 Data File Name，而不是先相信外部 txt 文件名。

例如：

Data File Name    G:\方法文件\576h-41w-ps-26.5.15.lcd

会识别为：

Sample = 41w
Time_h = 576
Category = ps

也支持：

Data File Name    G:\方法文件\2w-120h-ps-26-1-10.lcd

识别为：

Sample = 2w
Time_h = 120
Category = ps
Date = 20260110

后面的日期或重复编号不参与样品名识别。若 Data File Name 无法解析，才退回外部 txt 文件名。

现在同时支持两种文件名：

1. 有样品名称：
   样品名-时间h-类别.txt
   例如：2590-28h-pure.txt

2. 没有样品名称：
   时间h-类别.txt
   例如：0h-Ps.txt、46h-ps.txt、46h-pure.txt

退回外部文件名时，时间后面的 h 可以有也可以没有，例如 572h-ps.txt 和 572-ps.txt 都可以识别为 572 h。

如果 Data File Name 不可用、且外部文件名也没有样品名称，请运行时指定样品名作为备用值：

powershell -ExecutionPolicy Bypass -File run_autoplot.ps1 -SampleName "2w"

如果已经能从 Data File Name 或外部 txt 文件名解析出样品名，则 -SampleName 不会覆盖它。
只有在确实要强制覆盖时，才使用：

powershell -ExecutionPolicy Bypass -File run_autoplot.ps1 -SampleName "41w" -ForceSampleName

“运行自动作图.bat”不得默认写死 41w。

类别大小写不敏感：Ps、PS、ps 都会识别为 ps；Pure、PURE、pure 都会识别为 pure。

如果文件名中类别写成 pu，例如 2590-11h-pu.txt，也会自动识别为 pure，并进入 Pure 图和 C-T_Pure 数据。

当 SampleName = 2w 时，0h-Ps.txt 会作为 2w 样品的 Stock Solution，并作为 2w-ps 图和 2w-pure 图的第一条曲线，图例显示 Stock Solution。

【输入文件夹识别】

默认情况下，脚本只读取：

00_input_txt 根目录下的 .txt 文件

例如会读取：

00_input_txt\0h-ps.txt
00_input_txt\100h-ps.txt
00_input_txt\100h-pure.txt

不会读取任何子文件夹中的历史 txt，例如：

00_input_txt\20260514-2590\xxx.txt

运行开始时，终端和日志都会显示：

Current input mode: root txt only
Input txt files to process
Ignored subfolders

如果需要指定另一个输入目录，可以使用：

powershell -ExecutionPolicy Bypass -File run_autoplot.ps1 -SampleName "2w" -InputFolder "某个数据文件夹"

即使指定了 InputFolder，也只读取该文件夹根目录下的 txt，不递归读取子文件夹。

如果某一个 txt 提取失败，脚本会显示具体文件名和失败原因，并把它记为 skipped，继续处理其它有效 txt。只有全部 txt 都失败、找不到 Stock Solution、没有有效 ps/pure 数据、模板缺失或 Origin 作图失败时，才会停止整批流程。

每次成功运行后，脚本会在每个样品的 GPC project 文件夹中，和该样品的 .opju 放在一起，额外生成：

origin_project\样品名称\time_seconds_percent_样品名称.csv
origin_project\样品名称\time_seconds_percent_样品名称.xlsx

这个文件只包含两列：

Time_s
Percent_decimal

规则：
1. Time_s = Time_h × 3600。例如 2 h 会写成 7200。
2. Percent_decimal 优先使用 height_sum_vs_C0_样品名称.csv 中的 Ratio_vs_C0。
3. 如果只能使用 Percent_vs_C0，则会先除以 100 再写入。
4. Percent_decimal 必须是小数形式，例如 1.0000、0.8563，不写 100 或 85.63 这种百分数。
5. 同一个样品的 ps 和 pure 结果合并到同一个 time_seconds_percent_样品名称.csv 中，不分别生成 ps 和 pure 文件。
6. 输出顺序为 ps 在前、pure 在后；同一类别内按时间从小到大。
7. 样品名-0h-ps 仍然是 Stock Solution；在两列文件中对应 Time_s = 0、Percent_decimal = 1.0。
8. 如果 ps 和 pure 都引用同一个 Stock Solution，0 秒基准行只保留一行，不重复写入。

【新增输出：时间-比值图 C-T】

每次成功运行后，脚本还会为每个样品生成一张时间-比值图。

该图的数据来自：

origin_project\样品名称\time_seconds_percent_样品名称.csv

作图列为：

A 列 / X = Time_s
B 列 / Y = Percent_decimal

该图必须使用独立模板：

01_origin_template\C-T-.otpu

GPC 图仍然使用：

01_origin_template\GPCnew.otpu

脚本不会自动猜模板，也不会用 GPCnew.otpu 代替 C-T-.otpu。如果找不到 C-T-.otpu，脚本会停止并报错，不会生成 Origin 默认空白图。

每个样品会新增：

origin_project\样品名称\样品名称_C-T.opju
origin_project\样品名称\C-T_PS_样品名称.csv
origin_project\样品名称\C-T_Pure_样品名称.csv
export_figures\样品名称\C-T\样品名称_C-T.png
export_figures\样品名称\C-T\样品名称_C-T.tif

其中 样品名称_C-T.opju 与 样品名称_GPC.opju 放在同一个样品工程文件夹中，但二者是独立工程文件，互不覆盖。

C-T Origin 工程内部结构为：

样品名称_C-T
├─ PS
├─ Pure
└─ C-T

PS 和 Pure 必须是两个独立工作簿，不会再混合放进同一个数据表。

PS 工作簿只包含 PS 的 Time_s 和 Percent_decimal，第一行是 Stock Solution：
0, 1

Pure 工作簿只包含 Pure 的 Time_s 和 Percent_decimal，第一行同样是 Stock Solution：
0, 1

Pure 的 0,1 仍然来自同一样品的 样品名-0h-ps / C0 基准，不来自 样品名-0h-pure。

C-T 图中应有两条曲线，图例为：
PS
Pure
