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
| PNG 图层及色彩 | 8 位、16 位及混合位深重新合成。支持矩阵与受支持的查找表 ICC、gamma、RGB 色度及部分 SDR cICP | 16 位样例检查未改动样本及精确合成。矩阵、三类 LUT、P3 cICP 与 cHRM 对照 LittleCMS，每个 8 位通道最多相差 1 |
| SVG 图层及引用 | 保留矢量源和归档路径，已测 CSS、use、相对路径 CSS 和 PNG、跨文件 SVG 片段 | 已验证随稿 OpenType 字体、内置的通用字体、嵌套 tspan、多级样式表、沿本地路径排字和部分逐字位置列表。复杂脚本的逐字定位及完整静态效果仍待验证 |
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

`python scripts/check_svg.py` 另生成 `font-path-input.ora` 和 `font-position-list-input.ora`，并验证移动相邻栅格层后逐像素重算、矢量源保留及重开。沿路径排字覆盖线段、二次和三次曲线、椭圆弧的路径几何、本地路径变换、相对起点、pathLength 校准和嵌套文字片段。逐字坐标覆盖从左到右的一字一字形布局。


## SVG 1.1 静态特性核对

| W3C 特性 | 已有证据 | 待验收 |
| --- | --- | --- |
| 文档结构、坐标和视口 | UTF-8 和 UTF-16、嵌套组、百分比视口和文字坐标、物理单位、负偏移、基础变换、SVG 1.1 固定文档类型、带 CSS 的 switch 分支和超链接图形。元数据随源文件保留 | 全部条件特性、语言环境和扩展元素 |
| 图形、填充、描边与透明度 | 路径、常见几何、RGBA 像素、渐变及图案 | 渐变和图案的全部组合、标记对照 |
| 样式和资源 | 内部 CSS、多级 CSS、XML 样式表声明、文字样式选择器、同文件和跨文件引用、归档内和内嵌 PNG、JPEG、SVG 图像 | 资源图像的完整视口、片段与 CSS 组合 |
| 文字和字体 | 随稿 OpenType、WOFF2、内置通用字体、备用字体源、粗细及斜体选择、空白及嵌套居中、字距、简单单行 `textLength`、沿归档内路径排字、部分逐字定位 | 内置字体字形覆盖、系统字体解析、逐字多列继承、复杂脚本位置、路径上的字距和字形调整 |
| 剪裁、蒙版和滤镜 | 剪裁与亮度蒙版和偏移滤镜组合，四种颜色矩阵模式、组件传递、合并、形态学、高斯模糊、分形噪声、滤镜阶段裁剪、平铺及滤镜图像引用。已核对部分线性 RGB 表现和绘制、背景输入 | 其余滤镜的线性 RGB 与样式继承、变换后的边界和复杂组合 |
| 色彩与配置 | sRGB 8/16 位往返、常见 ICC 和 PNG 色彩声明及原始色彩数据保留 | 其他 ICC 转换类型、HDR、SVG 色彩配置 |

色彩对照可以运行 `python scripts/check_rgba16.py` 复现。被转换图层的原始 PNG 包含原位深和原色彩配置。写出的合并图使用 sRGB。ICC 采用相对色度转换，超出 sRGB 色域的颜色裁剪到可表示的范围。算法来源见 [ICC.1:2022](https://www.color.org/specifications/ICC.1-2022-05.pdf) 和 [PNG 第三版](https://www.w3.org/TR/png-3/)。

资源测试用独立像素断言检查了 `<image>` 引用归档 SVG，并检查该 SVG 通过自己的相对路径加载 CSS 和 PNG。移动图层、保存和重开后，所有资源字节保持一致，合并画面按新坐标生成。SVG 图像的 Base64 和百分号编码数据也通过了像素对照。循环引用会报告出错的资源。

Chromium 独立对照覆盖描边标记、渐变图案、剪裁和蒙版叠加滤镜、颜色矩阵和组件传递、滤镜合成、形态学，以及两种坐标单位下的滤镜区域。二十一例的 8 位预乘通道最大差为 1，其中八例覆盖卷积、滤色混合、源覆盖、合并、滤镜图形引用和平铺。两例有种子的分形噪声误差不到 2，其中一例使用无缝拼接。透明背景上的高斯模糊另由公式逐像素核对透明度，误差最多 1。该例与 Chromium 近似渲染的最大差为 12。测试位于 `tests/browser/svg-reference.mjs`。填充、描边和背景输入按 SVG 1.1 的定义用独立预期像素验证。[SVG 1.1 滤镜规范](https://www.w3.org/TR/SVG11/filters.html)

关于独立 `stack.xml` 文本节点的历史说明见 [OpenRaster 早期草案](https://github.com/openraster/ora-spec/pull/3/files)。现行交付以本文固定的规范和 schema 为依据。

第一轮验证候选在 Linux、Windows 和 macOS 的 CI 通过，包括原生测试与独立消费者。该运行对应其页面列出的提交。[CI 验证](https://github.com/gywcs101/MoonOpenRaster/actions/runs/44729596754)
