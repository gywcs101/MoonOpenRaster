# 16 位 OpenRaster 编辑往返

本案例使用项目自制的 32 × 20 分层渐变。顶层组包含 Light，底层为 Base。两层均含无法用 8 位通道精确表达的样本。

在仓库根目录执行：

```sh
python scripts/check_rgba16.py
```

脚本执行与下面相同的编辑指令。CLI 要求输出路径尚不存在。

```sh
moon run cmd/main --target js -- edit fixtures/gradient16.ora gradient16-edited.ora fixtures/gradient16-edits.json
```

也可用本地工作台打开 `fixtures/gradient16.ora`，选中 Light，将 X 改为 9、Y 改为 6、不透明度改为 50%，点击“应用修改”，再保存 ORA。重开后应保留组、图层和位深。

独立验证逐样本核对源层及新合并图。在修改后覆盖区，前景和背景各占一半。归档检查会核对输出仍是 16 位、预览已更新、缩略图为 8 位非隔行，以及图层的位置、不透明度和层级都正确。脚本输出位于 `_build/rgba16/`。

## Krita 5.3.4 重开

用实际 Krita 5.3.4 对修改结果重新打开和导出。为避免 Krita 针对每张 16 位图层询问配置，测试命令可传入 Krita 安装自带的 `sRGB-elle-V2-srgbtrc.icc`。脚本只在临时副本中把 sRGB 标记改为对应 ICC，独立确认修改前后样本一致。打开 MoonBit 原始输出时如果弹出配置框，选择同名非线性 sRGB 配置。

```sh
python scripts/check_rgba16.py --krita PATH_TO_KRITA --krita-profile PATH_TO_SRGB_ICC
```

实测 Krita 重开后保留图层层级、位置和不透明度。导出画面的 8 位比较最大通道差为 1。Krita 5.3.4 把本例重存为 ORA 后，两层 PNG 均变为 8 位；单张 16 位 PNG 导入 Krita 后直接导出 ORA 的探测也得到 8 位层。案例输入因此用独立生成器制作，16 位精度由独立 PNG 解码与 MoonBit 重开验证。Krita 负责独立检验结构和可见结果。
