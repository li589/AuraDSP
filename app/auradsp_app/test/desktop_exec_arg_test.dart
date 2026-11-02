import 'package:flutter_test/flutter_test.dart';

import 'package:auradsp_app/platform/autostart/autostart_linux.dart';

// 打磨·安全审查（2026-11-02）：desktop-entry Exec 参数转义。
void main() {
  test('plain path is simply quoted', () {
    expect(desktopExecArg('/opt/AuraDSP/auradsp'), '"/opt/AuraDSP/auradsp"');
  });

  test('quote, dollar, backtick and backslash are escaped', () {
    expect(desktopExecArg(r'/home/a"b/auradsp'), r'"/home/a\"b/auradsp"');
    expect(desktopExecArg(r'/home/$USER/auradsp'), r'"/home/\$USER/auradsp"');
    expect(desktopExecArg('/home/`x`/auradsp'), r'"/home/\`x\`/auradsp"');
    expect(desktopExecArg(r'C:\odd\auradsp'), r'"C:\\odd\\auradsp"');
  });
}
