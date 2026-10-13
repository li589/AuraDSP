# assets/ — 运行声学资源（原 resource/，P3b 改名）

> 布局：`convolver/`（IR 脉冲）+ `ddc/`（VDC 耳机校正）+ `liveprog/`（EEL2 脚本）
> + `manifest.json`（1MB，清单位级别盘点，版本化）。
> 工具：`tools/resource_pipeline/clean_and_organize.py`（盘点入库）+
> `tools/resource_pipeline/build_packages.py`（分级打包 + 沙箱覆盖演练）。

## 命名冻结（改前三思）

- `.irs` / `.vdc` 大二进制不进 git（`.gitignore`），走 release 附件；
  `.eel` + `manifest.json` 体积极小，正常版本化。
- 分发 zip 名（`auradsp-resource-*.zip`）、`dist/resources`、`user_data/` 下的
  `resource_preferences.json` 文件名**一律不动**——只搬源码目录，不管安装侧命名
  （P3b 决策，已验证管线自测全绿）。
