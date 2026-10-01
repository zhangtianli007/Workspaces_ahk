; ============================================================================
;  Workspaces.ahk  ——  工作区 / 布局管理器
; ============================================================================
;  功能概览
;    · 4 个工作区，每个工作区独立管理一组窗口
;    · 屏幕边缘悬浮侧边栏：
;        - 数字格子（2×2）  → 单击切换工作区
;        - 右侧转盘（3 个槽）→ 滚轮翻页，双击进入"冻结模式"
;        - 4 格中心的方形区域 → 鼠标变小手，可拖动整个面板
;    · 拖动中面板四周显示圆角描边；松手吸附到最近的一条屏幕边
;    · 位置记忆在 Workspaces.state.json，下次启动还原
;    · 冻结模式下点击窗口，按所选布局排列窗口
;    · 抓取模式：三击侧边栏进入，依次点窗口 → 三击保存为预设，ESC 取消
;    · 全局热键：Alt+数字 切换工作区；Ctrl+Alt+数字 移动当前窗口
;    · 布局定义保存在脚本同目录的 Workspaces.layouts.json
;
;  说明
;    DEBUG 默认关闭。需要排查问题时改为 true 并重跑，
;    日志会写到桌面的 Workspaces.log。
; ============================================================================

#Requires AutoHotkey v2.0
#SingleInstance Force

; ============================================================================
;  1. 管理员权限自提升
; ============================================================================
if !A_IsAdmin {
    try Run '*RunAs "' A_ScriptFullPath '"'
    ExitApp
}

; ============================================================================
;  2. 日志系统
; ============================================================================
DEBUG := false
LOG_PATH := A_Desktop "\Workspaces.log"

Log(msg) {
    global DEBUG, LOG_PATH
    if !DEBUG
        return
    try {
        t := FormatTime(A_Now, "HH:mm:ss") "." SubStr(Format("{:03}", A_MSec), 1, 3)
        FileAppend t "  " msg "`n", LOG_PATH, "UTF-8"
    }
}

if DEBUG
    try FileDelete LOG_PATH

Log("========== 脚本启动 ==========")
Log("A_IsAdmin=" A_IsAdmin)

; ============================================================================
;  3. 基础环境
; ============================================================================
CoordMode "Mouse", "Screen"
SetWinDelay -1
SetControlDelay -1

; ============================================================================
;  4. 运行时状态
; ============================================================================
Switching     := false
LastSwitchEnd := 0
SwitchGuardMs := 300

LastFocused     := Map()
ScriptMinimized := Map()

ExcludedProcesses := ["python.exe", "pythonw.exe"]
ExcludedClasses   := ["XamlExplorerHostIslandWindow_WASDK"]

; ---- 侧边栏位置与拖动状态 ----
BarX := 0
BarY := 0
StateFile := A_ScriptDir "\Workspaces.state.json"

Dragging         := false   ; 已真正进入拖动
Armed            := false   ; 按下但还没超过位移阈值
StartCellIdx     := 0       ; 按下时若落在某个格子内，记录其编号（1-4），否则 0
DragStartMouseX  := 0
DragStartMouseY  := 0
DragStartBarX    := 0
DragStartBarY    := 0
WasOverHandle    := false

; ---- 抓取模式 ----
Capturing    := false   ; 是否处于抓取模式
CaptureRects := []      ; 已选窗口的屏幕位置 [x, y, w, h]（顺序同 PickingWindows）

; ---- 侧边栏点击序列检测（用于三击）----
LastSidebarClickTime := 0
LastSidebarClickX    := 0
LastSidebarClickY    := 0
SidebarClickCount    := 0
PendingFreezeDoubleClick := false
PendingFreezeOnPalette   := false

; ---- 抓取模式三击保存 ----
CaptureClickCount    := 0
LastCaptureClickTime := 0
LastCaptureClickX    := 0
LastCaptureClickY    := 0

; ---- 状态文件读写 ----
SaveState() {
    global StateFile, BarX, BarY
    s := "{`n  `"barX`": " BarX ",`n  `"barY`": " BarY "`n}`n"
    try {
        f := FileOpen(StateFile, "w", "UTF-8")
        f.Write(s)
        f.Close()
        Log("状态已保存: BarX=" BarX " BarY=" BarY)
    } catch as e {
        Log("保存状态失败: " e.Message)
    }
}

LoadState() {
    global StateFile, BarX, BarY
    if !FileExist(StateFile) {
        Log("状态文件不存在，用默认位置 (0,0)")
        return false
    }
    try {
        text := FileRead(StateFile, "UTF-8")
        if (SubStr(text, 1, 1) = Chr(0xFEFF))
            text := SubStr(text, 2)
        if RegExMatch(text, '"barX"\s*:\s*(-?\d+)', &m1)
            BarX := Integer(m1[1])
        if RegExMatch(text, '"barY"\s*:\s*(-?\d+)', &m2)
            BarY := Integer(m2[1])
        Log("状态已加载: BarX=" BarX " BarY=" BarY)
        return true
    } catch as e {
        Log("加载状态失败: " e.Message)
        return false
    }
}

; ============================================================================
;  5. 工作区
; ============================================================================
MaxWs     := 4
CurrentWs := 1
WinToWs   := Map()

; ============================================================================
;  6. 侧边栏几何参数
; ============================================================================
GridCols         := 2
GridRows         := 2
FrameSize        := 40
GapX             := 8
GapY             := 8
LeftMargin       := 4
TopMargin        := 4
FontSize         := 22
CornerRadius     := 10
TopHotZoneHeight := 40

FrameColor       := 0xFF1E5A2E
FrameColorActive := 0xFF2E8B47
TextColor        := 0xFFB3D9FF
TextColorActive  := 0xFFFFFFFF

PaletteFrameColor  := 0xFF1E3A5A
PaletteFrameActive := 0xFF2E6AB0
PaletteTextColor   := 0xFFA8C8E8
PaletteTextActive  := 0xFFFFFFFF

PickingIdleFrame := 0xFF3A3A3A
PickingIdleText  := 0xFF888888
PickingDoneFrame := 0xFFAAAAAA
PickingDoneText  := 0xFFFFFFFF

HighlightColor      := 0x1E00FFCC
HighlightRadius     := 28
HighlightDurationMs := 350

DragOutlineColor    := 0xFFFFD060
DragOutlineWidth    := 3

BarWidth  := LeftMargin * 2 + GridCols * FrameSize + (GridCols - 1) * GapX
BarHeight := TopMargin  * 2 + GridRows * FrameSize + (GridRows - 1) * GapY

PaletteWidth := 40
TotalWidth   := BarWidth + PaletteWidth
PaletteSlots := 3
PaletteSlotH := BarHeight // PaletteSlots

PaletteRadiusActive := 17
PaletteRadiusIdle   := 6
PaletteFontActive   := 19
PaletteFontIdle     := 11

; ============================================================================
;  7. 布局定义
; ============================================================================
LayoutsFile := A_ScriptDir "\Workspaces.layouts.json"

DefaultLayouts := [
    { id: 1, name: "左右二分",    windows: 2, cells: [[0.0, 0.0, 0.5, 1.0], [0.5, 0.0, 0.5, 1.0]] },
    { id: 2, name: "上下二分",    windows: 2, cells: [[0.0, 0.0, 1.0, 0.5], [0.0, 0.5, 1.0, 0.5]] },
    { id: 3, name: "左大右小",    windows: 2, cells: [[0.0, 0.0, 0.6, 1.0], [0.6, 0.0, 0.4, 1.0]] },
    { id: 4, name: "左半+右上下", windows: 3, cells: [[0.0, 0.0, 0.5, 1.0], [0.5, 0.0, 0.5, 0.5], [0.5, 0.5, 0.5, 0.5]] },
    { id: 5, name: "上两下",      windows: 3, cells: [[0.0, 0.0, 0.5, 0.5], [0.5, 0.0, 0.5, 0.5], [0.0, 0.5, 1.0, 0.5]] },
    { id: 6, name: "2x2 等分",    windows: 4, cells: [[0.0, 0.0, 0.5, 0.5], [0.5, 0.0, 0.5, 0.5], [0.0, 0.5, 0.5, 0.5], [0.5, 0.5, 0.5, 0.5]] },
]

LayoutsToJson() {
    global DefaultLayouts
    s := "{`n  `"layouts`": [`n"
    for i, L in DefaultLayouts {
        s .= "    {`n"
        s .= "      `"id`": " L.id ",`n"
        s .= "      `"name`": `"" L.name "`",`n"
        s .= "      `"windows`": " L.windows ",`n"
        s .= "      `"cells`": ["
        for j, c in L.cells {
            s .= "[" c[1] ", " c[2] ", " c[3] ", " c[4] "]"
            if (j < L.cells.Length)
                s .= ", "
        }
        s .= "]`n"
        s .= "    }"
        if (i < DefaultLayouts.Length)
            s .= ","
        s .= "`n"
    }
    s .= "  ]`n}`n"
    return s
}

EnsureLayoutsFile() {
    global LayoutsFile
    if FileExist(LayoutsFile)
        return
    try {
        FileAppend LayoutsToJson(), LayoutsFile, "UTF-8"
        Log("首次启动：已生成布局模板 " LayoutsFile)
    } catch as e {
        Log("生成模板失败: " e.Message)
    }
}

LoadLayouts() {
    global LayoutsFile
    if !FileExist(LayoutsFile) {
        Log("JSON 不存在: " LayoutsFile)
        return false
    }

    text := ""
    try {
        text := FileRead(LayoutsFile, "UTF-8")
    } catch as e {
        Log("读取失败: " e.Message)
        return false
    }

    if (SubStr(text, 1, 1) = Chr(0xFEFF))
        text := SubStr(text, 2)

    layoutPattern := '(?s)"id"\s*:\s*(\d+)\s*,\s*"name"\s*:\s*"([^"]*)"\s*,\s*"windows"\s*:\s*(\d+)\s*,\s*"cells"\s*:\s*(\[\[.*?\]\])'
    cellPattern := '\[\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)\s*\]'

    newLayouts := []
    pos := 1
    while (pos := RegExMatch(text, layoutPattern, &m, pos)) {
        id       := Integer(m[1])
        nm       := m[2]
        wn       := Integer(m[3])
        cellsStr := m[4]

        cells := []
        cpos := 1
        while (cpos := RegExMatch(cellsStr, cellPattern, &cm, cpos)) {
            cells.Push([Number(cm[1]), Number(cm[2]), Number(cm[3]), Number(cm[4])])
            cpos := cm.Pos[0] + cm.Len[0]
        }

        if (cells.Length < wn) {
            Log("布局 " id " cells=" cells.Length " < windows=" wn "，跳过")
            pos := m.Pos[0] + m.Len[0]
            continue
        }

        newLayouts.Push({ id: id, name: nm, windows: wn, cells: cells })
        pos := m.Pos[0] + m.Len[0]
    }

    if (newLayouts.Length = 0) {
        Log("JSON 未解析出任何布局（检查格式）")
        return false
    }

    global Layouts
    Layouts := newLayouts
    Log("JSON 加载成功: " Layouts.Length " 个布局")
    for _, L in Layouts
        Log("  id=" L.id " name=" L.name " windows=" L.windows " cells=" L.cells.Length)
    return true
}

Layouts := []
if (!LoadLayouts()) {
    Layouts := DefaultLayouts.Clone()
    Log("使用内置默认布局: " Layouts.Length " 个")
    EnsureLayoutsFile()
}

; ============================================================================
;  8. 冻结模式状态
; ============================================================================
PaletteScrollOffset := 1

PickingMode      := false
PickingLayoutIdx := 0
PickingSelected  := 0
PickingWindows   := []

TaskbarClickRetry := 0
MaskShown         := false

; ============================================================================
;  9. GDI+ 初始化与屏幕尺寸
; ============================================================================
si := Buffer(24, 0)
NumPut("UInt", 1, si, 0)
GdipToken := 0
DllCall("gdiplus\GdiplusStartup", "UPtr*", &GdipToken, "Ptr", si, "Ptr", 0)

ScreenW := A_ScreenWidth
ScreenH := A_ScreenHeight
MaskH   := ScreenH - 20

LoadState()
if (BarX < 0)
    BarX := 0
if (BarY < 0)
    BarY := 0
if (BarX > ScreenW - TotalWidth)
    BarX := ScreenW - TotalWidth
if (BarY > ScreenH - BarHeight)
    BarY := ScreenH - BarHeight
Log("初始位置: BarX=" BarX " BarY=" BarY " 屏幕=" ScreenW "x" ScreenH)

; ============================================================================
;  10. 创建三个分层窗口
; ============================================================================

gBar := Gui("-Caption +AlwaysOnTop +ToolWindow +E0x08000000 +E0x80000")
gBar.Show("x" BarX " y" BarY " w" TotalWidth " h" BarHeight " NoActivate")
hBar := gBar.Hwnd
Log("侧边栏 hwnd=" hBar)

gMask := Gui("-Caption +AlwaysOnTop +ToolWindow +E0x08000000 +E0x80000 +E0x20")
gMask.Show("x0 y0 w" ScreenW " h" MaskH " NoActivate Hide")
hMask := gMask.Hwnd

gHL := Gui("-Caption +AlwaysOnTop +ToolWindow +E0x08000000 +E0x80000 +E0x20")
gHL.Show("x0 y0 w" ScreenW " h" ScreenH " NoActivate Hide")
hHL := gHL.Hwnd

DrawMask() {
    global hMask, ScreenW, MaskH
    pBitmap := 0
    DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", ScreenW, "Int", MaskH, "Int", 0, "Int", 0x000E200B, "Ptr", 0, "Ptr*", &pBitmap)
    pGraphics := 0
    DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", pBitmap, "Ptr*", &pGraphics)
    pBrush := 0
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", 0x08000000, "Ptr*", &pBrush)
    DllCall("gdiplus\GdipFillRectangleI", "Ptr", pGraphics, "Ptr", pBrush, "Int", 0, "Int", 0, "Int", ScreenW, "Int", MaskH)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", pBrush)
    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", pGraphics)
    hBitmap := 0
    DllCall("gdiplus\GdipCreateHBITMAPFromBitmap", "Ptr", pBitmap, "Ptr*", &hBitmap, "UInt", 0)
    DllCall("gdiplus\GdipDisposeImage", "Ptr", pBitmap)
    hdcScreen := DllCall("GetDC", "Ptr", 0, "Ptr")
    hdcMem := DllCall("CreateCompatibleDC", "Ptr", hdcScreen, "Ptr")
    hOld := DllCall("SelectObject", "Ptr", hdcMem, "Ptr", hBitmap, "Ptr")
    ptDst := Buffer(8, 0)
    size := Buffer(8, 0)
    NumPut("Int", ScreenW, size, 0)
    NumPut("Int", MaskH, size, 4)
    ptSrc := Buffer(8, 0)
    blend := Buffer(4, 0)
    NumPut("UChar", 255, blend, 2)
    NumPut("UChar", 1, blend, 3)
    DllCall("UpdateLayeredWindow", "Ptr", hMask, "Ptr", hdcScreen, "Ptr", ptDst, "Ptr", size, "Ptr", hdcMem, "Ptr", ptSrc, "UInt", 0, "Ptr", blend, "UInt", 2)
    DllCall("SelectObject", "Ptr", hdcMem, "Ptr", hOld)
    DllCall("DeleteDC", "Ptr", hdcMem)
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdcScreen)
    DllCall("DeleteObject", "Ptr", hBitmap)
}
DrawMask()

ShowMask(show) {
    global hMask, hBar, hHL, MaskShown
    if (show = MaskShown)
        return
    MaskShown := show
    DllCall("ShowWindow", "Ptr", hMask, "Int", show ? 4 : 0)
    if (show) {
        DllCall("SetWindowPos", "Ptr", hBar, "Ptr", -1, "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x0003)
        DllCall("SetWindowPos", "Ptr", hHL, "Ptr", -1, "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x0003)
    }
}

SetHandCursor() {
    h := DllCall("LoadCursorW", "Ptr", 0, "Ptr", 32649, "Ptr")
    DllCall("SetCursor", "Ptr", h)
}
SetArrowCursor() {
    h := DllCall("LoadCursorW", "Ptr", 0, "Ptr", 32512, "Ptr")
    DllCall("SetCursor", "Ptr", h)
}

CheckTaskbarZone() {
    global PickingMode, hMask, MaskShown, hBar, BarX, BarY, Dragging, WasOverHandle

    if (!PickingMode) {
        if (Dragging) {
            SetHandCursor()
            WasOverHandle := true
            return
        }
        MouseGetPos &mx, &my, &mhwnd, , 1
        inHandle := false
        if (mhwnd = hBar) {
            lx := mx - BarX
            ly := my - BarY
            if (IsOverDragHandleClient(lx, ly))
                inHandle := true
        }
        if (inHandle) {
            SetHandCursor()
            WasOverHandle := true
        } else if (WasOverHandle) {
            SetArrowCursor()
            WasOverHandle := false
        }
        return
    }

    MouseGetPos &mx, &my, , , 1
    want := (my < A_ScreenHeight - 40)
    if (want = MaskShown)
        return
    MaskShown := want
    DllCall("ShowWindow", "Ptr", hMask, "Int", want ? 4 : 0)
    Log("Mask " (want ? "显示" : "隐藏"))
}
SetTimer(CheckTaskbarZone, 40)

; ============================================================================
;  11. 高亮效果
; ============================================================================
RefreshHighlights() {
    global hHL, PickingWindows, HighlightColor, HighlightRadius, ScreenW, ScreenH, HighlightDurationMs

    if (PickingWindows.Length = 0) {
        DllCall("ShowWindow", "Ptr", hHL, "Int", 0)
        return
    }

    hwnd := PickingWindows[PickingWindows.Length]
    if !WinExist("ahk_id " hwnd) {
        Log("RefreshHL: 最新 hwnd=" hwnd " 已失效")
        DllCall("ShowWindow", "Ptr", hHL, "Int", 0)
        return
    }

    wx := 0, wy := 0, ww := 0, wh := 0
    try {
        WinGetPos &wx, &wy, &ww, &wh, "ahk_id " hwnd
    } catch as e {
        Log("RefreshHL: WinGetPos 异常 hwnd=" hwnd " err=" e.Message)
        DllCall("ShowWindow", "Ptr", hHL, "Int", 0)
        return
    }

    minmax := 99
    try minmax := WinGetMinMax("ahk_id " hwnd)
    Log("RefreshHL(最新): hwnd=" hwnd " pos=" wx "," wy " " ww "x" wh " minmax=" minmax)

    if (ww <= 0 || wh <= 0 || wx <= -10000 || wy <= -10000 || ww > ScreenW || wh > ScreenH) {
        Log("RefreshHL:   坐标异常，跳过")
        DllCall("ShowWindow", "Ptr", hHL, "Int", 0)
        return
    }

    pBitmap := 0
    DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", ScreenW, "Int", ScreenH, "Int", 0, "Int", 0x000E200B, "Ptr", 0, "Ptr*", &pBitmap)
    pGraphics := 0
    DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", pBitmap, "Ptr*", &pGraphics)
    DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", pGraphics, "Int", 4)

    pBg := 0
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", 0x01000000, "Ptr*", &pBg)
    DllCall("gdiplus\GdipFillRectangleI", "Ptr", pGraphics, "Ptr", pBg, "Int", 0, "Int", 0, "Int", ScreenW, "Int", ScreenH)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", pBg)

    r := HighlightRadius
    d := r * 2
    pBrush := 0
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", HighlightColor, "Ptr*", &pBrush)

    pPath := 0
    DllCall("gdiplus\GdipCreatePath", "Int", 0, "Ptr*", &pPath)
    DllCall("gdiplus\GdipAddPathArc", "Ptr", pPath, "Float", wx, "Float", wy, "Float", d, "Float", d, "Float", 180, "Float", 90)
    DllCall("gdiplus\GdipAddPathArc", "Ptr", pPath, "Float", wx + ww - d, "Float", wy, "Float", d, "Float", d, "Float", 270, "Float", 90)
    DllCall("gdiplus\GdipAddPathArc", "Ptr", pPath, "Float", wx + ww - d, "Float", wy + wh - d, "Float", d, "Float", d, "Float", 0, "Float", 90)
    DllCall("gdiplus\GdipAddPathArc", "Ptr", pPath, "Float", wx, "Float", wy + wh - d, "Float", d, "Float", d, "Float", 90, "Float", 90)
    DllCall("gdiplus\GdipClosePathFigure", "Ptr", pPath)
    DllCall("gdiplus\GdipFillPath", "Ptr", pGraphics, "Ptr", pBrush, "Ptr", pPath)
    DllCall("gdiplus\GdipDeletePath", "Ptr", pPath)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", pBrush)
    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", pGraphics)

    hBitmap := 0
    DllCall("gdiplus\GdipCreateHBITMAPFromBitmap", "Ptr", pBitmap, "Ptr*", &hBitmap, "UInt", 0)
    DllCall("gdiplus\GdipDisposeImage", "Ptr", pBitmap)

    hdcScreen := DllCall("GetDC", "Ptr", 0, "Ptr")
    hdcMem := DllCall("CreateCompatibleDC", "Ptr", hdcScreen, "Ptr")
    hOld := DllCall("SelectObject", "Ptr", hdcMem, "Ptr", hBitmap, "Ptr")

    ptDst := Buffer(8, 0)
    size := Buffer(8, 0)
    NumPut("Int", ScreenW, size, 0)
    NumPut("Int", ScreenH, size, 4)
    ptSrc := Buffer(8, 0)
    blend := Buffer(4, 0)
    NumPut("UChar", 255, blend, 2)
    NumPut("UChar", 1, blend, 3)

    DllCall("UpdateLayeredWindow", "Ptr", hHL, "Ptr", hdcScreen, "Ptr", ptDst, "Ptr", size, "Ptr", hdcMem, "Ptr", ptSrc, "UInt", 0, "Ptr", blend, "UInt", 2)

    DllCall("SelectObject", "Ptr", hdcMem, "Ptr", hOld)
    DllCall("DeleteDC", "Ptr", hdcMem)
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdcScreen)
    DllCall("DeleteObject", "Ptr", hBitmap)

    DllCall("ShowWindow", "Ptr", hHL, "Int", 4)
    SetTimer(HideHighlight, -HighlightDurationMs)
}

HideHighlight() {
    global hHL
    DllCall("ShowWindow", "Ptr", hHL, "Int", 0)
}

ShowHighlight(hwnd) {
    global hHL, HighlightColor, HighlightRadius, ScreenW, ScreenH, HighlightDurationMs
    if !WinExist("ahk_id " hwnd)
        return
    wx := 0, wy := 0, ww := 0, wh := 0
    try {
        WinGetPos &wx, &wy, &ww, &wh, "ahk_id " hwnd
    } catch {
        return
    }
    if (ww <= 0 || wh <= 0)
        return
    if (wx <= -10000 || wy <= -10000)
        return
    if (ww > ScreenW || wh > ScreenH)
        return

    pBitmap := 0
    DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", ScreenW, "Int", ScreenH, "Int", 0, "Int", 0x000E200B, "Ptr", 0, "Ptr*", &pBitmap)
    pGraphics := 0
    DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", pBitmap, "Ptr*", &pGraphics)
    DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", pGraphics, "Int", 4)
    pBg := 0
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", 0x01000000, "Ptr*", &pBg)
    DllCall("gdiplus\GdipFillRectangleI", "Ptr", pGraphics, "Ptr", pBg, "Int", 0, "Int", 0, "Int", ScreenW, "Int", ScreenH)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", pBg)

    r := HighlightRadius
    d := r * 2
    pPath := 0
    DllCall("gdiplus\GdipCreatePath", "Int", 0, "Ptr*", &pPath)
    DllCall("gdiplus\GdipAddPathArc", "Ptr", pPath, "Float", wx, "Float", wy, "Float", d, "Float", d, "Float", 180, "Float", 90)
    DllCall("gdiplus\GdipAddPathArc", "Ptr", pPath, "Float", wx + ww - d, "Float", wy, "Float", d, "Float", d, "Float", 270, "Float", 90)
    DllCall("gdiplus\GdipAddPathArc", "Ptr", pPath, "Float", wx + ww - d, "Float", wy + wh - d, "Float", d, "Float", d, "Float", 0, "Float", 90)
    DllCall("gdiplus\GdipAddPathArc", "Ptr", pPath, "Float", wx, "Float", wy + wh - d, "Float", d, "Float", d, "Float", 90, "Float", 90)
    DllCall("gdiplus\GdipClosePathFigure", "Ptr", pPath)
    pBrush := 0
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", HighlightColor, "Ptr*", &pBrush)
    DllCall("gdiplus\GdipFillPath", "Ptr", pGraphics, "Ptr", pBrush, "Ptr", pPath)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", pBrush)
    DllCall("gdiplus\GdipDeletePath", "Ptr", pPath)
    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", pGraphics)

    hBitmap := 0
    DllCall("gdiplus\GdipCreateHBITMAPFromBitmap", "Ptr", pBitmap, "Ptr*", &hBitmap, "UInt", 0)
    DllCall("gdiplus\GdipDisposeImage", "Ptr", pBitmap)
    hdcScreen := DllCall("GetDC", "Ptr", 0, "Ptr")
    hdcMem := DllCall("CreateCompatibleDC", "Ptr", hdcScreen, "Ptr")
    hOld := DllCall("SelectObject", "Ptr", hdcMem, "Ptr", hBitmap, "Ptr")
    ptDst := Buffer(8, 0)
    size := Buffer(8, 0)
    NumPut("Int", ScreenW, size, 0)
    NumPut("Int", ScreenH, size, 4)
    ptSrc := Buffer(8, 0)
    blend := Buffer(4, 0)
    NumPut("UChar", 255, blend, 2)
    NumPut("UChar", 1, blend, 3)
    DllCall("UpdateLayeredWindow", "Ptr", hHL, "Ptr", hdcScreen, "Ptr", ptDst, "Ptr", size, "Ptr", hdcMem, "Ptr", ptSrc, "UInt", 0, "Ptr", blend, "UInt", 2)
    DllCall("SelectObject", "Ptr", hdcMem, "Ptr", hOld)
    DllCall("DeleteDC", "Ptr", hdcMem)
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdcScreen)
    DllCall("DeleteObject", "Ptr", hBitmap)
    DllCall("ShowWindow", "Ptr", hHL, "Int", 4)
    SetTimer(HideHighlight, -HighlightDurationMs)
}

; ============================================================================
;  12. 侧边栏渲染
; ============================================================================
Render() {
    global hBar, BarWidth, BarHeight, TotalWidth, MaxWs, CurrentWs, CornerRadius
    global FrameColor, FrameColorActive, TextColor, TextColorActive
    global PaletteFrameColor, PaletteFrameActive, PaletteTextColor, PaletteTextActive
    global PickingIdleFrame, PickingIdleText, PickingDoneFrame, PickingDoneText
    global PickingMode, PickingLayoutIdx, PickingSelected, Layouts
    global FrameSize, GapX, GapY, LeftMargin, TopMargin, FontSize, GridCols
    global PaletteWidth, PaletteSlots, PaletteSlotH, PaletteScrollOffset
    global PaletteRadiusActive, PaletteRadiusIdle
    global PaletteFontActive, PaletteFontIdle
    global BarX, BarY, Dragging, Armed, DragOutlineColor, DragOutlineWidth

    pBitmap := 0
    DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", TotalWidth, "Int", BarHeight, "Int", 0, "Int", 0x000E200B, "Ptr", 0, "Ptr*", &pBitmap)
    pGraphics := 0
    DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", pBitmap, "Ptr*", &pGraphics)
    DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", pGraphics, "Int", 4)
    DllCall("gdiplus\GdipSetTextRenderingHint", "Ptr", pGraphics, "Int", 5)

    pBgBrush := 0
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", 0x01000000, "Ptr*", &pBgBrush)
    DllCall("gdiplus\GdipFillRectangleI", "Ptr", pGraphics, "Ptr", pBgBrush, "Int", 0, "Int", 0, "Int", TotalWidth, "Int", BarHeight)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", pBgBrush)

    pFamily := 0
    DllCall("gdiplus\GdipCreateFontFamilyFromName", "WStr", "Segoe UI", "Ptr", 0, "Ptr*", &pFamily)
    pFontNum := 0
    DllCall("gdiplus\GdipCreateFont", "Ptr", pFamily, "Float", FontSize, "Int", 1, "Int", 2, "Ptr*", &pFontNum)
    pFontActive := 0
    DllCall("gdiplus\GdipCreateFont", "Ptr", pFamily, "Float", PaletteFontActive, "Int", 1, "Int", 2, "Ptr*", &pFontActive)
    pFontIdle := 0
    DllCall("gdiplus\GdipCreateFont", "Ptr", pFamily, "Float", PaletteFontIdle, "Int", 1, "Int", 2, "Ptr*", &pFontIdle)

    pSf := 0
    DllCall("gdiplus\GdipCreateStringFormat", "Int", 0, "Short", 0, "Ptr*", &pSf)
    DllCall("gdiplus\GdipSetStringFormatAlign", "Ptr", pSf, "Int", 1)
    DllCall("gdiplus\GdipSetStringFormatLineAlign", "Ptr", pSf, "Int", 1)

    if (PickingMode) {
        Loop PickingSelected {
            idx := A_Index
            col := Mod(idx - 1, GridCols)
            row := (idx - 1) // GridCols
            x := LeftMargin + col * (FrameSize + GapX)
            y := TopMargin  + row * (FrameSize + GapY)
            DrawBox(pGraphics, x, y, FrameSize, CornerRadius, PickingDoneFrame)
            DrawCenteredText(pGraphics, String(idx), x, y, FrameSize, pFontNum, pSf, PickingDoneText)
        }
    } else {
        Loop MaxWs {
            idx := A_Index
            col := Mod(idx - 1, GridCols)
            row := (idx - 1) // GridCols
            x := LeftMargin + col * (FrameSize + GapX)
            y := TopMargin  + row * (FrameSize + GapY)
            cFrame := (idx = CurrentWs) ? FrameColorActive : FrameColor
            cText  := (idx = CurrentWs) ? TextColorActive  : TextColor
            DrawBox(pGraphics, x, y, FrameSize, CornerRadius, cFrame)
            DrawCenteredText(pGraphics, String(idx), x, y, FrameSize, pFontNum, pSf, cText)
        }
    }

    N := Layouts.Length
    Loop PaletteSlots {
        slot        := A_Index
        slotY       := (slot - 1) * PaletteSlotH
        slotCenterY := slotY + PaletteSlotH // 2
        slotCenterX := BarWidth + PaletteWidth // 2
        layoutIdx   := Mod(PaletteScrollOffset - 1 + (slot - 2) + N, N) + 1
        isActive    := (slot = 2)
        radius      := isActive ? PaletteRadiusActive : PaletteRadiusIdle

        if (PickingMode && isActive) {
            cFrame := PickingDoneFrame
            cText  := PickingDoneText
        } else if (isActive) {
            cFrame := PaletteFrameActive
            cText  := PaletteTextActive
        } else {
            cFrame := PaletteFrameColor
            cText  := PaletteTextColor
        }

        pBrush := 0
        DllCall("gdiplus\GdipCreateSolidFill", "UInt", cFrame, "Ptr*", &pBrush)
        DllCall("gdiplus\GdipFillEllipse", "Ptr", pGraphics, "Ptr", pBrush, "Float", slotCenterX - radius, "Float", slotCenterY - radius, "Float", radius * 2, "Float", radius * 2)
        DllCall("gdiplus\GdipDeleteBrush", "Ptr", pBrush)

        pTextBrush := 0
        DllCall("gdiplus\GdipCreateSolidFill", "UInt", cText, "Ptr*", &pTextBrush)
        rect := Buffer(16, 0)
        NumPut("Float", slotCenterX - radius, rect, 0)
        NumPut("Float", slotCenterY - radius, rect, 4)
        NumPut("Float", radius * 2, rect, 8)
        NumPut("Float", radius * 2, rect, 12)
        pFontUse := isActive ? pFontActive : pFontIdle
        DllCall("gdiplus\GdipDrawString", "Ptr", pGraphics, "WStr", String(Layouts[layoutIdx].id), "Int", -1, "Ptr", pFontUse, "Ptr", rect, "Ptr", pSf, "Ptr", pTextBrush)
        DllCall("gdiplus\GdipDeleteBrush", "Ptr", pTextBrush)
    }

    if (Dragging || Armed) {
        DrawRoundedOutline(pGraphics, 2, 2, TotalWidth - 4, BarHeight - 4, CornerRadius, DragOutlineColor, DragOutlineWidth)
    }

    DllCall("gdiplus\GdipDeleteFont", "Ptr", pFontNum)
    DllCall("gdiplus\GdipDeleteFont", "Ptr", pFontActive)
    DllCall("gdiplus\GdipDeleteFont", "Ptr", pFontIdle)
    DllCall("gdiplus\GdipDeleteFontFamily", "Ptr", pFamily)
    DllCall("gdiplus\GdipDeleteStringFormat", "Ptr", pSf)
    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", pGraphics)

    hBitmap := 0
    DllCall("gdiplus\GdipCreateHBITMAPFromBitmap", "Ptr", pBitmap, "Ptr*", &hBitmap, "UInt", 0)
    DllCall("gdiplus\GdipDisposeImage", "Ptr", pBitmap)

    hdcScreen := DllCall("GetDC", "Ptr", 0, "Ptr")
    hdcMem := DllCall("CreateCompatibleDC", "Ptr", hdcScreen, "Ptr")
    hOld := DllCall("SelectObject", "Ptr", hdcMem, "Ptr", hBitmap, "Ptr")

    ptDst := Buffer(8, 0)
    NumPut("Int", BarX, ptDst, 0)
    NumPut("Int", BarY, ptDst, 4)
    size := Buffer(8, 0)
    NumPut("Int", TotalWidth, size, 0)
    NumPut("Int", BarHeight, size, 4)
    ptSrc := Buffer(8, 0)
    blend := Buffer(4, 0)
    NumPut("UChar", 255, blend, 2)
    NumPut("UChar", 1, blend, 3)

    DllCall("UpdateLayeredWindow", "Ptr", hBar, "Ptr", hdcScreen, "Ptr", ptDst, "Ptr", size, "Ptr", hdcMem, "Ptr", ptSrc, "UInt", 0, "Ptr", blend, "UInt", 2)

    DllCall("SelectObject", "Ptr", hdcMem, "Ptr", hOld)
    DllCall("DeleteDC", "Ptr", hdcMem)
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdcScreen)
    DllCall("DeleteObject", "Ptr", hBitmap)
}

DrawBox(pGraphics, x, y, size, radius, color) {
    pPath := 0
    DllCall("gdiplus\GdipCreatePath", "Int", 0, "Ptr*", &pPath)
    d := radius * 2
    DllCall("gdiplus\GdipAddPathArc", "Ptr", pPath, "Float", x, "Float", y, "Float", d, "Float", d, "Float", 180, "Float", 90)
    DllCall("gdiplus\GdipAddPathArc", "Ptr", pPath, "Float", x + size - d, "Float", y, "Float", d, "Float", d, "Float", 270, "Float", 90)
    DllCall("gdiplus\GdipAddPathArc", "Ptr", pPath, "Float", x + size - d, "Float", y + size - d, "Float", d, "Float", d, "Float", 0, "Float", 90)
    DllCall("gdiplus\GdipAddPathArc", "Ptr", pPath, "Float", x, "Float", y + size - d, "Float", d, "Float", d, "Float", 90, "Float", 90)
    DllCall("gdiplus\GdipClosePathFigure", "Ptr", pPath)
    pBrush := 0
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", color, "Ptr*", &pBrush)
    DllCall("gdiplus\GdipFillPath", "Ptr", pGraphics, "Ptr", pBrush, "Ptr", pPath)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", pBrush)
    DllCall("gdiplus\GdipDeletePath", "Ptr", pPath)
}

DrawRoundedOutline(pGraphics, x, y, w, h, radius, color, thickness) {
    pPath := 0
    DllCall("gdiplus\GdipCreatePath", "Int", 0, "Ptr*", &pPath)
    d := radius * 2
    DllCall("gdiplus\GdipAddPathArc", "Ptr", pPath, "Float", x, "Float", y, "Float", d, "Float", d, "Float", 180, "Float", 90)
    DllCall("gdiplus\GdipAddPathArc", "Ptr", pPath, "Float", x + w - d, "Float", y, "Float", d, "Float", d, "Float", 270, "Float", 90)
    DllCall("gdiplus\GdipAddPathArc", "Ptr", pPath, "Float", x + w - d, "Float", y + h - d, "Float", d, "Float", d, "Float", 0, "Float", 90)
    DllCall("gdiplus\GdipAddPathArc", "Ptr", pPath, "Float", x, "Float", y + h - d, "Float", d, "Float", d, "Float", 90, "Float", 90)
    DllCall("gdiplus\GdipClosePathFigure", "Ptr", pPath)
    pPen := 0
    DllCall("gdiplus\GdipCreatePen1", "UInt", color, "Float", thickness, "Int", 0, "Ptr*", &pPen)
    DllCall("gdiplus\GdipDrawPath", "Ptr", pGraphics, "Ptr", pPen, "Ptr", pPath)
    DllCall("gdiplus\GdipDeletePen", "Ptr", pPen)
    DllCall("gdiplus\GdipDeletePath", "Ptr", pPath)
}

DrawCenteredText(pGraphics, text, x, y, size, pFont, pSf, color) {
    pTextBrush := 0
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", color, "Ptr*", &pTextBrush)
    rect := Buffer(16, 0)
    NumPut("Float", x, rect, 0)
    NumPut("Float", y, rect, 4)
    NumPut("Float", size, rect, 8)
    NumPut("Float", size, rect, 12)
    DllCall("gdiplus\GdipDrawString", "Ptr", pGraphics, "WStr", text, "Int", -1, "Ptr", pFont, "Ptr", rect, "Ptr", pSf, "Ptr", pTextBrush)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", pTextBrush)
}

; ============================================================================
;  13. 窗口识别辅助
; ============================================================================
GetOwner(hwnd) {
    try {
        return DllCall("GetWindow", "Ptr", hwnd, "UInt", 4, "Ptr")
    } catch {
        return 0
    }
}

FindTrackableWindow(hwnd) {
    cur := hwnd
    loop 10 {
        if (!cur)
            break
        if ShouldTrack(cur)
            return cur
        owner := GetOwner(cur)
        if (!owner || owner = cur)
            break
        cur := owner
    }
    return 0
}

IsTaskbarWindow(hwnd) {
    if (!hwnd)
        return false
    try {
        cls := WinGetClass("ahk_id " hwnd)
        taskbarClasses := ["Shell_TrayWnd", "Shell_SecondaryTrayWnd",
                           "TaskListThumbnailWnd", "TaskListThumbnailWnd2",
                           "TopLevelWindowForOverflowXamlIsland",
                           "Windows.UI.Core.CoreWindow",
                           "XamlExplorerHostIslandWindow",
                           "XamlExplorerHostIslandWindow_WASDK"]
        for _, c in taskbarClasses {
            if (cls = c)
                return true
        }
    } catch {
    }
    return false
}

ShouldTrack(hwnd) {
    global hBar, hMask, hHL, ExcludedProcesses, ExcludedClasses
    if (hwnd = hBar || hwnd = hMask || hwnd = hHL)
        return false
    try {
        cls := WinGetClass("ahk_id " hwnd)
        if (cls = "Shell_TrayWnd" || cls = "Shell_SecondaryTrayWnd" || cls = "Progman" || cls = "WorkerW")
            return false
        for _, c in ExcludedClasses {
            if (cls = c)
                return false
        }
        exStyle := WinGetExStyle("ahk_id " hwnd)
        if (exStyle & 0x80)
            return false
        title := WinGetTitle("ahk_id " hwnd)
        if (title = "")
            return false
        procName := ""
        try procName := WinGetProcessName("ahk_id " hwnd)
        for _, ex in ExcludedProcesses {
            if (procName = ex)
                return false
        }
        return true
    } catch {
        return false
    }
}

; 客户端坐标 (cx, cy) 是否落在 4 个格子中心构成的正方形内
IsOverDragHandleClient(cx, cy) {
    global LeftMargin, TopMargin, FrameSize, GapX, GapY
    c1x := LeftMargin + FrameSize // 2
    c1y := TopMargin  + FrameSize // 2
    c4x := LeftMargin + FrameSize + GapX + FrameSize // 2
    c4y := TopMargin  + FrameSize + GapY + FrameSize // 2
    return (cx >= c1x && cx <= c4x && cy >= c1y && cy <= c4y)
}

; 客户端坐标 (cx, cy) 落在哪个格子里；返回 1-4，否则 0
HitTestCell(cx, cy) {
    global GridCols, GridRows, LeftMargin, TopMargin, FrameSize, GapX, GapY, BarWidth
    if (cx < LeftMargin || cy < TopMargin || cx >= BarWidth)
        return 0
    col := (cx - LeftMargin) // (FrameSize + GapX)
    row := (cy - TopMargin) // (FrameSize + GapY)
    if (col >= GridCols || row >= GridRows)
        return 0
    fx := LeftMargin + col * (FrameSize + GapX)
    fy := TopMargin + row * (FrameSize + GapY)
    if (cx > fx + FrameSize || cy > fy + FrameSize)
        return 0
    return row * GridCols + col + 1
}

; 拖动状态机：Armed 状态下位移超过阈值 → 进入 Dragging
UpdateDrag() {
    global Dragging, Armed, BarX, BarY
    global DragStartMouseX, DragStartMouseY, DragStartBarX, DragStartBarY
    global ScreenW, ScreenH, TotalWidth, BarHeight

    if (!Armed && !Dragging)
        return

    MouseGetPos &cx, &cy, , , 1

    if (Armed && !Dragging) {
        dx := cx - DragStartMouseX
        dy := cy - DragStartMouseY
        if (Abs(dx) < 5 && Abs(dy) < 5)
            return
        Dragging := true
        Armed := false
        Log("进入拖动模式 (位移=" dx "," dy ")")
        Render()
    }

    if (!Dragging)
        return

    BarX := DragStartBarX + (cx - DragStartMouseX)
    BarY := DragStartBarY + (cy - DragStartMouseY)
    if (BarX < 0)
        BarX := 0
    if (BarY < 0)
        BarY := 0
    if (BarX > ScreenW - TotalWidth)
        BarX := ScreenW - TotalWidth
    if (BarY > ScreenH - BarHeight)
        BarY := ScreenH - BarHeight
    Render()
}

; ============================================================================
;  14. 工作区切换
; ============================================================================
SwitchToWs(target) {
    global CurrentWs, WinToWs, MaxWs, Switching, LastSwitchEnd
    global LastFocused, ScriptMinimized
    if (target < 1 || target > MaxWs)
        return
    if (target = CurrentWs)
        return

    Switching := true
    old := CurrentWs

    fg := WinExist("A")
    realFg := FindTrackableWindow(fg)
    if (realFg && WinToWs.Has(realFg) && WinToWs[realFg] = old)
        LastFocused[old] := realFg

    CurrentWs := target
    Log("SwitchToWs " old " -> " target)

    for hwnd, ws in WinToWs {
        if (ws = target)
            continue
        if !WinExist("ahk_id " hwnd)
            continue
        owner := GetOwner(hwnd)
        if (owner && WinToWs.Has(owner))
            continue
        try {
            if (WinGetMinMax("ahk_id " hwnd) != -1) {
                WinMinimize("ahk_id " hwnd)
                ScriptMinimized[hwnd] := true
            }
        }
    }

    lf := LastFocused.Has(target) ? LastFocused[target] : 0
    for hwnd in ScriptMinimized.Clone() {
        if (hwnd = lf)
            continue
        if !WinToWs.Has(hwnd) || WinToWs[hwnd] != target
            continue
        owner := GetOwner(hwnd)
        if (owner && WinToWs.Has(owner))
            continue
        if !WinExist("ahk_id " hwnd) {
            ScriptMinimized.Delete(hwnd)
            continue
        }
        try {
            DllCall("ShowWindow", "Ptr", hwnd, "Int", 4)
            ScriptMinimized.Delete(hwnd)
        }
    }

    if (lf && WinToWs.Has(lf) && WinToWs[lf] = target && ScriptMinimized.Has(lf) && WinExist("ahk_id " lf)) {
        try {
            WinRestore("ahk_id " lf)
            ScriptMinimized.Delete(lf)
            for h, ws in WinToWs {
                if (GetOwner(h) = lf && WinExist("ahk_id " h))
                    try WinActivate("ahk_id " h)
            }
        }
    }

    Switching := false
    LastSwitchEnd := A_TickCount
    Render()
}

MoveWindowToWs(target) {
    global WinToWs, CurrentWs, MaxWs, ScriptMinimized, LastFocused
    if (target < 1 || target > MaxWs)
        return

    fg := WinExist("A")
    targetHwnd := 0

    if (fg) {
        candidate := FindTrackableWindow(fg)
        if (candidate)
            targetHwnd := candidate
    }
    if (!targetHwnd && LastFocused.Has(CurrentWs)) {
        lf := LastFocused[CurrentWs]
        if (WinExist("ahk_id " lf) && WinToWs.Has(lf) && WinToWs[lf] = CurrentWs)
            targetHwnd := lf
    }
    if (!targetHwnd) {
        for h, ws in WinToWs {
            if (ws != CurrentWs)
                continue
            if !WinExist("ahk_id " h)
                continue
            try {
                if (WinGetMinMax("ahk_id " h) != -1) {
                    targetHwnd := h
                    break
                }
            }
        }
    }
    if (!targetHwnd) {
        Log("MoveWindowToWs: 无目标 → 忽略")
        return
    }

    owner := GetOwner(targetHwnd)
    if (owner && (WinToWs.Has(owner) || ShouldTrack(owner)))
        targetHwnd := owner

    WinToWs[targetHwnd] := target
    for h, ws in WinToWs.Clone() {
        if (GetOwner(h) = targetHwnd)
            WinToWs[h] := target
    }
    LastFocused[target] := targetHwnd

    if (target != CurrentWs) {
        try {
            WinMinimize("ahk_id " targetHwnd)
            ScriptMinimized[targetHwnd] := true
        }
        SwitchToWs(target)
    }
}

; ============================================================================
;  15. 窗口扫描（周期任务）
; ============================================================================
ScanWindows() {
    global WinToWs, CurrentWs, hBar, Switching, LastSwitchEnd, SwitchGuardMs, ScriptMinimized
    global PickingMode, Dragging, Armed

    if (Dragging || Armed)
        return

    for hwnd in WinGetList() {
        if (hwnd = hBar)
            continue
        if (WinToWs.Has(hwnd))
            continue
        if !ShouldTrack(hwnd)
            continue
        try {
            if (WinGetMinMax("ahk_id " hwnd) = -1)
                continue
        } catch {
            continue
        }
        owner := GetOwner(hwnd)
        if (owner && WinToWs.Has(owner)) {
            WinToWs[hwnd] := WinToWs[owner]
            continue
        }
        WinToWs[hwnd] := CurrentWs
    }

    for hwnd, ws in WinToWs.Clone() {
        if !WinExist("ahk_id " hwnd) {
            WinToWs.Delete(hwnd)
            if (ScriptMinimized.Has(hwnd))
                ScriptMinimized.Delete(hwnd)
        }
    }

    if (Switching || PickingMode)
        return
    if (A_TickCount - LastSwitchEnd < SwitchGuardMs)
        return

    fg := WinExist("A")
    if (fg) {
        realFg := FindTrackableWindow(fg)
        if (realFg) {
            owner := GetOwner(realFg)
            if (owner && WinToWs.Has(owner))
                realFg := owner
            if (WinToWs.Has(realFg)) {
                fgWs := WinToWs[realFg]
                if (fgWs != CurrentWs) {
                    fgMin := 0
                    try fgMin := WinGetMinMax("ahk_id " realFg)
                    if (fgMin != -1) {
                        SwitchToWs(fgWs)
                        return
                    }
                }
            }
        }
    }
}

SetTimer(ScanWindows, 400)

; ============================================================================
;  16. 工作区
; ============================================================================
GetWorkArea() {
    rect := Buffer(16, 0)
    DllCall("SystemParametersInfoW", "UInt", 0x0030, "UInt", 0, "Ptr", rect, "UInt", 0)
    x := NumGet(rect, 0, "Int")
    y := NumGet(rect, 4, "Int")
    r := NumGet(rect, 8, "Int")
    b := NumGet(rect, 12, "Int")
    return { x: x, y: y, w: r - x, h: b - y }
}

ApplyLayout(layoutIdx, windowList) {
    global Layouts
    L := Layouts[layoutIdx]
    wa := GetWorkArea()
    Log("ApplyLayout: id=" L.id " name=[" L.name "] windows=" L.windows " 传入=" windowList.Length " workarea=" wa.x "," wa.y " " wa.w "x" wa.h)
    Loop Min(L.windows, windowList.Length) {
        hwnd := windowList[A_Index]
        cell := L.cells[A_Index]
        if !WinExist("ahk_id " hwnd) {
            Log("  窗口[" A_Index "] hwnd=" hwnd " 不存在，跳过")
            continue
        }
        try {
            if (WinGetMinMax("ahk_id " hwnd) = -1) {
                Log("  窗口[" A_Index "] hwnd=" hwnd " 处于最小化，先恢复")
                WinRestore("ahk_id " hwnd)
                Sleep 30
            }
        }
        x := wa.x + Round(cell[1] * wa.w)
        y := wa.y + Round(cell[2] * wa.h)
        w := Round(cell[3] * wa.w)
        h := Round(cell[4] * wa.h)
        try {
            WinMove(x, y, w, h, "ahk_id " hwnd)
            Log("  窗口[" A_Index "] hwnd=" hwnd " -> " x "," y " " w "x" h " OK")
        } catch as e {
            Log("  窗口[" A_Index "] hwnd=" hwnd " WinMove 异常: " e.Message)
        }
    }
}

; ============================================================================
;  17. 冻结模式
; ============================================================================
EnterPicking(layoutIdx) {
    global PickingMode, PickingLayoutIdx, PickingSelected, PickingWindows, Layouts
    PickingMode := true
    PickingLayoutIdx := layoutIdx
    PickingSelected := 0
    PickingWindows := []
    L := Layouts[layoutIdx]
    Log("进入冻结模式：布局 id=" L.id " name=" L.name " windows=" L.windows)
    ShowMask(true)
    Render()
}

ExitPicking() {
    global PickingMode, PickingWindows, TaskbarClickRetry
    if (!PickingMode)
        return
    PickingMode := false
    PickingWindows := []
    TaskbarClickRetry := 0
    Log("退出冻结模式")
    HideHighlight()
    ShowMask(false)
    Render()
}

ProcessPickWindow(mhwnd) {
    global PickingMode, PickingWindows, PickingSelected, PickingLayoutIdx, Layouts
    global CurrentWs, WinToWs, hBar, hMask, hHL, HighlightDurationMs
    global Capturing, CaptureRects

    if (!PickingMode) {
        Log("Pick: 不在选取模式，忽略")
        return
    }
    if (mhwnd = hBar || mhwnd = hMask || mhwnd = hHL) {
        Log("Pick: 目标是脚本窗口，忽略")
        return
    }

    mClass := "", mTitle := ""
    try mClass := WinGetClass("ahk_id " mhwnd)
    try mTitle := WinGetTitle("ahk_id " mhwnd)
    Log("Pick: 输入 hwnd=" mhwnd " cls=[" mClass "] title=[" mTitle "]")

    realHwnd := FindTrackableWindow(mhwnd)
    if (!realHwnd) {
        Log("Pick: FindTrackableWindow 返回 0，拒绝；仅高亮原窗口")
        ShowHighlight(mhwnd)
        return
    }

    rClass := "", rTitle := "", rProc := "", rMin := 99
    try rClass := WinGetClass("ahk_id " realHwnd)
    try rTitle := WinGetTitle("ahk_id " realHwnd)
    try rProc  := WinGetProcessName("ahk_id " realHwnd)
    try rMin   := WinGetMinMax("ahk_id " realHwnd)
    Log("Pick: realHwnd=" realHwnd " cls=[" rClass "] proc=[" rProc "] minmax=" rMin " title=[" rTitle "]")

    if (!WinToWs.Has(realHwnd)) {
        Log("Pick: realHwnd 未追踪，触发主动扫描")
        ScanWindows()
    }
    if (!WinToWs.Has(realHwnd)) {
        Log("Pick: 扫描后仍未追踪，兜底登记到当前工作区 ws" CurrentWs)
        WinToWs[realHwnd] := CurrentWs
    }

    ws := WinToWs[realHwnd]
    Log("Pick: realHwnd 归属 ws" ws "，当前 ws" CurrentWs)
    if (ws != CurrentWs) {
        Log("Pick: 归属其他工作区，拒绝")
        ShowHighlight(realHwnd)
        return
    }

    ; 去重
    for _, h in PickingWindows {
        if (h = realHwnd) {
            Log("Pick: hwnd 已在选列表，重复选取")
            ShowHighlight(realHwnd)
            return
        }
    }

    ; 抓取模式：记录窗口位置，不检查数量
    if (Capturing) {
        wx := 0, wy := 0, ww := 0, wh := 0
        try {
            WinGetPos &wx, &wy, &ww, &wh, "ahk_id " realHwnd
        } catch as e {
            Log("Capture: WinGetPos 异常: " e.Message)
            return
        }
        CaptureRects.Push([wx, wy, ww, wh])
        PickingWindows.Push(realHwnd)
        PickingSelected := PickingWindows.Length
        Log("Capture: 加入选列表 (" PickingSelected ") hwnd=" realHwnd " 位置=" wx "," wy " " ww "x" wh)
        RefreshHighlights()
        Render()
        return
    }

    PickingWindows.Push(realHwnd)
    PickingSelected := PickingWindows.Length
    need := Layouts[PickingLayoutIdx].windows
    Log("Pick: 加入选列表 (" PickingSelected "/" need ") hwnd=" realHwnd)

    RefreshHighlights()
    Render()

    if (PickingSelected >= need) {
        Log("Pick: 选取完成，" HighlightDurationMs "ms 后应用布局")
        SetTimer(FinishSelection, -HighlightDurationMs)
    }
}

FinishSelection() {
    global PickingLayoutIdx, PickingWindows
    Log("FinishSelection: 开始，共 " PickingWindows.Length " 个窗口")
    for i, h in PickingWindows {
        t := "", c := ""
        try t := WinGetTitle("ahk_id " h)
        try c := WinGetClass("ahk_id " h)
        Log("  选中[" i "] hwnd=" h " cls=[" c "] title=[" t "]")
    }
    HideHighlight()
    ApplyLayout(PickingLayoutIdx, PickingWindows)
    SetTimer(FinishPicking, -200)
}

FinishPicking() {
    ExitPicking()
}

; ============================================================================
;  17b. 抓取模式（从当前屏幕抓布局）
; ============================================================================
EnterCapture() {
    global Capturing, PickingMode, PickingWindows, CaptureRects, PickingSelected
    global CaptureClickCount, LastCaptureClickTime, LastCaptureClickX, LastCaptureClickY

    Capturing := true
    PickingMode := true
    PickingWindows := []
    CaptureRects := []
    PickingSelected := 0

    CaptureClickCount := 0
    LastCaptureClickTime := 0
    LastCaptureClickX := 0
    LastCaptureClickY := 0

    Log("进入抓取模式")
    ShowMask(true)
    Render()
}

ExitCapture(save) {
    global Capturing, PickingMode, PickingWindows, CaptureRects, PickingSelected, TaskbarClickRetry
    global CaptureClickCount, LastCaptureClickTime

    if (!Capturing)
        return

    count := PickingWindows.Length
    rects := CaptureRects.Clone()

    Capturing := false
    PickingMode := false
    PickingWindows := []
    CaptureRects := []
    PickingSelected := 0
    TaskbarClickRetry := 0
    CaptureClickCount := 0
    LastCaptureClickTime := 0

    HideHighlight()
    ShowMask(false)
    Render()

    Log("退出抓取模式，已选=" count " 保存=" (save ? 1 : 0))

    if (save && count > 0)
        SaveCaptureAsLayout(rects)
}

SaveCaptureAsLayout(rects) {
    global Layouts, LayoutsFile

    if (rects.Length = 0)
        return

    nextId := 1
    for _, L in Layouts {
        if (L.id >= nextId)
            nextId := L.id + 1
    }

    wa := GetWorkArea()
    cells := []
    for _, r in rects {
        rel_x := (r[1] - wa.x) / wa.w
        rel_y := (r[2] - wa.y) / wa.h
        rel_w := r[3] / wa.w
        rel_h := r[4] / wa.h
        cells.Push([Round(rel_x, 4), Round(rel_y, 4), Round(rel_w, 4), Round(rel_h, 4)])
    }

    newLayout := { id: nextId, name: "预设 " nextId, windows: cells.Length, cells: cells }
    Layouts.Push(newLayout)

    s := "{`n  `"layouts`": [`n"
    for i, L in Layouts {
        s .= "    {`n"
        s .= "      `"id`": " L.id ",`n"
        s .= "      `"name`": `"" L.name "`",`n"
        s .= "      `"windows`": " L.windows ",`n"
        s .= "      `"cells`": ["
        for j, c in L.cells {
            s .= "[" c[1] ", " c[2] ", " c[3] ", " c[4] "]"
            if (j < L.cells.Length)
                s .= ", "
        }
        s .= "]`n"
        s .= "    }"
        if (i < Layouts.Length)
            s .= ","
        s .= "`n"
    }
    s .= "  ]`n}`n"

    try {
        f := FileOpen(LayoutsFile, "w", "UTF-8")
        f.Write(s)
        f.Close()
        Log("已保存新布局: id=" nextId " name=" newLayout.name " windows=" newLayout.windows)
        for i, c in cells
            Log("  cell[" i "]=[" c[1] ", " c[2] ", " c[3] ", " c[4] "]")
        ToolTip("已保存布局「" newLayout.name "」，共 " newLayout.windows " 个窗口")
        SetTimer(() => ToolTip(), -2500)
    } catch as e {
        Log("保存布局失败: " e.Message)
    }
}

; ---- 侧边栏点击序列检测（普通模式三击进入抓取）----
RegisterSidebarClick(mx, my) {
    global LastSidebarClickTime, LastSidebarClickX, LastSidebarClickY, SidebarClickCount

    now := A_TickCount
    sameArea := (now - LastSidebarClickTime < 500)
              && (Abs(mx - LastSidebarClickX) < 10)
              && (Abs(my - LastSidebarClickY) < 10)

    if (sameArea)
        SidebarClickCount += 1
    else
        SidebarClickCount := 1

    LastSidebarClickTime := now
    LastSidebarClickX := mx
    LastSidebarClickY := my

    return SidebarClickCount
}

; ---- 抓取模式下，侧边栏三击 = 保存并退出 ----
RegisterCaptureTripleClick(mx, my) {
    global Capturing, CaptureClickCount, LastCaptureClickTime, LastCaptureClickX, LastCaptureClickY

    if (!Capturing)
        return

    now := A_TickCount
    sameArea := (now - LastCaptureClickTime < 500)
              && (Abs(mx - LastCaptureClickX) < 10)
              && (Abs(my - LastCaptureClickY) < 10)

    if (sameArea)
        CaptureClickCount += 1
    else
        CaptureClickCount := 1

    LastCaptureClickTime := now
    LastCaptureClickX := mx
    LastCaptureClickY := my

    Log("抓取模式侧边栏点击: 位置=" mx "," my " 计数=" CaptureClickCount)

    if (CaptureClickCount >= 3) {
        CaptureClickCount := 0
        Log("抓取模式三击 → 保存并退出")
        ExitCapture(true)
    }
}

; 双击延迟触发（给三击留出 350ms 判定窗口）
FireFreezeFromDouble() {
    global PendingFreezeDoubleClick, PendingFreezeOnPalette, PaletteScrollOffset

    if (!PendingFreezeDoubleClick)
        return
    PendingFreezeDoubleClick := false

    if (PendingFreezeOnPalette) {
        Log("双击转盘 → 进入冻结模式")
        EnterPicking(PaletteScrollOffset)
    }
}

; ============================================================================
;  18. 冻结模式下的鼠标交互
; ============================================================================
HandlePickingClick() {
    global PickingMode, hBar, hMask, hHL, TaskbarClickRetry, Capturing

    if (!PickingMode)
        return

    MouseGetPos &mx, &my, &mhwnd, , 1
    mClass := "", mTitle := ""
    try mClass := WinGetClass("ahk_id " mhwnd)
    try mTitle := WinGetTitle("ahk_id " mhwnd)
    Log("PickingClick: pos=" mx "," my " hwnd=" mhwnd " cls=[" mClass "] title=[" mTitle "]")

    if (mhwnd = hBar || mhwnd = hMask || mhwnd = hHL) {
        Log("PickingClick: 命中脚本窗口，忽略")
        if (Capturing && mhwnd = hBar)
            RegisterCaptureTripleClick(mx, my)
        return
    }

    if (IsTaskbarWindow(mhwnd)) {
        Log("PickingClick: 命中任务栏/缩略图 cls=[" mClass "]，转发点击并延迟检查前台")
        SendInput "{LButton}"
        TaskbarClickRetry := 0
        SetTimer(CheckForegroundAfterTaskbarClick, -250)
        return
    }

    ProcessPickWindow(mhwnd)
}

CheckForegroundAfterTaskbarClick() {
    global PickingMode, TaskbarClickRetry
    if (!PickingMode) {
        TaskbarClickRetry := 0
        Log("TaskbarCheck: 已退出选取模式，取消")
        return
    }
    TaskbarClickRetry += 1
    if (TaskbarClickRetry > 15) {
        Log("TaskbarCheck: 重试超上限(" TaskbarClickRetry ")，放弃")
        TaskbarClickRetry := 0
        return
    }

    fg := WinExist("A")
    if (!fg) {
        Log("TaskbarCheck#" TaskbarClickRetry ": 无前台窗口，稍后重试")
        SetTimer(CheckForegroundAfterTaskbarClick, -200)
        return
    }

    fgClass := "", fgTitle := "", fgProc := "", fgMin := 99
    try fgClass := WinGetClass("ahk_id " fg)
    try fgTitle := WinGetTitle("ahk_id " fg)
    try fgProc  := WinGetProcessName("ahk_id " fg)
    try fgMin   := WinGetMinMax("ahk_id " fg)
    Log("TaskbarCheck#" TaskbarClickRetry ": fg=" fg " cls=[" fgClass "] proc=[" fgProc "] minmax=" fgMin " title=[" fgTitle "]")

    if (IsTaskbarWindow(fg)) {
        Log("TaskbarCheck: 前台仍是任务栏相关窗口，稍后重试")
        SetTimer(CheckForegroundAfterTaskbarClick, -200)
        return
    }

    TaskbarClickRetry := 0
    ProcessPickWindow(fg)
}

; ============================================================================
;  19. 滚轮热区
; ============================================================================

; 鼠标是否在滚轮热区内：
;   · 屏幕顶部整条横带
;   · 屏幕左侧整条竖带
;   · 侧边栏自己的矩形
IsOverScrollZone() {
    global BarX, BarY, TotalWidth, BarHeight, TopHotZoneHeight, ScreenW, ScreenH
    MouseGetPos &mx, &my, , , 1
    inTop := (my >= 0 && my <= TopHotZoneHeight && mx >= 0 && mx <= ScreenW)
    if (inTop)
        return true
    inLeft := (mx >= 0 && mx <= TotalWidth * 0.4 && my >= 0 && my <= ScreenH)
    if (inLeft)
        return true
    inBar := (mx >= BarX && mx <= BarX + TotalWidth && my >= BarY && my <= BarY + BarHeight)
    return inBar
}

IsOverPaletteZone() {
    global BarX, BarY, BarWidth, PaletteWidth, BarHeight
    MouseGetPos &mx, &my, , , 1
    return (mx >= BarX + BarWidth && mx <= BarX + BarWidth + PaletteWidth
         && my >= BarY && my <= BarY + BarHeight)
}

PaletteScroll(delta) {
    global PaletteScrollOffset, Layouts
    N := Layouts.Length
    PaletteScrollOffset := Mod(PaletteScrollOffset - 1 + delta + N, N) + 1
    Log("转盘滚动 -> idx=" PaletteScrollOffset " (id=" Layouts[PaletteScrollOffset].id ")")
    Render()
}

ReloadLayouts() {
    global Layouts, PaletteScrollOffset
    if (LoadLayouts()) {
        if (PaletteScrollOffset > Layouts.Length)
            PaletteScrollOffset := 1
        Render()
        ToolTip("已重载 " Layouts.Length " 个布局")
    } else {
        ToolTip("重载失败，见日志")
    }
    SetTimer(() => ToolTip(), -1500)
}

; ============================================================================
;  20. 热键
; ============================================================================

; 滚轮热区内的滚轮
#HotIf IsOverScrollZone() && !PickingMode && !Dragging && !Armed
WheelUp:: {
    global BarX, BarY
    MouseGetPos &mx, &my, , , 1
    Log("WheelUp 触发: 鼠标=" mx "," my " BarX=" BarX " BarY=" BarY " 在转盘=" (IsOverPaletteZone() ? 1 : 0))
    if (IsOverPaletteZone()) {
        PaletteScroll(-1)
        return
    }
    global CurrentWs, MaxWs
    t := (CurrentWs > 1) ? CurrentWs - 1 : MaxWs
    SwitchToWs(t)
}
WheelDown:: {
    global BarX, BarY
    MouseGetPos &mx, &my, , , 1
    Log("WheelDown 触发: 鼠标=" mx "," my " BarX=" BarX " BarY=" BarY " 在转盘=" (IsOverPaletteZone() ? 1 : 0))
    if (IsOverPaletteZone()) {
        PaletteScroll(1)
        return
    }
    global CurrentWs, MaxWs
    t := (CurrentWs < MaxWs) ? CurrentWs + 1 : 1
    SwitchToWs(t)
}
#HotIf

; 侧边栏左键按下：记录起点和可能命中的格子，等待后续判定（拖动 or 点击）
OnMessage(0x0201, WM_LBUTTONDOWN)
WM_LBUTTONDOWN(wParam, lParam, msg, hwnd) {
    global hBar, PickingMode
    global Dragging, Armed, StartCellIdx
    global DragStartMouseX, DragStartMouseY, DragStartBarX, DragStartBarY, BarX, BarY
    global SidebarClickCount, PendingFreezeDoubleClick

    if (hwnd != hBar)
        return
    if (PickingMode)
        return
    if (Dragging || Armed)
        return

    mx := (lParam & 0xFFFF)
    my := ((lParam >> 16) & 0xFFFF)
    if (mx > 32767)
        mx -= 65536
    if (my > 32767)
        my -= 65536

    cnt := RegisterSidebarClick(mx, my)
    if (cnt >= 3) {
        SidebarClickCount := 0
        PendingFreezeDoubleClick := false
        SetTimer(FireFreezeFromDouble, 0)
        Log("三击检测 → 进入抓取模式")
        EnterCapture()
        return
    }

    cellIdx  := HitTestCell(mx, my)
    inHandle := IsOverDragHandleClient(mx, my)

    if (!inHandle && cellIdx = 0)
        return

    Armed := true
    Dragging := false
    StartCellIdx := cellIdx
    DragStartBarX := BarX
    DragStartBarY := BarY
    MouseGetPos &cx, &cy, , , 1
    DragStartMouseX := cx
    DragStartMouseY := cy
    DllCall("SetCapture", "Ptr", hBar)
    SetTimer(UpdateDrag, 16)
    Log("按下(等待判定): 鼠标=" cx "," cy " 面板起点=" BarX "," BarY " 命中格子=" StartCellIdx " 手把内=" (inHandle ? 1 : 0))
    Render()
}

; 侧边栏左键松开：真正决定是"拖动结束"还是"格子点击"
OnMessage(0x0202, WM_LBUTTONUP)
WM_LBUTTONUP(wParam, lParam, msg, hwnd) {
    global Dragging, Armed, StartCellIdx
    global BarX, BarY, DragStartBarX, DragStartBarY
    global ScreenW, ScreenH, TotalWidth, BarHeight, MaxWs

    if (!Dragging && !Armed)
        return

    wasDragging := Dragging
    cellIdx := StartCellIdx

    Dragging := false
    Armed := false
    StartCellIdx := 0
    DllCall("ReleaseCapture")
    SetTimer(UpdateDrag, 0)

    if (!wasDragging) {
        Log("松开(未拖动): 命中格子=" cellIdx)
        Render()
        if (cellIdx >= 1 && cellIdx <= MaxWs)
            SwitchToWs(cellIdx)
        return
    }

    if (BarY <= BarX) {
        BarY := 0
        if (BarX < 0)
            BarX := 0
        if (BarX > ScreenW - TotalWidth)
            BarX := ScreenW - TotalWidth
        Log("吸附顶边: BarX=" BarX)
    } else {
        BarX := 0
        if (BarY < 0)
            BarY := 0
        if (BarY > ScreenH - BarHeight)
            BarY := ScreenH - BarHeight
        Log("吸附左边: BarY=" BarY)
    }

    SaveState()
    Render()
}

; 侧边栏左键双击：延迟进入冻结模式（给三击留出判定窗口）
OnMessage(0x0203, WM_LBUTTONDBLCLK)
WM_LBUTTONDBLCLK(wParam, lParam, msg, hwnd) {
    global hBar, BarWidth, PaletteWidth, BarHeight, PickingMode
    global PendingFreezeDoubleClick, PendingFreezeOnPalette

    if (hwnd != hBar)
        return
    if (PickingMode)
        return

    mx := (lParam & 0xFFFF)
    my := ((lParam >> 16) & 0xFFFF)
    if (mx > 32767)
        mx -= 65536
    if (my > 32767)
        my -= 65536

    cnt := RegisterSidebarClick(mx, my)

    if (cnt = 2) {
        onPalette := (mx >= BarWidth && mx <= BarWidth + PaletteWidth && my >= 0 && my <= BarHeight)
        PendingFreezeDoubleClick := true
        PendingFreezeOnPalette := onPalette
        SetTimer(FireFreezeFromDouble, -350)
    }
}

; 冻结模式 / 抓取模式下的按键绑定
#HotIf PickingMode
$LButton::HandlePickingClick()
Esc:: {
    global Capturing
    if (Capturing)
        ExitCapture(false)
    else
        ExitPicking()
}
#HotIf

; 切换工作区
!1:: SwitchToWs(1)
!2:: SwitchToWs(2)
!3:: SwitchToWs(3)
!4:: SwitchToWs(4)

; 把当前窗口移到指定工作区
^!1:: MoveWindowToWs(1)
^!2:: MoveWindowToWs(2)
^!3:: MoveWindowToWs(3)
^!4:: MoveWindowToWs(4)

; 按 2×2 网格左右移动工作区
![:: {
    global CurrentWs, GridCols
    col := Mod(CurrentWs - 1, GridCols)
    row := (CurrentWs - 1) // GridCols
    col := Mod(col - 1 + GridCols, GridCols)
    SwitchToWs(row * GridCols + col + 1)
}

; 按 2×2 网格上下移动工作区
!]:: {
    global CurrentWs, GridCols, GridRows
    col := Mod(CurrentWs - 1, GridCols)
    row := (CurrentWs - 1) // GridCols
    row := Mod(row + 1, GridRows)
    SwitchToWs(row * GridCols + col + 1)
}

; 重载布局 JSON
F9:: ReloadLayouts()

; 诊断：F12 记录当前鼠标位置和滚轮热区状态
F12:: {
    global BarX, BarY, TotalWidth, BarHeight
    MouseGetPos &mx, &my, &mhwnd, , 1
    inZone    := IsOverScrollZone()
    inPalette := IsOverPaletteZone()
    Log("F12 诊断: 鼠标=" mx "," my " 窗口hwnd=" mhwnd " BarX=" BarX " BarY=" BarY
        " 侧边栏矩形=[x" BarX ".." (BarX + TotalWidth) ", y" BarY ".." (BarY + BarHeight) "]"
        " 判定在侧边栏内=" (inZone ? 1 : 0) " 判定在转盘内=" (inPalette ? 1 : 0))
    ToolTip("鼠标=" mx "," my "  侧边栏内=" (inZone ? "是" : "否"))
    SetTimer(() => ToolTip(), -1500)
}

; 退出脚本
F10:: {
    Log("========== F10 退出 ==========")
    ExitApp
}

; ============================================================================
;  21. 启动
; ============================================================================
ScanWindows()
Render()
DllCall("ShowWindow", "Ptr", hBar, "Int", 4)
Log("启动完成 BarX=" BarX " BarY=" BarY)
