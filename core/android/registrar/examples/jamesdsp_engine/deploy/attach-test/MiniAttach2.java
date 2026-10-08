import java.lang.reflect.Constructor;
import java.util.UUID;

/**
 * MiniAttach2 — 参数化 attach 验证器（shell 级 app_process 反射 hidden 构造）。
 *
 * 用法: app_process / MiniAttach2 [implUUID] [holdMs]
 *   implUUID 缺省 = SpikeEQ (8e73f7a1-...)
 *   AuraDSP libjdsp: 6d5d0f7a-3c1e-4a9b-8b2d-9f0a1c2d3e4f
 */
public class MiniAttach2 {
    public static void main(String[] args) throws Exception {
        UUID type = UUID.fromString("0bed4300-ddd6-11db-8f34-0002a5d5c51b"); // EFFECT_TYPE_EQUALIZER
        UUID impl = UUID.fromString(args.length > 0
                ? args[0] : "8e73f7a1-3c92-4f6b-9d5e-7a1b2c3d4e5f");
        long holdMs = args.length > 1 ? Long.parseLong(args[1]) : 20000L;
        Class<?> cls = Class.forName("android.media.audiofx.AudioEffect");
        Constructor<?> ctor = cls.getDeclaredConstructor(UUID.class, UUID.class, int.class, int.class);
        ctor.setAccessible(true);
        System.out.println("[MiniAttach2] creating AudioEffect impl=" + impl + " on global session 0 ...");
        Object ef = ctor.newInstance(type, impl, 0, 0);
        java.lang.reflect.Method getId = cls.getMethod("getId");
        java.lang.reflect.Method getEnabled = cls.getMethod("getEnabled");
        System.out.println("[MiniAttach2] created, id=" + getId.invoke(ef) + " enabled=" + getEnabled.invoke(ef));
        java.lang.reflect.Method setEnabled = cls.getMethod("setEnabled", boolean.class);
        setEnabled.invoke(ef, true);
        System.out.println("[MiniAttach2] enabled OK, keeping alive " + holdMs + "ms ...");
        Thread.sleep(holdMs);
        cls.getMethod("release").invoke(ef);
        System.out.println("[MiniAttach2] released.");
    }
}
