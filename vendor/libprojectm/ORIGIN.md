# vendor/libprojectm 溯源记录

- **来源仓库**：https://github.com/projectM-visualizer/projectm.git
- **对应参考分支与提交**：`master@9e26f5b5b` (`9e26f5b5bf89b015f197a16a61bcb21f4946d985`)
- **许可证**：LGPL-2.1 (`LICENSE.txt` 声明)
- **提取范围**：
  - `include/projectM-4/`：libprojectM v4.2+ 官方公开 C-API 头文件集合（`core.h`, `audio.h`, `render_opengl.h`, `parameters.h`, `types.h` 等）。
- **定位与合规约束**：
  - 本目录为第三方头文件与预编译库隔离区，严格切断对 `source/projectm` 的直接依赖；
  - 仅暴露标准 C-ABI 给 `core/desktop/visualizer/projectm_bridge/` 与前端 Dart FFI。
