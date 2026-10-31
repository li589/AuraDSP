import '../../../../platform/platform_profile.dart';
import 'milkdrop_preset.dart';

/// External projectM (MilkDrop 2) C ABI specification:
///
/// ```c
/// typedef void* auradsp_projectm_t;
///
/// auradsp_projectm_t auradsp_projectm_create(int width, int height, float fps);
/// void               auradsp_projectm_destroy(auradsp_projectm_t handle);
/// void               auradsp_projectm_resize(auradsp_projectm_t handle, int width, int height);
/// int                auradsp_projectm_feed_pcm(auradsp_projectm_t handle, const float* pcm, int frames, int channels);
/// int                auradsp_projectm_load_preset(auradsp_projectm_t handle, const char* preset_path);
/// int64_t            auradsp_projectm_render_to_texture(auradsp_projectm_t handle);
/// ```

/// High-level Dart interface contract for libprojectM external visualizer engine
abstract interface class ProjectMBridge {
  bool get isAvailable;
  bool get isLoaded;
  MilkdropPreset? get currentPreset;

  Future<bool> initialize({int width = 1280, int height = 720, double fps = 60.0});
  void resize(int width, int height);
  bool loadPreset(MilkdropPreset preset);
  void feedPcm(List<double> pcmFrames);
  int? renderFrame();
  void dispose();
}

/// Fallback / mock bridge when native libprojectM is unlinked or on unsupported OS
class MockProjectMBridge implements ProjectMBridge {
  MilkdropPreset? _preset;

  @override
  bool get isAvailable => PlatformProfile.supportsPlugins;

  @override
  bool get isLoaded => _preset != null;

  @override
  MilkdropPreset? get currentPreset => _preset;

  @override
  Future<bool> initialize({int width = 1280, int height = 720, double fps = 60.0}) async {
    return true;
  }

  @override
  void resize(int width, int height) {}

  @override
  bool loadPreset(MilkdropPreset preset) {
    _preset = preset;
    return true;
  }

  @override
  void feedPcm(List<double> pcmFrames) {}

  @override
  int? renderFrame() => null;

  @override
  void dispose() {
    _preset = null;
  }
}
