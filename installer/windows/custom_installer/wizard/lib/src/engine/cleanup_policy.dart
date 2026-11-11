/// 退出后清理脚本生成（纯逻辑，可单测）。
///
/// 背景：原实现用可见 cmd 窗口执行 `ping -n 3 & rmdir /s /q`，
/// 用户一点击/选中窗口文字就进入 QuickEdit「选择」模式，控制台挂起，
/// 窗口永远关不掉。改为由 ShellExecute(SW_HIDE) 启动的隐藏 PowerShell
/// 脚本：先等向导进程退出，再重试删除被占用文件、清理会话目录、自删。
library;

/// PowerShell 单引号字符串字面量转义。
String psQuote(String value) => "'${value.replaceAll("'", "''")}'";

String buildCleanupScript({
  required String session,
  required List<String> leftovers,
}) {
  final lines = <String>[
    '# AuraDSP Setup post-exit cleanup (hidden window)',
    'Start-Sleep -Seconds 2',
    // PowerShell 数组字面量不接受尾随逗号（会报「',' 后缺少表达式」），
    // 用单行 join；空列表自然得到 @()。
    '\$targets = @(${leftovers.map(psQuote).join(', ')})',
    'foreach (\$t in \$targets) {',
    '  for (\$i = 0; \$i -lt 8; \$i++) {',
    '    try { Remove-Item -LiteralPath \$t -Force -ErrorAction Stop; break }',
    '    catch { Start-Sleep -Milliseconds 500 }',
    '  }',
    '}',
    if (session.isNotEmpty)
      'Remove-Item -LiteralPath ${psQuote(session)} -Recurse -Force '
          '-ErrorAction SilentlyContinue',
    'Remove-Item -LiteralPath \$PSCommandPath -Force -ErrorAction SilentlyContinue',
  ];
  return '${lines.join('\n')}\n';
}
