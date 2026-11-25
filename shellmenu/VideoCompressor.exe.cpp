// The app entry the Windows 11 menu package needs (a package must name an .exe).
// It just opens the full Video Compressor window through launch.vbs, passing any files along.

#include <windows.h>
#include <shlwapi.h>

int WINAPI wWinMain(HINSTANCE, HINSTANCE, LPWSTR cmdLine, int) {
    wchar_t dir[MAX_PATH];
    GetModuleFileNameW(nullptr, dir, MAX_PATH);
    PathRemoveFileSpecW(dir);
    wchar_t params[32768];
    wnsprintfW(params, ARRAYSIZE(params), L"\"%s\\launch.vbs\" %s", dir, cmdLine);
    ShellExecuteW(nullptr, L"open", L"wscript.exe", params, dir, SW_SHOWNORMAL);
    return 0;
}
