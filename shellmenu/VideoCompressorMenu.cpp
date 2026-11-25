// Windows 11 right-click menu for Video Compressor.
// Windows 11 only puts IExplorerCommand handlers from a packaged app in its top-level menu
// (the classic registry verbs end up under "Show more options"). This DLL is that handler:
// a "Video Compressor" entry with the same submenu as the classic one. Each item runs
// launch.vbs from the folder this DLL sits in, once per selected file, like the classic verbs.
// Build with build.ps1.

#include <windows.h>
#include <shobjidl_core.h>
#include <shlwapi.h>
#include <new>

// Must match the Clsid in AppxManifest.xml.
static const CLSID CLSID_VideoCompressorMenu =
    { 0x2cbd15ad, 0xc92a, 0x47e0, { 0xbe, 0x67, 0x1f, 0xce, 0x36, 0xe5, 0x99, 0x48 } };

static HMODULE g_module;
static LONG g_refs;

static void ModuleDir(wchar_t* out, DWORD size) {
    GetModuleFileNameW(g_module, out, size);
    PathRemoveFileSpecW(out);
}

static HRESULT DupString(const wchar_t* s, LPWSTR* out) { return SHStrDupW(s, out); }

struct Item {
    const wchar_t* title;
    const wchar_t* args;   // launch.vbs arguments before the file; nullptr = parent menu
    bool separatorBefore;
};

static const Item kItems[] = {
    { L"Compress to 8 MB",        L"-Quick 8",        false },
    { L"Compress to 10 MB",       L"-Quick 10",       false },
    { L"Compress to 25 MB",       L"-Quick 25",       false },
    { L"Compress to 50 MB",       L"-Quick 50",       false },
    { L"Make GIF (under 10 MB)",  L"-Gif -Quick 10",  true  },
    { L"Custom target size...",   L"-Ask",            true  },
    { L"Advanced...",             L"",                false },
};
static const ULONG kItemCount = ARRAYSIZE(kItems);

static void Launch(const wchar_t* args, const wchar_t* file) {
    wchar_t dir[MAX_PATH];
    ModuleDir(dir, MAX_PATH);
    wchar_t params[4 * MAX_PATH + 64];
    wnsprintfW(params, ARRAYSIZE(params), L"\"%s\\launch.vbs\" %s%s\"%s\"", dir, args, *args ? L" " : L"", file);
    ShellExecuteW(nullptr, L"open", L"wscript.exe", params, dir, SW_SHOWNORMAL);
}

class SubCommand;

class Separator : public IExplorerCommand {
    LONG m_refs = 1;
public:
    Separator() { InterlockedIncrement(&g_refs); }
    virtual ~Separator() { InterlockedDecrement(&g_refs); }
    IFACEMETHODIMP QueryInterface(REFIID riid, void** ppv) {
        if (riid == IID_IUnknown || riid == IID_IExplorerCommand) { *ppv = static_cast<IExplorerCommand*>(this); AddRef(); return S_OK; }
        *ppv = nullptr; return E_NOINTERFACE;
    }
    IFACEMETHODIMP_(ULONG) AddRef() { return InterlockedIncrement(&m_refs); }
    IFACEMETHODIMP_(ULONG) Release() { LONG r = InterlockedDecrement(&m_refs); if (!r) delete this; return r; }
    IFACEMETHODIMP GetTitle(IShellItemArray*, LPWSTR* out) { *out = nullptr; return E_NOTIMPL; }
    IFACEMETHODIMP GetIcon(IShellItemArray*, LPWSTR* out) { *out = nullptr; return E_NOTIMPL; }
    IFACEMETHODIMP GetToolTip(IShellItemArray*, LPWSTR* out) { *out = nullptr; return E_NOTIMPL; }
    IFACEMETHODIMP GetCanonicalName(GUID* g) { *g = GUID_NULL; return S_OK; }
    IFACEMETHODIMP GetState(IShellItemArray*, BOOL, EXPCMDSTATE* s) { *s = ECS_ENABLED; return S_OK; }
    IFACEMETHODIMP Invoke(IShellItemArray*, IBindCtx*) { return S_OK; }
    IFACEMETHODIMP GetFlags(EXPCMDFLAGS* f) { *f = ECF_ISSEPARATOR; return S_OK; }
    IFACEMETHODIMP EnumSubCommands(IEnumExplorerCommand** e) { *e = nullptr; return E_NOTIMPL; }
};

class Command : public IExplorerCommand, public IEnumExplorerCommand {
    LONG m_refs = 1;
    int m_item;        // -1 = the "Video Compressor" parent
    ULONG m_cursor = 0;  // enumeration position over kItems, counting separators

    // Entries the submenu shows: each item, with a separator object before the ones that ask for one.
    static ULONG EntryCount() { ULONG n = kItemCount; for (auto& i : kItems) if (i.separatorBefore) n++; return n; }
    static IExplorerCommand* MakeEntry(ULONG index) {
        ULONG pos = 0;
        for (ULONG i = 0; i < kItemCount; i++) {
            if (kItems[i].separatorBefore) { if (pos++ == index) return new (std::nothrow) Separator(); }
            if (pos++ == index) return new (std::nothrow) Command(static_cast<int>(i));
        }
        return nullptr;
    }

public:
    explicit Command(int item = -1) : m_item(item) { InterlockedIncrement(&g_refs); }
    virtual ~Command() { InterlockedDecrement(&g_refs); }

    IFACEMETHODIMP QueryInterface(REFIID riid, void** ppv) {
        if (riid == IID_IUnknown || riid == IID_IExplorerCommand) *ppv = static_cast<IExplorerCommand*>(this);
        else if (riid == IID_IEnumExplorerCommand) *ppv = static_cast<IEnumExplorerCommand*>(this);
        else { *ppv = nullptr; return E_NOINTERFACE; }
        AddRef();
        return S_OK;
    }
    IFACEMETHODIMP_(ULONG) AddRef() { return InterlockedIncrement(&m_refs); }
    IFACEMETHODIMP_(ULONG) Release() { LONG r = InterlockedDecrement(&m_refs); if (!r) delete this; return r; }

    // IExplorerCommand
    IFACEMETHODIMP GetTitle(IShellItemArray*, LPWSTR* out) {
        return DupString(m_item < 0 ? L"Video Compressor" : kItems[m_item].title, out);
    }
    IFACEMETHODIMP GetIcon(IShellItemArray*, LPWSTR* out) {
        if (m_item >= 0) { *out = nullptr; return E_NOTIMPL; }
        wchar_t path[MAX_PATH];
        ModuleDir(path, MAX_PATH);
        PathAppendW(path, L"icon.ico");
        return DupString(path, out);
    }
    IFACEMETHODIMP GetToolTip(IShellItemArray*, LPWSTR* out) { *out = nullptr; return E_NOTIMPL; }
    IFACEMETHODIMP GetCanonicalName(GUID* g) { *g = GUID_NULL; return S_OK; }
    IFACEMETHODIMP GetState(IShellItemArray*, BOOL, EXPCMDSTATE* s) { *s = ECS_ENABLED; return S_OK; }
    IFACEMETHODIMP GetFlags(EXPCMDFLAGS* f) { *f = m_item < 0 ? ECF_HASSUBCOMMANDS : ECF_DEFAULT; return S_OK; }

    IFACEMETHODIMP Invoke(IShellItemArray* items, IBindCtx*) {
        if (m_item < 0 || !items) return S_OK;
        DWORD count = 0;
        items->GetCount(&count);
        for (DWORD i = 0; i < count; i++) {
            IShellItem* item = nullptr;
            if (FAILED(items->GetItemAt(i, &item))) continue;
            LPWSTR path = nullptr;
            if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &path))) {
                Launch(kItems[m_item].args, path);
                CoTaskMemFree(path);
            }
            item->Release();
        }
        return S_OK;
    }

    IFACEMETHODIMP EnumSubCommands(IEnumExplorerCommand** e) {
        if (m_item >= 0) { *e = nullptr; return E_NOTIMPL; }
        Command* c = new (std::nothrow) Command(-1);
        if (!c) return E_OUTOFMEMORY;
        *e = c;   // a fresh enumerator, so each menu opening starts at the top
        return S_OK;
    }

    // IEnumExplorerCommand (only used on the parent)
    IFACEMETHODIMP Next(ULONG want, IExplorerCommand** out, ULONG* fetched) {
        ULONG got = 0, total = EntryCount();
        while (got < want && m_cursor < total) {
            IExplorerCommand* cmd = MakeEntry(m_cursor++);
            if (!cmd) break;
            out[got++] = cmd;
        }
        if (fetched) *fetched = got;
        return got == want ? S_OK : S_FALSE;
    }
    IFACEMETHODIMP Skip(ULONG n) { m_cursor += n; return m_cursor <= EntryCount() ? S_OK : S_FALSE; }
    IFACEMETHODIMP Reset() { m_cursor = 0; return S_OK; }
    IFACEMETHODIMP Clone(IEnumExplorerCommand** e) { *e = nullptr; return E_NOTIMPL; }
};

class Factory : public IClassFactory {
public:
    IFACEMETHODIMP QueryInterface(REFIID riid, void** ppv) {
        if (riid == IID_IUnknown || riid == IID_IClassFactory) { *ppv = static_cast<IClassFactory*>(this); return S_OK; }
        *ppv = nullptr; return E_NOINTERFACE;
    }
    IFACEMETHODIMP_(ULONG) AddRef() { return 2; }
    IFACEMETHODIMP_(ULONG) Release() { return 1; }
    IFACEMETHODIMP CreateInstance(IUnknown* outer, REFIID riid, void** ppv) {
        *ppv = nullptr;
        if (outer) return CLASS_E_NOAGGREGATION;
        Command* c = new (std::nothrow) Command(-1);
        if (!c) return E_OUTOFMEMORY;
        HRESULT hr = c->QueryInterface(riid, ppv);
        c->Release();
        return hr;
    }
    IFACEMETHODIMP LockServer(BOOL lock) { if (lock) InterlockedIncrement(&g_refs); else InterlockedDecrement(&g_refs); return S_OK; }
};
static Factory g_factory;

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) { g_module = module; DisableThreadLibraryCalls(module); }
    return TRUE;
}

STDAPI DllGetClassObject(REFCLSID clsid, REFIID riid, void** ppv) {
    if (clsid != CLSID_VideoCompressorMenu) { *ppv = nullptr; return CLASS_E_CLASSNOTAVAILABLE; }
    return g_factory.QueryInterface(riid, ppv);
}

STDAPI DllCanUnloadNow() { return g_refs == 0 ? S_OK : S_FALSE; }
