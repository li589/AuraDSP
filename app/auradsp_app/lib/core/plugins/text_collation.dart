// text_collation.dart —— 插件列表用的确定性排序键。
//
// 目标（2026-10-28）：厂商与插件名按「字典序」排列且跨语言稳定。
// Dart 标准库没有 ICU collator（intl 也不提供），这里实现一个
// 确定性、无外部数据依赖的比较器：
//
// 1. 大小写折叠（A == a）；
// 2. 拉丁变音符号折叠（é/ü/ñ/ø/å → e/u/n/o/a，覆盖 Latin-1 Supplement 与
//    Latin Extended-A 常用段）——否则同一厂商因写法差异被拆成两组；
// 3. 数字自然序（"Plugin 2" 排在 "Plugin 10" 之前）；
// 4. 标点/空白参与比较但权重最低（先比较去标点的主键，再回退原文比较），
//    避免 "ACME, Inc." 与 "ACME Inc" 分开；
// 5. 非拉丁文字（中日韩等）按 Unicode 码位稳定排序——不依赖系统区域设置，
//    跨机器结果一致（不承诺拼音序，拼音排序需 ICU 数据，明确不做）。
//
// 只用于 UI 展示排序，不参与任何协议/持久化键。
abstract final class TextCollation {
  /// 比较两个展示名。空串排最后（厂商缺失的插件沉底，而不是抢占头部）。
  static int compare(String a, String b) {
    final ae = a.trim().isEmpty;
    final be = b.trim().isEmpty;
    if (ae && be) return 0;
    if (ae) return 1;
    if (be) return -1;

    final ka = _primary(a);
    final kb = _primary(b);
    // 纯标点名（主键为空）与空名同待遇：沉底，不抢占列表头部。
    if (ka.isEmpty != kb.isEmpty) return ka.isEmpty ? 1 : -1;
    final c = _naturalCompare(ka, kb);
    if (c != 0) return c;
    // 主键相等（仅大小写/变音/标点差异）时用原文兜底，保证全序稳定。
    return a.compareTo(b);
  }

  /// 去空白与常见标点、数字保留。返回折叠后的字符序列。
  static String _primary(String input) {
    final out = StringBuffer();
    for (final rune in input.runes) {
      final folded = _foldRune(rune);
      if (folded == null) continue; // 空白/标点：不参与主键
      out.writeCharCode(folded);
    }
    return out.toString();
  }

  /// 单字符折叠；null = 该字符属于分隔/标点（主键忽略）。
  static int? _foldRune(int rune) {
    // ASCII 快速路径
    if (rune >= 0x30 && rune <= 0x39) return rune; // 0-9
    if (rune >= 0x41 && rune <= 0x5A) return rune + 0x20; // A-Z
    if (rune >= 0x61 && rune <= 0x7A) return rune; // a-z
    if (rune < 0x80) return null; // 其它 ASCII：空白/标点，忽略

    final mapped = _diacritics[rune];
    if (mapped != null) return mapped;

    // 希腊/西里尔等有大小写之分的字母：用 Dart 的 toLowerCase 折叠。
    final s = String.fromCharCode(rune).toLowerCase();
    if (s.length == 1) {
      final code = s.codeUnitAt(0);
      // 标点类（Unicode P*/S*）不参与主键：常见区间足够覆盖文件命名。
      if (_isPunctuation(code)) return null;
      return code;
    }
    return rune;
  }

  static bool _isPunctuation(int code) {
    // 常见标点区间（拉丁补充、通用标点、CJK 标点）。
    return (code >= 0x2000 && code <= 0x206F) ||
        (code >= 0x3000 && code <= 0x303F) ||
        (code >= 0xFF00 && code <= 0xFF65 &&
            !(code >= 0xFF10 && code <= 0xFF19) &&
            !(code >= 0xFF21 && code <= 0xFF3A) &&
            !(code >= 0xFF41 && code <= 0xFF5A));
  }

  /// 自然序：数字段按数值比较（"2" < "10"），其余逐码位。
  static int _naturalCompare(String a, String b) {
    var i = 0;
    var j = 0;
    while (i < a.length && j < b.length) {
      final ca = a.codeUnitAt(i);
      final cb = b.codeUnitAt(j);
      final da = _isDigit(ca);
      final db = _isDigit(cb);
      if (da && db) {
        var i2 = i;
        while (i2 < a.length && _isDigit(a.codeUnitAt(i2))) {
          i2++;
        }
        var j2 = j;
        while (j2 < b.length && _isDigit(b.codeUnitAt(j2))) {
          j2++;
        }
        final na = int.tryParse(a.substring(i, i2));
        final nb = int.tryParse(b.substring(j, j2));
        if (na != null && nb != null && na != nb) {
          return na.compareTo(nb);
        }
        // 数值相等（如前导零差异）：按数字段长度再比较，保证确定。
        final lenCmp = (i2 - i).compareTo(j2 - j);
        if (lenCmp != 0) return lenCmp;
        i = i2;
        j = j2;
        continue;
      }
      if (ca != cb) return ca.compareTo(cb);
      i++;
      j++;
    }
    return (a.length - i).compareTo(b.length - j);
  }

  static bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

  /// 拉丁变音折叠表（Latin-1 Supplement + Latin Extended-A 常用段）。
  /// 值一律为小写 ASCII 码位。
  static final Map<int, int> _diacritics = _buildDiacritics();

  static Map<int, int> _buildDiacritics() {
    const groups = <String, String>{
      'a': 'àáâãäåāăą',
      'c': 'çćĉċč',
      'd': 'ďđ',
      'e': 'èéêëēĕėęě',
      'g': 'ĝğġģ',
      'h': 'ĥħ',
      'i': 'ìíîïĩīĭįı',
      'j': 'ĵ',
      'k': 'ķ',
      'l': 'ĺļľŀł',
      'n': 'ñńņňŉ',
      'o': 'òóôõöøōŏő',
      'r': 'ŕŗř',
      's': 'śŝşš',
      't': 'ţťŧ',
      'u': 'ùúûüũūŭůűų',
      'w': 'ŵ',
      'y': 'ýÿŷ',
      'z': 'źżž',
      'ae': 'æ',
      'oe': 'œ',
      'ss': 'ß',
      'th': 'þ',
    };
    final map = <int, int>{};
    groups.forEach((target, chars) {
      final lower = target.codeUnitAt(0);
      for (final r in chars.runes) {
        map[r] = lower;
      }
    });
    return map;
  }

  /// 组内插件排序键：先按名称，再按格式/路径兜底，保证稳定。
  static int comparePluginNames(String a, String b, String aPath, String bPath) {
    final c = compare(a, b);
    if (c != 0) return c;
    final p = aPath.toLowerCase().compareTo(bPath.toLowerCase());
    return p != 0 ? p : 0;
  }

  /// 分组键：空白/未知厂商统一归入空串（UI 显示“未知厂商”）。
  static String vendorKey(String vendor) {
    final v = vendor.trim();
    if (v.isEmpty) return '';
    final lower = v.toLowerCase();
    if (lower == 'unknown' || lower == '未知' || lower == '未知厂商') return '';
    return v;
  }
}
