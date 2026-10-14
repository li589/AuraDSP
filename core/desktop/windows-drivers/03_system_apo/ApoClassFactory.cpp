// ApoClassFactory.cpp
#include "ApoClassFactory.h"

#include <new>
#include <windows.h>

#include "AuraApo.h"
#include "AuraApoGuid.h"

long ApoClassFactory::lockCount = 0;

ApoClassFactory::ApoClassFactory() = default;
ApoClassFactory::~ApoClassFactory() = default;

HRESULT __stdcall ApoClassFactory::QueryInterface(REFIID iid, void** ppv) {
    if (!ppv) return E_POINTER;
    if (iid == IID_IUnknown || iid == IID_IClassFactory) {
        *ppv = static_cast<IClassFactory*>(this);
        AddRef();
        return S_OK;
    }
    *ppv = nullptr;
    return E_NOINTERFACE;
}

ULONG __stdcall ApoClassFactory::AddRef() {
    return (ULONG)InterlockedIncrement(&m_ref);
}

ULONG __stdcall ApoClassFactory::Release() {
    const ULONG n = (ULONG)InterlockedDecrement(&m_ref);
    if (n == 0) delete this;
    return n;
}

HRESULT __stdcall ApoClassFactory::CreateInstance(IUnknown* pUnkOuter, REFIID iid, void** ppv) {
    if (!ppv) return E_POINTER;
    // EAPO 同式：工厂走 NonDelegating 对（返回 inner 自身引用，绝不碰 outer）。
    // 聚合只支持 IUnknown（EAPO 用 E_NOINTERFACE，同式跟随）。
    if (pUnkOuter && iid != IID_IUnknown) return E_NOINTERFACE;
    auto* apo = new (std::nothrow) CAuraApo(pUnkOuter);
    if (!apo) return E_OUTOFMEMORY;
    const HRESULT hr = apo->NonDelegatingQueryInterface(iid, ppv);
    apo->NonDelegatingRelease();
    return hr;
}

HRESULT __stdcall ApoClassFactory::LockServer(BOOL bLock) {
    if (bLock)
        InterlockedIncrement(&lockCount);
    else
        InterlockedDecrement(&lockCount);
    return S_OK;
}
