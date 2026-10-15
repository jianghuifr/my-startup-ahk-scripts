// WinAlwaysOnTop_hook.c
// Global hook DLL for intercepting WM_SYSCOMMAND on a custom menu item.
//
// Build (zig is not required; any toolchain that targets the same bitness as
// AutoHotkey works):
//     zig cc -shared -o WinAlwaysOnTop_hook_v2.dll WinAlwaysOnTop_hook.c -luser32
//   or: cl /LD WinAlwaysOnTop_hook.c user32.lib /Fe:WinAlwaysOnTop_hook_v2.dll
//
// The hooks are installed globally, so they are injected into every process of
// the same bitness that owns a message queue. A 32-bit application is therefore
// not covered by the 64-bit build: its "Always On Top" menu item does nothing.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#define SC_TOGGLE_TOPMOST 0xE001
#define WM_TOGGLE_TOPMOST_NAME "WM_AHKTOP_TOGGLE"

static HINSTANCE g_hInstance = NULL;
static HHOOK g_hHookGet = NULL;   // WH_GETMESSAGE (catches posted messages)
static HHOOK g_hHookCall = NULL;  // WH_CALLWNDPROC (catches sent messages)

BOOL APIENTRY DllMain(HINSTANCE hinstDLL, DWORD fdwReason, LPVOID lpvReserved) {
    (void)lpvReserved;
    if (fdwReason == DLL_PROCESS_ATTACH) {
        g_hInstance = hinstDLL;
        DisableThreadLibraryCalls(hinstDLL);
    }
    return TRUE;
}

// Send notification to all AutoHotkey windows (fast, targeted)
static void NotifyAHK(HWND sourceHwnd) {
    UINT wmMsg = RegisterWindowMessageA(WM_TOGGLE_TOPMOST_NAME);
    if (!wmMsg) return;
    HWND hwnd = NULL;
    while ((hwnd = FindWindowExA(NULL, hwnd, "AutoHotkey", NULL)) != NULL) {
        PostMessage(hwnd, wmMsg, (WPARAM)sourceHwnd, 0);
    }
}

// WH_GETMESSAGE: catches posted WM_SYSCOMMAND
static LRESULT CALLBACK GetMsgProc(int nCode, WPARAM wParam, LPARAM lParam) {
    if (nCode >= 0 && wParam == PM_REMOVE) {
        MSG* pMsg = (MSG*)lParam;
        if (pMsg->message == WM_SYSCOMMAND && pMsg->wParam == SC_TOGGLE_TOPMOST) {
            NotifyAHK(pMsg->hwnd);
            pMsg->message = WM_NULL;
        }
    }
    return CallNextHookEx(NULL, nCode, wParam, lParam);
}

// WH_CALLWNDPROC: catches sent WM_SYSCOMMAND
static LRESULT CALLBACK CallWndProc(int nCode, WPARAM wParam, LPARAM lParam) {
    if (nCode >= 0) {
        CWPSTRUCT* pMsg = (CWPSTRUCT*)lParam;
        if (pMsg->message == WM_SYSCOMMAND && pMsg->wParam == SC_TOGGLE_TOPMOST) {
            NotifyAHK(pMsg->hwnd);
        }
    }
    return CallNextHookEx(NULL, nCode, wParam, lParam);
}

__declspec(dllexport) BOOL InstallHook(void) {
    if (g_hHookGet && g_hHookCall) return TRUE;
    g_hHookGet = SetWindowsHookExW(WH_GETMESSAGE, GetMsgProc, g_hInstance, 0);
    g_hHookCall = SetWindowsHookExW(WH_CALLWNDPROC, CallWndProc, g_hInstance, 0);
    return (g_hHookGet != NULL || g_hHookCall != NULL);
}

__declspec(dllexport) void UninstallHook(void) {
    if (g_hHookGet) { UnhookWindowsHookEx(g_hHookGet); g_hHookGet = NULL; }
    if (g_hHookCall) { UnhookWindowsHookEx(g_hHookCall); g_hHookCall = NULL; }
}
