#pragma once
/*
 * x11_min.h — X11 最小 ABI 声明（门禁探针与见证工具共用）。
 *
 * 免 libx11-dev 依赖：类型/函数按稳定 ABI 自带声明，链接以
 * -l:libX11.so.6 直指运行时 SONAME（CI 的 J3 无 X11 开发包，
 * 只有运行时库）。仅覆盖编辑器探针用到的函数子集；与真实
 * <X11/Xlib.h> 二选一包含，不可同编。
 */
#ifdef __cplusplus
extern "C" {
#endif

typedef unsigned long Window;
typedef struct _XDisplay Display;

/* XEvent 的完整空间（192B/64 位）；探针只泵不用其字段。 */
typedef union {
    long _pad[32];
    int type;
} XEvent;

Display *XOpenDisplay(const char *name);
int XCloseDisplay(Display *dpy);
int XDefaultScreen(Display *dpy);
Window XRootWindow(Display *dpy, int screen);
Window XCreateSimpleWindow(Display *dpy, Window parent, int x, int y,
                           unsigned width, unsigned height,
                           unsigned border_width, unsigned long border,
                           unsigned long background);
int XDestroyWindow(Display *dpy, Window win);
int XStoreName(Display *dpy, Window win, const char *name);
int XSelectInput(Display *dpy, Window win, long mask);
int XMapWindow(Display *dpy, Window win);
int XUnmapWindow(Display *dpy, Window win);
int XResizeWindow(Display *dpy, Window win, unsigned width, unsigned height);
int XFlush(Display *dpy);
int XPending(Display *dpy);
int XNextEvent(Display *dpy, XEvent *event);
int XFetchName(Display *dpy, Window win, char **name);
int XQueryTree(Display *dpy, Window win, Window *root, Window *parent,
               Window **children, unsigned *n);
int XFree(void *data);

#ifdef __cplusplus
}
#endif

#define ExposureMask (1L << 15)
#define StructureNotifyMask (1L << 17)
