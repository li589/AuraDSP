import java.lang.reflect.Constructor;
import java.util.UUID;

public class MiniAttach {
    public static void main(String[] args) throws Exception {
        UUID type = UUID.fromString("0bed4300-ddd6-11db-8f34-0002a5d5c51b"); // EFFECT_TYPE_EQUALIZER
        UUID impl = UUID.fromString("8e73f7a1-3c92-4f6b-9d5e-7a1b2c3d4e5f"); // SpikeEQ impl
        Class<?> cls = Class.forName("android.media.audiofx.AudioEffect");
        Constructor<?> ctor = cls.getDeclaredConstructor(UUID.class, UUID.class, int.class, int.class);
        ctor.setAccessible(true);
        System.out.println("[MiniAttach] creating AudioEffect on global session 0 ...");
        Object ef = ctor.newInstance(type, impl, 0, 0);
        java.lang.reflect.Method getId = cls.getMethod("getId");
        java.lang.reflect.Method getEnabled = cls.getMethod("getEnabled");
        System.out.println("[MiniAttach] created, id=" + getId.invoke(ef) + " enabled=" + getEnabled.invoke(ef));
        java.lang.reflect.Method setEnabled = cls.getMethod("setEnabled", boolean.class);
        setEnabled.invoke(ef, true);
        System.out.println("[MiniAttach] enabled OK, keeping alive 20s ...");
        Thread.sleep(20000);
        cls.getMethod("release").invoke(ef);
        System.out.println("[MiniAttach] released.");
    }
}
