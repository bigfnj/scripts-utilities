"""Place windows only for an alive subprocess.Popen child on an explicit display.

No persisted settings, focus changes, visibility changes or unrelated-window moves.
"""
from __future__ import annotations

import ctypes
from ctypes import wintypes
import os
import subprocess


class RECT(ctypes.Structure):
    _fields_ = [("left", wintypes.LONG), ("top", wintypes.LONG),
                ("right", wintypes.LONG), ("bottom", wintypes.LONG)]


class MONITORINFOEXW(ctypes.Structure):
    _fields_ = [("cbSize", wintypes.DWORD), ("rcMonitor", RECT), ("rcWork", RECT),
                ("dwFlags", wintypes.DWORD), ("szDevice", wintypes.WCHAR * 32)]


def _api():
    if os.name != "nt":
        raise RuntimeError("Window placement requires Windows")
    api = ctypes.WinDLL("user32", use_last_error=True)
    api.GetMonitorInfoW.argtypes = [wintypes.HANDLE, ctypes.POINTER(MONITORINFOEXW)]
    api.GetMonitorInfoW.restype = wintypes.BOOL
    api.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
    api.GetWindowThreadProcessId.restype = wintypes.DWORD
    api.GetWindowRect.argtypes = [wintypes.HWND, ctypes.POINTER(RECT)]
    api.GetWindowRect.restype = wintypes.BOOL
    api.SetWindowPos.argtypes = [wintypes.HWND, wintypes.HWND, ctypes.c_int, ctypes.c_int,
                                ctypes.c_int, ctypes.c_int, wintypes.UINT]
    api.SetWindowPos.restype = wintypes.BOOL
    return api


def monitor_work_area(device: str) -> tuple[int, int, int, int]:
    if not device:
        raise ValueError("Explicit display device required")
    api = _api()
    found = []
    callback_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HANDLE, wintypes.HDC,
                                      ctypes.POINTER(RECT), wintypes.LPARAM)
    def visit(handle, dc, bounds, data):
        info = MONITORINFOEXW()
        info.cbSize = ctypes.sizeof(info)
        if not api.GetMonitorInfoW(handle, ctypes.byref(info)):
            return False
        if info.szDevice.casefold() == device.casefold():
            found.append((info.rcWork.left, info.rcWork.top,
                          info.rcWork.right, info.rcWork.bottom))
        return True
    callback = callback_type(visit)
    api.EnumDisplayMonitors.argtypes = [wintypes.HDC, ctypes.POINTER(RECT),
                                       callback_type, wintypes.LPARAM]
    api.EnumDisplayMonitors.restype = wintypes.BOOL
    if not api.EnumDisplayMonitors(None, None, callback, 0):
        raise ctypes.WinError(ctypes.get_last_error())
    if len(found) != 1:
        raise ValueError("Requested display device is not connected")
    return found[0]


def fit_rectangle(current: tuple[int, int, int, int],
                  work: tuple[int, int, int, int]) -> tuple[int, int, int, int]:
    left, top, right, bottom = work
    if right <= left or bottom <= top:
        raise ValueError("Display has no positive work area")
    width = min(max(current[2] - current[0], 160), right - left)
    height = min(max(current[3] - current[1], 120), bottom - top)
    x = min(max(current[0], left), right - width)
    y = min(max(current[1], top), bottom - height)
    return x, y, width, height


def move_child_windows(process: subprocess.Popen, work: tuple[int, int, int, int]) -> int:
    if not isinstance(process, subprocess.Popen) or process.pid <= 0:
        raise ValueError("An explicit launched Popen child is required")
    if process.poll() is not None:
        return 0
    api = _api()
    count = []
    errors = []
    fit_rectangle((0, 0, 160, 120), work)
    callback_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    def visit(hwnd, data):
        if process.poll() is not None:
            return False
        owner = wintypes.DWORD()
        api.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
        if owner.value != process.pid:
            return True
        current = RECT()
        if not api.GetWindowRect(hwnd, ctypes.byref(current)):
            return True  # The child may destroy a window during enumeration.
        x, y, width, height = fit_rectangle(
            (current.left, current.top, current.right, current.bottom), work)
        if (current.left, current.top, current.right, current.bottom) == (x, y, x + width, y + height):
            return True
        flags = 0x0004 | 0x0010 | 0x0200  # NOZORDER, NOACTIVATE, NOOWNERZORDER
        if current.right - current.left == width and current.bottom - current.top == height:
            flags |= 0x0001  # NOSIZE for a pure move; avoid repeated resize messages.
        if process.poll() is None:
            if api.SetWindowPos(hwnd, None, x, y, width, height, flags):
                count.append(int(hwnd))
            else:
                errors.append(ctypes.get_last_error())
        return True
    callback = callback_type(visit)
    api.EnumWindows.argtypes = [callback_type, wintypes.LPARAM]
    api.EnumWindows.restype = wintypes.BOOL
    result = api.EnumWindows(callback, 0)
    if not result and process.poll() is None:
        raise ctypes.WinError(ctypes.get_last_error())
    if errors and process.poll() is None:
        raise ctypes.WinError(errors[0])
    return len(count)
