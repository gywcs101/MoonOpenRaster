# OpenRaster 0.0.6 Full baseline 核对记录

本页记录仓库版本的验证证据。Full baseline 是交付目标，表中未完成的条目仍需补齐。规范固定到上游修订 `febacf9ae879a95fc9200d5bccb67d15db4de298`。SVG 1.1 静态特性用于补充渲染验收，OpenRaster 未在所查条款中逐项列出 SVG 特性。[文件布局](https://github.com/KDE/websites-openraster-org/blob/febacf9ae879a95fc9200d5bccb67d15db4de298/baseline/file-layout-spec.rst) · [图层栈](https://github.com/KDE/websites-openraster-org/blob/febacf9ae879a95fc9200d5bccb67d15db4de298/baseline/layer-stack-spec.rst) · [配套 schema](https://github.com/KDE/websites-openraster-org/blob/febacf9ae879a95fc9200d5bccb67d15db4de298/openraster-standard/schema.rnc) · [SVG 静态特性](https://www.w3.org/TR/SVG11/feature.html)

| 条款 | 读取与写回 | 证据或待验证项 |
| --- | --- | --- |
| ZIP 与 mimetype | 校验标识和资源路径，输出首项为未压缩 mimetype | Python 独立核对了中文路径的 UTF-8 标志。Python 生成的混合宽度 ZIP64 目录已通过读取和像素对照。真实大文件仍受 256 MiB 归档预算限制 |
| stack.xml 和资源路径 | UTF-8 图层树及区分大小写的相对路径，写出 0.0.6 | SVG 样例验证路径和资源保留 |
| 图像尺寸、裁剪与分辨率 | 按画布裁剪，保留分辨率属性 | 已测负偏移和裁剪。旧文件只给一个方向时，对缺失方向采用 72 DPI，输出成对写入 |
| 图层顺序与属性 | 读写名称、显隐、透明度、合成方式、带符号坐标 | CLI、库和工作台已有编辑往返测试 |
| 根栈、组隔离及透传 | 根栈隐式合成，组显式声明隔离方式。省略废弃组位置 | 核心测试覆盖组和透明度。schema 要求 isolation，正文对根栈要求省略并为非根栈给出默认值，以正文的属性行为写出 |
| 20 种合成操作 | 读写模式并依规范合成 | 核心独立数值测试。与 Krita 的加法差异另见兼容矩阵 |
| PNG 图层及色彩 | 8 位、16 位及混合位深重新合成。支持矩阵、查找表与受支持的 ICC 多阶段浮点转换，以及 gamma、RGB 色度及部分 SDR cICP | 16 位样例检查未改动样本及精确合成。矩阵、三类 LUT、ICC 浮点矩阵、查找表和分段曲线、P3 cICP 与 cHRM 对照 LittleCMS，每个 8 位通道最多相差 1 |
| SVG 图层及引用 | 保留矢量源和归档路径，已测 CSS、use、相对路径 CSS 和 PNG、跨文件 SVG 片段 | 已验证随稿 OpenType 字体、内置的通用字体、嵌套 tspan、多级样式表、沿本地路径排字和部分逐字位置列表和简单汉字竖排。复杂脚本的逐字定位及完整静态效果仍待验证 |
| ORA 文本节点 | 正文提到 `text`，正式 schema 只定义 `stack` 和 `layer`，早期草案把文本标为待定义。按正式语法验收，未定义节点通过只读查看和原样保存保留 | SVG 文字使用 `layer src="…svg"`，见下面的独立样例 |
| mergedimage.png | 从编辑后图层生成 8 位或 16 位 PNG | 样例用独立合成预期验证像素 |
| Thumbnails/thumbnail.png | 生成 8 位非隔行缩略图，最大 256 × 256 | CLI 往返和独立格式检查 |

## SVG 与 16 位混合案例

在仓库根目录运行 `python scripts/check_svg.py`。打开生成的 `_build/svg-roundtrip/input.ora`，选中 Vector，把 X 改为 2，不透明度改为 50%，保存新 ORA。CLI 生成的对照文件位于同目录的 `edited.ora`。该案例由测试程序生成，用已知颜色和样本值核对 SVG、CSS、16 位合成及缩略图。Playwright 在 Chromium 中执行相同修改并得到与 CLI 字节一致的 ORA，再从网页重开。MyPaint 已对带路径 SVG 的混合稿完成独立重开和合成。MyPaint 也独立重算了包含图形复用、剪裁和偏移滤镜的混合稿。含定制字体的其他独立应用对照仍待补齐。

内部 CSS 与 use 两条独立回归各自移动邻接栅格层，然后验证重新打开时的图层和像素。另一条回归复制引用归档内 CSS 和 PNG 的 SVG 图层，检查共享资源和路径继续有效。实验还需完成 SVG 1.1 静态特性对照，其中完整蒙版、滤镜、复杂文字和嵌套资源是当前优先项。已通过重复图案、亮度蒙版及偏移滤镜的独立像素断言。

同一命令另外生成 `font-input.ora`、`font-edited.ora` 和内嵌字体变体。在工作台打开 `font-input.ora`，选中 Raster，把 X 改为 1，再保存。独立逐像素检查确认 SVG 的 A 和中仍使用随稿字形，未修改的 16 位栅格样本保持原值。

Chromium 的 Canvas 使用同一字体独立绘制字形，并用 50% 覆盖阈值检查轮廓，以容纳边缘抗锯齿差异。工作台打开相同原稿后移动 Raster，生成的 ORA 与 CLI 输出字节一致。Krita 5.3.4 的普通栅格 ORA 往返最大 8 位通道差为 1。用 Krita 实际打开字体混合稿并导出 PNG 时，栅格能够导出，SVG 的红色字形没有出现在结果里。进一步用 `python scripts/check_svg.py --krita PATH_TO_KRITA` 对照，PNG 层完整导出，纯路径 SVG 与带字体 SVG 都被跳过。三份归档的旧预览均为纯蓝，导出都没有蓝色像素。这验证了该版本 Krita 在此测试中会重算栅格，但不会呈现这两种 SVG 层。

## MyPaint 独立往返

使用官方 MyPaint 2.0.1 Windows 便携版和 Python Pillow。运行 `python scripts/check_mypaint.py PATH_TO_EXTRACTED_MYPAINT`。脚本分别编辑 MyPaint 导出的路径 SVG 分层稿和包含同一 SVG 与原生 16 位 PNG 的混合稿，再调用 MyPaint 重开、合成并保存。另有图形复用、剪裁和偏移滤镜一起参与合成的样例。三份输出都保留原 SVG 和新坐标。按 ORA 画布范围裁剪 MyPaint 的瓦片输出后，8 位通道差均为 0。独立 PNG 解码确认 MoonOpenRaster 写出的 16 位栅格样本精确保留。MyPaint 自己重存的栅格资源会变为 8 位。

另外实测 MyPaint 打开本项目生成的混排字体稿和带 SVG 视图引用的混合稿。它留下 SVG 根源文件，但重存未包含随稿字体以及相对引用的 CSS、SVG 和 PNG，两例预期的彩色区域也未正确呈现。因此这两例的独立应用往返仍未通过。

`python scripts/check_svg.py` 另生成 `font-path-input.ora` 和 `font-position-list-input.ora`，并验证移动相邻栅格层后逐像素重算、矢量源保留及重开。沿路径排字覆盖线段、二次和三次曲线、椭圆弧的路径几何、本地路径变换、相对起点、pathLength 校准和嵌套文字片段。逐字坐标覆盖从左到右的一字一字形布局。

字体样例还用手算像素核对了内嵌和归档引用的 SVG 路径字形、水平字偶间距、通过 `tref` 引用文字，以及一行使用随稿 OpenType 字体的从右向左排列。保存保留字体、引用文件和 SVG 原文。XML 内部实体在受限预算内展开，找不到的外部实体会报告名称。[SVG 1.1 字体规范](https://www.w3.org/TR/SVG11/fonts.html) · [SVG 1.1 文字规范](https://www.w3.org/TR/SVG11/text.html)


两个竖排样例验证同一随稿 OpenType 字体的汉字字形、纵向进给和居中对齐。旧版拒绝两份文件。当前版本复用 mizchi/font 的纵向字形和度量，移动相邻 16 位层后保存并重开，保留源字形和栅格精度。

## SVG 1.1 静态特性核对

| W3C 特性 | 已有证据 | 待验收 |
| --- | --- | --- |
| 文档结构、坐标和视口 | UTF-8 和 UTF-16、嵌套组、百分比视口和文字坐标、物理单位、负偏移、基础变换、SVG 1.1 文档类型及内部实体、带 CSS 的 switch 分支和超链接图形。元数据随源文件保留 | 全部条件特性、语言环境和扩展元素 |
| 图形、填充、描边与透明度 | 路径、常见几何、RGBA 像素、渐变及图案 | 渐变和图案的全部组合、标记对照 |
| 样式和资源 | 内部 CSS、多级 CSS、XML 样式表声明、文字样式选择器、同文件和跨文件引用、归档内和内嵌 PNG、JPEG、SVG 图像 | 嵌套视口的命名片段、带 transform 的 svgView 及视口与 CSS 的其余组合 |
| 文字和字体 | 随稿 OpenType、WOFF2、内置通用字体、SVG 路径字形、备用字体源、粗细及斜体选择、空白、嵌套居中、字距、文字引用、单行右向左文字及双向文字片段、沿归档内路径排字和随稿 OpenType 简单竖排 | 内置字体字形覆盖、系统字体解析、复杂脚本逐字定位、多段竖排和字形旋转、路径字距和字形调整 |
| 剪裁、蒙版和滤镜 | 剪裁、蒙版、颜色矩阵、组件传递、合并、形态学、模糊、噪声、平铺、滤镜图像引用及填充和背景输入。已核对滤镜色彩空间的样式继承、缩放和平移下的偏移，以及倾斜变换下以用户坐标和对象边界定义的外层滤镜区域 | 滤镜属性的完整样式覆盖、受旋转和剪切影响的图元及多阶段组合 |
| 色彩与配置 | sRGB 8/16 位往返、常见 ICC 和 PNG 色彩声明及原始色彩数据保留 | 其余 ICC 转换与真实配置覆盖、HDR、SVG 色彩配置 |

安装的 MoonBit 图像库读取 ICC 名称和字节。Mooncakes 的 enanandesu/icc 解析配置描述和标签，未提供相同样例所需的浮点像素转换。现有 MoonBit 转换器复用查找表插值和 XYZ、Lab 转 sRGB 计算。矩阵、查找表和分段曲线样例的 8 位通道与 LittleCMS 相差最多 1。16 位浮点矩阵样例的原始图层逐字节保留，16 位透明度完全一致。与 LittleCMS 2.16 的 sRGB 输出相比，最大通道差为 7，验收容差为 8。对含未定义阶段的 D2B1，按 ICC.1 的优先级退回仍受支持的矩阵或查找表。LittleCMS 在实测中拒绝带该未知阶段的原配置，因此回退像素用移除未知阶段后的同一配置对照。[Mooncakes ICC 解析器](https://skills.mooncakes.io/docs/enanandesu/icc%400.1.1) · [LittleCMS](https://github.com/mm2/Little-CMS)

色彩对照可以运行 `python scripts/check_rgba16.py` 复现。被转换图层的原始 PNG 包含原位深和原色彩配置。写出的合并图使用 sRGB。ICC 采用相对色度转换，超出 sRGB 色域的颜色裁剪到可表示的范围。算法来源见 [ICC.1:2022](https://www.color.org/specifications/ICC.1-2022-05.pdf) 和 [PNG 第三版](https://www.w3.org/TR/png-3/)。

资源测试用独立像素断言检查了 `<image>` 引用归档 SVG，并检查该 SVG 通过自己的相对路径加载 CSS 和 PNG。移动图层、保存和重开后，所有资源字节保持一致，合并画面按新坐标生成。SVG 图像的 Base64 和百分号编码数据也通过了像素对照。循环引用会报告出错的资源。 同一 SVG 资源的两个图像引用可分别使用命名视图和 svgView 中的 viewBox。混合稿保存并重开后，两种裁切仍保留各自的视图，并按原路径读取对应的 CSS、PNG 和 OpenType 字体。命名视图内的字形遮住滤镜颜色，确保字体和滤镜都参与了重算。同一混合稿分别移动 16 位栅格层，以及移动 SVG 并将其不透明度设为 50%。独立像素断言核对了两次保存的新预览、未修改的 16 位像素和图层结构。[SVG 1.1 视图片段](https://www.w3.org/TR/SVG11/linking.html#SVGFragmentIdentifiers)

同一混合样例提取到本地后，resvg 0.50.0 即使显式加载随稿字体，仍将两条带视图的相对图像引用报告为无效，输出全透明。Chromium 的本地 SVG 图像嵌入也未得到预期颜色。该样例以独立构造的像素为对照，网页与命令行的 ORA 输出逐字节相同。[resvg 0.50.0](https://github.com/linebender/resvg/releases/tag/v0.50.0)

Chromium 独立对照覆盖描边标记、渐变图案、剪裁和蒙版叠加滤镜、颜色矩阵和组件传递、滤镜合成、形态学、图像引用，以及变换后的偏移和滤镜区域。三十二例的 8 位预乘通道最大差为 1。不等透明度的形态学膨胀与 Chromium 逐通道一致，计算复用了预乘通道类型。两例有种子的分形噪声误差不到 2，其中一例使用无缝拼接。透明背景上的高斯模糊另由公式逐像素核对透明度，误差最多 1。该例与 Chromium 近似渲染的最大差为 12。测试位于 `tests/browser/svg-reference.mjs`。填充、描边和背景输入由独立预期像素验证。半像素偏移用相邻两像素各半的覆盖度验证，测试样例中 Chromium 的边缘覆盖取整。[SVG 1.1 滤镜规范](https://www.w3.org/TR/SVG11/filters.html)

带倾斜变换的滤镜在旧版会填满外接矩形。当前版本复用 SVG 剪裁算法计算以用户坐标和对象边界定义的滤镜区域的实际像素覆盖，逐像素对照变换后的四边形与像素交叠面积，8 位透明度误差最多为 1。同一样例与 Chromium 的最大通道差为 127，resvg 0.50.0 生成图的透明度与几何预期最大差为 143。两者在该样例的边缘覆盖计算不同。两例验证的是滤镜外层区域，图元区域及多阶段变换还需分别验收。[SVG 1.1 滤镜区域](https://www.w3.org/TR/SVG11/filters.html#FilterEffectsRegion) · [resvg 0.50.0](https://github.com/linebender/resvg/releases/tag/v0.50.0)

滤镜色彩空间的两例复用现有 CSS 层叠，分别验证从祖先样式表继承 sRGB，以及图元选择器覆盖滤镜的线性 RGB 属性。旧版在祖先继承案例的红色通道差为 61。修复后两例与 Chromium 的最大 8 位通道差均为 1。填充颜色、透明度以及光源颜色也复用样式层叠，覆盖 currentColor 和 CSS 变量。灰度高度图的边缘法线采用 SVG 规范给出的加权差分。新增三个对应样例与 Chromium 逐通道一致。透光的镜面反射和线性 RGB 漫反射也通过对照，最大通道差为 1。

旧版拒绝混排 `אב<tspan>A</tspan>`。独立探针确认 moon_cosmic 0.3.9 可返回字形、位置和所选字体。随后核对已安装的 mizchi/font，发现其使用的 Unicode 双向排序模块也能提供整行顺序。当前实现直接复用该模块和现有 OpenType 字形处理，两个不同字体和颜色的文字片段保留各自样式。移动相邻 16 位层后，独立像素断言核对了文字位置和颜色，两个字体文件与 SVG 源都完整保留。显式方向覆盖与跨片段逐字定位仍待验证。

缺字回退样例使用两款可分发 OpenType 字体。主字体保留其独特的拉丁字母进给，缺少的汉字借用备用字体。另一例由备用字体绘制整段文字。复用 mizchi/font 的塑形分段和字形度量，独立像素结果核对了缺字替换后的精确位置。另有一例验证首选字体文件缺失时仍能从备用字体绘制。保存保留实际用到的字体和 SVG 源。需要跨字体连写的复杂脚本仍待验收。[moon_cosmic 0.3.9](https://mooncakes.io/docs/Milky2018/moon_cosmic%400.3.9)

关于独立 `stack.xml` 文本节点的历史说明见 [OpenRaster 早期草案](https://github.com/openraster/ora-spec/pull/3/files)。现行交付以本文固定的规范和 schema 为依据。

第一轮验证候选在 Linux、Windows 和 macOS 的 CI 通过，包括原生测试与独立消费者。该运行对应其页面列出的提交。[CI 验证](https://github.com/gywcs101/MoonOpenRaster/actions/runs/44729596754)
