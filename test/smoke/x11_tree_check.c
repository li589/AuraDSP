/*
 * x11_tree_check.c — 门禁 [editor] 节的 X 侧见证工具。
 *
 * 连当前 DISPLAY，递归遍历根窗口树，把每个窗口的 WM_NAME 打到
 * stdout（一行一个，无名窗口跳过）。门禁据此断言编辑器容器窗口
 * （标题由 show_editor 传入）与插件子窗口（探针固定名）真实存在
 * 于 X 服务器——引擎侧 is_editor_open 之外的独立证据。
 * 退出码：0 = 已连接并遍历；1 = 连不上显示。
 *
 * 不依赖 libx11-dev：X11 类型/函数按稳定 ABI 自带声明，链接以
 * -l:libX11.so.6 直指运行时 SONAME（CI 的 J3 无 X11 开发包）。
 */
#include <stdio.h>
#include <stdlib.h>

#include "x11_min.h"

static void walk(Display *dpy, Window win, int depth) {
    char *name = NULL;
    if (XFetchName(dpy, win, &name) && name) {
        printf("%s\n", name);
        XFree(name);
    }
    Window root = 0, parent = 0, *children = NULL;
    unsigned n = 0;
    if (depth < 8 && XQueryTree(dpy, win, &root, &parent, &children, &n)) {
        for (unsigned i = 0; i < n; ++i) walk(dpy, children[i], depth + 1);
        if (children) XFree(children);
    }
}

int main(void) {
    Display *dpy = XOpenDisplay(NULL);
    if (!dpy) return 1;
    walk(dpy, XRootWindow(dpy, XDefaultScreen(dpy)), 0);
    XCloseDisplay(dpy);
    return 0;
}
