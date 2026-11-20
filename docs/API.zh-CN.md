# 公共库使用说明

本库把 ORA 看成一张带图层树的图片。`read` 读取字节，编辑方法返回新文档，`render` 计算当前画面，`write` 生成新的 ORA 字节。文件读写放在调用程序中，库本身不依赖文件路径或浏览器。

## 引入与可运行示例

模块名为 `gywcs101/MoonOpenRaster`，`0.2.0` 提供以下 8 位及 16 位接口。在自己的模块中运行 `moon add gywcs101/MoonOpenRaster@0.2.0`，再在包中添加 `import { "gywcs101/MoonOpenRaster" @ora }`。

以下 `examples/` 与 `web/` 路径的命令在克隆的 GitHub 仓库根目录运行；通过 Mooncakes 安装核心库不包含网页样例。

最小示例：`moon run examples/basic --target js`。
完整示例：`moon run examples/roundtrip --target js`。它创建带嵌套组的文档，修改属性、替换像素、复制、跨组移动、合成、保存到字节并重开，还检查旧版本不被修改。

也可以读入真实文件并写到一个尚不存在的路径：

```sh
moon run examples/roundtrip --target js -- web/assets/capitole.ora edited.ora
```

原生目标把 `js` 改为 `native`。Windows 原生需要完整 MSVC 与 Windows SDK；不具备时可先运行 JS 目标。

## 导入单张图片

用 `decode_image(bytes)` 按文件内容识别独立图片，得到可传给 `Node::Layer` 或 `replace_image` 的图像。支持 PNG、JPEG、静态 WebP、GIF、BMP、TIFF、ICO 和受支持的静态 SVG。JPEG 和 TIFF 应用方向标记，GIF 取第一帧，TIFF 取第一页，ICO 取最大图标。文件上限 32 MiB；支持的 16 位样本保持精度。直接读取 ORA 中的栅格资源时使用 `decode_png`。已支持的色彩配置转换为 sRGB 像素供合成和单层 PNG 导出使用，保存 ORA 时保留转换过的原始 PNG。仓库版本通过 `read` 解析 SVG 引用的归档内 CSS、PNG、JPEG 和 SVG 片段，相对路径以 SVG 在归档中的位置为基准。独立导入请使用自包含 SVG。SVG 可用 `@font-face` 指定随稿字体，通用无衬线和衬线用内置字体。缺少字体或字形时，错误信息会指出原因。

## 矢量图层

`decode_svg(bytes)` 返回可作为 `Node::Layer` 内容使用的图像，`image.svg_source()` 返回原始 SVG 字节（普通栅格图像返回空），`image.storage_bytes()` 包含合成用像素和源文件占用。读取 ORA 时会识别 SVG 图层，移动、复制或编辑图层属性后写回仍保留源文件。调用 `encode_png()` 或 `layer_png(path)` 获得渲染后的像素，缩放预览也是栅格图像。具体元素与大小限制见 [兼容矩阵](COMPATIBILITY.zh-CN.md)。

## 数据和路径

`Image::new(w,h,pixels)` 接收连续 RGBA 字节，四个字节表示一个像素。输入数组会被复制。`image.pixels()` 返回 8 位副本，16 位输入采用就近舍入映射到 8 位，适合界面预览。用 `Image::new_rgba16(w,h,samples)` 创建每通道 0～65535 的图像。用 `image.bit_depth()` 查询存储位深，`image.pixels_rgba16()` 获取完整样本副本。读取 8 位图像的 16 位样本时，每个值精确乘 257。`Properties::new` 创建名称、坐标、可见性、不透明度和混合方式；标量可读，扩展属性通过 `extra()` 取得副本。

`Node::Layer(properties,image)` 表示独立像素图层；`Node::Group(properties,isolation,children)` 表示组。`Document::new` 会分离传入的组数组。`document.children()`、`document.node(path)` 也会分离可变数组。已创建的图像和属性内部存储不对外公开；旧文档、撤销版本之间可以安全共享不可变像素。

路径从上往下以 0 开始：`[0]` 是最上面的节点，`[0,2]` 是第一个组里的第三个节点。空数组代表根的子列表，不能用来指代某个图层。最上面的节点在合成时覆盖下面的节点。

## 编辑与导出

| 方法 | 行为 |
| --- | --- |
| `set_properties(path, properties)` | 替换标准属性，保留原扩展属性；返回新文档 |
| `replace_extra(path, pairs)` | 替换扩展属性并复制输入；拒绝标准属性名、重复名和无效 XML 属性名 |
| `replace_image(path, image)` | 更换某一栅格层的全部像素，保留其属性；不接受组 |
| `insert(parent, index, node)` | 插入图层或组，索引允许等于目标子列表长度 |
| `remove(path)` | 删除整个节点及其子树 |
| `reorder(path, index)` | 在原父组内改顺序，索引是移动后的顺序 |
| `duplicate(path, name=...)` | 在原节点上方放一个副本，复制组结构、隔离方式、扩展属性；共享不可变像素 |
| `move_to(source, parent, index)` | 跨组移动；`parent` 按原树解析，`index` 按删除源节点后的目标列表计算；拒绝移进自身或后代 |
| `layer_png(path)` | 导出图层本来的像素，保留原尺寸，不把位置、透明度或混合效果烘焙进去 |
| `layers_zip()` | 导出安全顺序文件名的 PNG 和 `layers.json`，记录名称、路径和基本属性；这是素材提取，不是 ORA |
| `render().encode_png()` | 把当前所有可见图层合成整张 PNG |
| `write()` | 重新合成，生成 ORA、新预览和缩略图；不会沿用过期预览 |
| `compatibility_warnings()` | 提示已知跨软件差异；目前包含 `svg:plus` 与 Krita Addition 的差异 |
| `image.resize_nearest(w,h)` | 缩略预览用最近邻缩放，不改变源图像；最终导出不使用网页预览尺寸 |

组的 X/Y 不参与 OpenRaster 合成，写出时省略。组透明度与逐层透明度不同。`Isolate` 先合成整组再叠加；`Auto` 按规范透传，需要结合混合方式理解。无需为了移动组内的某个图案而移动整个组；选中该图案所在的独立图层即可。

## 错误和兼容性

所有编辑是持久化操作：失败会抛出错误，不改变旧文档。`OraError::message()` 给出可读说明。结构、尺寸、坐标、资源和枚举错误应拒绝；不能通过小数取整或错误类型默认值悄悄修改数据。CLI 的编辑项允许省略标准属性，省略项保留原值；显式错误类型拒绝。

编辑范围包括 8 位、16 位和混合位深的 sRGB RGBA。含 16 位层的文档会用 16 位缓冲合成，`document.bit_depth()` 返回合成位深。图层 PNG 保留各自的位深，`render().encode_png()` 保留合成位深。详细色彩和保留边界见 [兼容矩阵](COMPATIBILITY.zh-CN.md)。未知混合方式在合成时抛出 `Unsupported`。未支持的 SVG 特性、未知 ICC 配置和其他渲染特性可能需要查看原始预览。`inspect(bytes)` 可查看结构和已有预览，网页进入只读并原样保存。只读并不等于能够正确合成。未知扩展属性和未引用资源可以保存，但未知属性的应用语义不因此得到支持。

尺寸每边最多 16,384、总像素最多 16,777,216；坐标为 ±1,000,000 内整数；不透明度 0～1。文档最多 4096 节点、128 层嵌套，解码图层预算 128 MiB；归档和渲染还有独立预算。运行时实际内存包括数组和编码缓冲区，会高于逻辑 RGBA 字节数。

`svg:plus` 保持 W3C 规则，网页和 CLI 会提示它与 Krita Addition 可能不同。不要把有提示的跨软件像素差异理解为无条件兼容。

## 安装内容

Mooncakes 提供核心库、CLI、示例、核心测试、说明和完整许可证。完整网页、演示素材及贡献者工具保留在 GitHub 仓库；需要体验网页时按 [README](../README.md) 克隆并启动即可。开发检查方法见 [开发与贡献](../CONTRIBUTING.md)。
