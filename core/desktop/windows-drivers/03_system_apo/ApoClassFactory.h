// ApoClassFactory.h — 裸 COM 类厂（EAPO ClassFactory 同式，自写）。
#pragma once

#include <Unknwn.h>

class ApoClassFactory : public IClassFactory {
 public:
    ApoClassFactory();
    virtual ~ApoClassFactory();

    virtual HRESULT __stdcall QueryInterface(REFIID iid, void** ppv) override;
    virtual ULONG __stdcall AddRef() override;
    virtual ULONG __stdcall Release() override;

    virtual HRESULT __stdcall CreateInstance(IUnknown* pUnkOuter, REFIID iid,
                                             void** ppv) override;
    virtual HRESULT __stdcall LockServer(BOOL bLock) override;

    static long lockCount;

 private:
    long m_ref = 1;
};
