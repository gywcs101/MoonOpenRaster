# 开发与贡献

本文面向修改本项目源码、补充测试或检查分发内容的贡献者。日常使用请从 [README](README.md) 开始。

以下命令均在完整 GitHub 仓库的根目录运行。Mooncakes 核心库包不包含网页素材、开发脚本和浏览器测试；需要这些内容时请克隆仓库。

## 实现分工

| 目录或文件 | 职责 | 语言 |
| --- | --- | --- |
| 根目录 `*.mbt` | ORA 文档模型、归档语义、PNG 接入、图层编辑、像素合成、写回与核心测试 | MoonBit |
| `bridge/` | 网页调用入口、文档状态、撤销重做与预览调度 | MoonBit |
| `cmd/main/` | 命令行输入输出和参数校验 | MoonBit |
| `web/app.js`、`web/samples.js`、`web/worker.js` | 浏览器控件、图层列表、鼠标事件、练习引导和 Worker 消息 | JavaScript |
| `scripts/`、`tests/browser/` | 构建、素材准备、独立对照、性能测量和浏览器测试 | Python / JavaScript |

网页通过编译自 MoonBit 的处理核心执行读写与合成。`web/core.js` 是构建产物，已忽略，不提交到 Git。修改算法时应改 MoonBit 源码，再重新构建网页。

## 基础检查

需要 MoonBit、Node.js、Python 3；独立图像对照还需要 Pillow。

```sh
moon update
moon check --target all --deny-warn
moon test --target js --deny-warn
moon fmt --check
moon info
```

检查生成接口的变化是否符合预期。原生目标需要系统 C 工具链，Windows 需要完整 MSVC 与 Windows SDK。CI 的平台覆盖和互操作证据见 [验证记录](VALIDATION.md)。

## 独立回归

```sh
python -m pip install Pillow==11.1.0
python scripts/build_web.py
python scripts/check_image_import.py
python scripts/check_interop.py
python scripts/check_rgba16.py
python scripts/check_acceptance.py
python scripts/check_consistency.py
python scripts/check_plus.py
node scripts/check_bridge.mjs
node scripts/check_editor.mjs
node scripts/check_samples.mjs
python scripts/check_sample_pixels.py
python scripts/check_artwork.py
python scripts/check_krita.py
python scripts/check_licenses.py
python scripts/check_package.py
```

Krita 对照脚本可以额外传入本机 Krita 可执行文件路径，重新执行真实软件导出。未传入时检查仓库中的独立样例与参考像素。原生 CLI 另用 `python scripts/check_native.py` 验证。

## 浏览器回归

```sh
npm ci --prefix tests/browser
npx --prefix tests/browser playwright install --with-deps chromium
node tests/browser/check.mjs
node tests/browser/samples.mjs
python scripts/check_web_server.py
```

先运行上一节的网页构建与一致性检查，生成浏览器测试使用的核心和参考结果。测试会启动自己的本地服务，不需要关闭日常预览页面。

## 分发文件与许可

`.moonignore` 控制核心库的分发范围。`scripts/check_package.py` 检查文件清单，并在隔离目录运行源码消费者及私有字段访问的负向编译检查；它不代替正式归档或注册表安装验证。当前工具链的 `moon package --list` 仍会顺带写归档，因此脚本把这一副作用隔离到自动清理的临时目录。

`python scripts/check_licenses.py` 验证完整许可副本、上游 NOTICE、资源来源与适用范围。添加代码、字体、图片或样例时同步更新相应说明，不能只保留一个上游链接。

网页源码、样例和核心库保留在同一个 GitHub 仓库中。`scripts/package_web.py` 仅用于按需生成独立离线网页 ZIP，不是使用核心库或发布 Mooncakes 的前置步骤。

性能复测方法及测量限制见 [PERFORMANCE.md](PERFORMANCE.md)。


## 重新生成格式练习

安装 Pillow 后运行 `python scripts/build_web.py` 和 `python scripts/build_format_samples.py`。脚本生成海岸明信片、地形测绘图与夜间车站的原始素材和练习起点，再调用 MoonBit 生成参考结果。浏览器样例测试逐步重放三套练习，并将下载的 PNG 与参考成图比较。授权见 [许可索引](LICENSES/README.md)。
