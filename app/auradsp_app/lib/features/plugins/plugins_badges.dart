// part of plugins_page.dart —— P1 按区拆分，纯搬运零改行。
part of '../plugins_page.dart';
class _FeatureBadge extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _FeatureBadge({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    // 2026-10-28：徽标文案可能很长（英文尤其），窄窗口下必须允许换行，
    // 否则 Row 直接溢出视口（无障碍/窄宽度回归）。
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            label,
            softWrap: true,
            style: captionOf(p, color: p.text),
          ),
        ),
      ],
    );
  }
}
