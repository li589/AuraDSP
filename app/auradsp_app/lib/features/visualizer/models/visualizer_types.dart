/*
 * 迁移壳（2026-10-31）：可视化配置模型已升格至 `lib/core/visualizer_types.dart`
 *（预设/会话记忆需要 AppModel 持有该状态，而 core/ 不得依赖 features/）。
 * 本文件仅 re-export，保持所有特性侧既有 import 路径不变。
 */
export '../../../core/visualizer_types.dart';
