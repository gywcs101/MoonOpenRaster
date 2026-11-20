# MoonOpenRaster

MoonOpenRaster 是用 MoonBit 编写的 **OpenRaster（`.ora`）16 位与 8 位分层栅格图像读写、编辑与合成库**，配有命令行和本地网页工作台。

普通 PNG 只保留最终画面；ORA 还保存独立图层、分组、位置、透明度和混合方式。本项目可以读取这些图层，修改后重新计算画面，再保存为仍可编辑的 ORA。例如：批量隐藏草稿层并导出预览、替换海报中的独立图片层，或为绘图程序添加 ORA 导入与导出功能。

[Mooncakes 包与接口文档](https://mooncakes.io/docs/gywcs101/MoonOpenRaster) · [网页使用说明](docs/WORKBENCH.zh-CN.md) · [库 API 说明](docs/API.zh-CN.md)

## 能做什么

- 读取与写入 ORA，保存嵌套图层树、图层属性和可保留的扩展资源。
- 创建、删除、重命名、复制、重排和跨组移动图层，支持用 PNG、JPEG、静态 WebP、GIF、BMP、TIFF、ICO 或受支持的 SVG 导入和替换图层。
- 调整可见性、整数位置、不透明度和混合方式，支持 20 种基线 SVG 合成操作及组隔离。
- 导出整张 PNG、单层 PNG 或全部图层素材；保存 ORA 时重新生成合并预览和缩略图。
- 在网页中实时预览拖动、撤销重做，并通过四份真实分层作品及三套原创图片格式练习了解图层编辑。

## 体验网页

需要 **MoonBit 0.10.20、Node.js 和 Python 3**，以下步骤在完整 GitHub 仓库中运行：

```sh
git clone https://github.com/gywcs101/MoonOpenRaster.git
cd MoonOpenRaster
moon update
python scripts/serve_web.py
```

浏览器打开 **http://127.0.0.1:8765/**，保持终端运行；按 `Ctrl+C` 停止。端口已占用时可使用 `python scripts/serve_web.py --port 8766`，并访问相应端口。Windows 使用 PowerShell 也可以直接运行这些命令。

启动后会载入 David Revoy 的真实分层插画。选择图层后，可以拖动蓝色选框、切换眼睛、修改属性，或在“样例与练习”中跟随指引完成改图，再导出 PNG 或保存 ORA。拖动移动的是**整个选中图层**，不会自动拆分层内物体；修改图层名称也不会改变画面里的文字。

点击左侧「导入图片」添加新图层，或选择已有图层后在右侧点击「替换图片」。GIF 取第一帧，TIFF 取第一页。保存 ORA 时，栅格素材存为 PNG，SVG 图层保留原始源文件。打开「样例与练习 → 图片格式练习」，可直接使用案例素材验证八种格式的导入、替换和编辑。支持范围见 [兼容矩阵](docs/COMPATIBILITY.zh-CN.md)。

字体和样例随仓库提供，处理期间图像不会上传服务器。浏览器导入上限为 32 MiB。更多操作见 [网页使用说明](docs/WORKBENCH.zh-CN.md)。

## 在 MoonBit 项目中使用

从 Mooncakes 安装 0.2.0 即可使用 8 位和 16 位图层编辑、自包含静态 SVG 图层及图片格式导入。网页工作台和示例素材随 GitHub 仓库提供。

```sh
moon add gywcs101/MoonOpenRaster@0.2.0
```

在使用它的包的 `moon.pkg` 中添加导入：

```moonbit
import {
  "gywcs101/MoonOpenRaster" @ora,
}
```

下面的例子创建一个图层、修改名称和位置、合成 PNG，并保存与重新读取 ORA。代码中的 `archive` 和 `png` 都是字节数据，文件保存由调用程序处理。

```moonbit
fn main raise {
  let image = @ora.Image::new(1, 1, [255, 0, 0, 255])
  let layer = @ora.Node::Layer(@ora.Properties::new("红色图层"), image)
  let document = @ora.Document::new(4, 4, [layer])
  let edited = document.set_properties(
    [0],
    @ora.Properties::new("移动后的图层", x=1, y=1),
  )
  let archive = edited.write()
  let reopened = @ora.read(archive)
  let png = reopened.render().encode_png()
  println(png.length())
}
```

这是可执行包示例；在 `moon.pkg` 中另加 `pkgtype(kind: "executable")`，然后运行 `moon run . --target js`。在现有库函数中使用时，无需将包改为可执行类型。

编辑方法返回新文档，原文档保持不变。路径从栈顶按 0 编号：`[0]` 表示最上面的节点，`[0,2]` 表示第一个组内的第三个节点。完整方法、错误约定与更多示例见 [库 API 说明](docs/API.zh-CN.md)。

## 命令行使用

在克隆的仓库根目录运行，输入路径替换为自己的文件：

```sh
moon run cmd/main --target js -- inspect drawing.ora
moon run cmd/main --target js -- render drawing.ora composite.png
moon run cmd/main --target js -- edit drawing.ora changed.ora edits.json
```

三条命令分别查看图层结构、合成整张 PNG，以及按 JSON 指令修改后保存 ORA。输出路径必须尚不存在。

`edits.json` 示例：将第一个组里的第一层改名、移动并设为半透明。省略的属性保留原值，坐标必须为范围内整数。

```json
[{"path":[0,0],"name":"移动后的图层","x":20,"y":10,"visible":true,"opacity":0.5,"composite_op":"svg:src-over"}]
```

## 16 位 ORA 往返

在网页打开 16 位渐变样例，选中 Light 图层，把 X 改为 9、Y 改为 6，并将不透明度设为 50%。保存并重新打开 ORA，仍可继续编辑图层。新合并图保留 16 位精度。[下载样例](https://github.com/gywcs101/MoonOpenRaster/blob/main/fixtures/gradient16.ora) · [案例与复现说明](docs/ROUNDTRIP16.zh-CN.md)

## SVG 矢量图层

工作台可以直接导入支持的静态 SVG，也可以打开含 SVG 图层的 ORA。仓库版本支持内部 CSS、图形复用以及随 ORA 一起保存的相对路径 CSS、PNG 和 SVG 片段，也支持使用 `@font-face` 声明的随稿字体渲染文字、嵌套片段和沿路径排列的字形。图层支持移动、显隐、透明度、混合、复制和排序。合成时按 SVG 的像素尺寸或 `viewBox` 渲染，保存 ORA 时保留源文件；导出 PNG 时输出合成像素。在「样例与练习 → 地形测绘图」中，可以将 SVG 等高线与 16 位 TIFF 地形放在同一文档。

## 兼容性与限制

- 交付目标为 **OpenRaster 0.0.6 Full baseline**，当前已验证的栅格编辑流程包括 8 位与 16 位每通道的 sRGB 图层、混合位深、嵌套组、负偏移及 20 种基线合成操作。各图层按原精度保存，含 16 位层时重新生成 16 位合成，归档缩略图为 8 位。
- 未标记色彩的 PNG 按 sRGB 处理。仓库版本还可将矩阵型与受支持的查找表 ICC、PNG gamma 和色度，以及常见全范围 SDR cICP 转为 sRGB。保存 ORA 时保留转换过的原图层 PNG。其他色彩配置与 SVG 限制见 [兼容矩阵](docs/COMPATIBILITY.zh-CN.md)。
- `svg:plus` 遵循 W3C 规则，和 Krita Addition 可能有像素差异。Krita 5.3.4 可重开本项目的案例，但实测其 ORA 重存会将图层变回 8 位。
- 单图和画布最多 16,777,216 像素、单边 16,384，解码图层总预算为 128 MiB。16 位 RGBA 每像素占 8 字节，文件还受归档和渲染缓冲区限制。详见 [兼容矩阵](docs/COMPATIBILITY.zh-CN.md)。

## 文档与许可

- [网页使用说明](docs/WORKBENCH.zh-CN.md)：工作台操作、图层含义与练习。
- [库 API 说明](docs/API.zh-CN.md)：文档模型、编辑接口、导出与错误处理。
- [开发与贡献](CONTRIBUTING.md)：构建、回归测试、浏览器验证和分发检查。

项目代码使用 [MIT 许可证](LICENSE)。网页中的作品、字体与第三方组件各自遵循其许可，完整文本、来源及修改说明见 [LICENSES](LICENSES/README.md) 和 [THIRD_PARTY.md](THIRD_PARTY.md)。ZIP、XML 与图片编解码复用 MoonBit 生态组件，OpenRaster 文档语义、编辑与合成在本项目实现。
