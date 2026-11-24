# -*- coding: utf-8 -*-
"""任意 Windows 主机上的 AuraDSP ASIO 驱动注册探针。

枚举 HKLM/HKCU 的 SOFTWARE\\ASIO 名单，读 AuraDSP Driver 的 CLSID 与
InprocServer32 指向的 DLL（存在则报 mtime/大小，并粗查二进制内的
遥测字段标记）。用于区分「驱动没注册 / 注册指向旧 DLL / 注册正确」
三种状态——注意开发机当前无注册（REAPER 实测在宾机），探针在本机
跑出空名单不等于宾机没装。

用法：python asio_registration_probe.py
"""
import datetime
import os
import winreg

CLSID = r'{4B617572-6144-5350-4153-494F44727631}'


def enum_asio(root, path):
    try:
        k = winreg.OpenKey(root, path)
        names = [winreg.EnumKey(k, i)
                 for i in range(winreg.QueryInfoKey(k)[0])]
        print(path, '->', names)
        return names
    except Exception as e:
        print(path, 'ERR', e)
        return []


def main():
    enum_asio(winreg.HKEY_LOCAL_MACHINE, r'SOFTWARE\ASIO')
    enum_asio(winreg.HKEY_CURRENT_USER, r'SOFTWARE\ASIO')
    for root, rn in ((winreg.HKEY_LOCAL_MACHINE, 'HKLM'),
                     (winreg.HKEY_CURRENT_USER, 'HKCU')):
        try:
            k = winreg.OpenKey(root, r'SOFTWARE\ASIO\AuraDSP Driver')
            print(rn, 'AuraDSP Driver CLSID =',
                  winreg.QueryValueEx(k, 'CLSID')[0])
        except Exception as e:
            print(rn, 'AuraDSP Driver key ERR', e)
    try:
        k = winreg.OpenKey(winreg.HKEY_CLASSES_ROOT,
                           r'CLSID\%s\InprocServer32' % CLSID)
        p = winreg.QueryValueEx(k, None)[0]
        print('InprocServer32 =', p)
        if p and os.path.exists(p):
            st = os.stat(p)
            print('  mtime', datetime.datetime.fromtimestamp(st.st_mtime),
                  'size', st.st_size)
            data = open(p, 'rb').read()
            print('  has v3 marker peakInCh:', b'peakInCh' in data)
    except Exception as e:
        print('HKCR CLSID ERR', e)
    print('probe done')


if __name__ == '__main__':
    main()
