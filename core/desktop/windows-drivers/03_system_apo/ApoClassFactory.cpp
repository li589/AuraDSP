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
    // 聚合只支持 IUnknown（教科书规则）。
    if (pUnkOuter && iid != IID_IUnknown) return CLASS_E_NOAGGREGATION;
    auto* apo = new (std::nothrow) CAuraApo(pUnkOuter);
    if (!apo) return E_OUTOFMEMORY;
    const HRESULT hr = apo->QueryInterface(iid, ppv);
    apo->Release();  // QI 成功已 AddRef；失败则此处析构
    return hr;
}

HRESULT __stdcall ApoClassFactory::LockServer(BOOL bLock) {
    if (bLock)
        InterlockedIncrement(&lockCount);
    else
        InterlockedDecrement(&lockCount);
    return S_OK;
}
