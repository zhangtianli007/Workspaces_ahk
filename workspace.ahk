#Requires AutoHotkey v2.0
#SingleInstance Force

if !A_IsAdmin {
    try Run '*RunAs "' A_ScriptFullPath '"'
    ExitApp
}

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

CoordMode "Mouse", "Screen"
SetWinDelay -1
SetControlDelay -1

Switching := false
LastSwitchEnd := 0
SwitchGuardMs := 300

LastFocused := Map()
ScriptMinimized := Map()

ExcludedProcesses := ["python.exe", "pythonw.exe"]
ExcludedClasses := ["XamlExplorerHostIslandWindow_WASDK"]

MaxWs := 4
CurrentWs := 1
WinToWs := Map()

GridCols := 2
GridRows := 2
FrameSize := 40
GapX := 8
GapY := 8
LeftMargin := 4
TopMargin := 4
FontSize := 22
CornerRadius := 10
TopHotZoneHeight := 40

FrameColor       := 0xFF1E5A2E
FrameColorActive := 0xFF2E8B47
TextColor        := 0xFFB3D9FF
TextColorActive  := 0xFFFFFFFF

PaletteFrameColor  := 0xFF1E3A5A
PaletteFrameActive := 0xFF2E6AB0
PaletteTextColor   := 0xFFA8C8E8
PaletteTextActive  := 0xFFFFFFFF

PickingIdleFrame  := 0xFF3A3A3A
PickingIdleText   := 0xFF888888
PickingDoneFrame  := 0xFFAAAAAA
PickingDoneText   := 0xFFFFFFFF

HighlightColor := 0x3000FFCC
HighlightRadius := 12
HighlightDurationMs := 350

BarWidth  := LeftMargin * 2 + GridCols * FrameSize + (GridCols - 1) * GapX
BarHeight := TopMargin * 2 + GridRows * FrameSize + (GridRows - 1) * GapY

PaletteWidth := 40
TotalWidth := BarWidth + PaletteWidth
PaletteSlots := 3
PaletteSlotH := BarHeight // PaletteSlots

PaletteRadiusActive := 17
PaletteRadiusIdle   := 6

PaletteFontActive := 19
PaletteFontIdle   := 11

LayoutsFile := A_ScriptDir "\Workspaces.layouts.json"

DefaultLayouts := [
    { id: 1, name: "左右二分",     windows: 2, cells: [[0.0, 0.0, 0.5, 1.0], [0.5, 0.0, 0.5, 1.0]] },
    { id: 2, name: "上下二分",     windows: 2, cells: [[0.0, 0.0, 1.0, 0.5], [0.0, 0.5, 1.0, 0.5]] },
    { id: 3, name: "左大右小",     windows: 2, cells: [[0.0, 0.0, 0.6, 1.0], [0.6, 0.0, 0.4, 1.0]] },
    { id: 4, name: "左半+右上下",  windows: 3, cells: [[0.0, 0.0, 0.5, 1.0], [0.5, 0.0, 0.5, 0.5], [0.5, 0.5, 0.5, 0.5]] },
    { id: 5, name: "上两下",       windows: 3, cells: [[0.0, 0.0, 0.5, 0.5], [0.5, 0.0, 0.5, 0.5], [0.0, 0.5, 1.0, 0.5]] },
    { id: 6, name: "2x2 等分",     windows: 4, cells: [[0.0, 0.0, 0.5, 0.5], [0.5, 0.0, 0.5, 0.5], [0.0, 0.5, 0.5, 0.5], [0.5, 0.5, 0.5, 0.5]] },
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
        id := Integer(m[1])
        nm := m[2]
        wn := Integer(m[3])
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

PaletteScrollOffset := 1

PickingMode := false
PickingLayoutIdx := 0
PickingSelected := 0
PickingWindows := []

si := Buffer(24, 0)
NumPut("UInt", 1, si, 0)
GdipToken := 0
DllCall("gdiplus\GdiplusStartup", "UPtr*", &GdipToken, "Ptr", si, "Ptr", 0)

ScreenW := A_ScreenWidth
ScreenH := A_ScreenHeight

MaskH := ScreenH - 20

gBar := Gui("-Caption +AlwaysOnTop +ToolWindow +E0x08000000 +E0x80000")
gBar.Show("x0 y0 w" TotalWidth " h" BarHeight " NoActivate")
hBar := gBar.Hwnd
Log("侧边栏 hwnd=" hBar)

gMask := Gui("-Caption +AlwaysOnTop +ToolWindow +E0x08000000 +E0x80000 +E0x20")
gMask.Show("x0 y0 w" ScreenW " h" MaskH " NoActivate Hide")
hMask := gMask.Hwnd

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

gHL := Gui("-Caption +AlwaysOnTop +ToolWindow +E0x08000000 +E0x80000 +E0x20")
gHL.Show("x0 y0 w" ScreenW " h" ScreenH " NoActivate Hide")
hHL := gHL.Hwnd

ShowMask(show) {
    global hMask, hBar, hHL
    DllCall("ShowWindow", "Ptr", hMask, "Int", show ? 4 : 0)
    if (show) {
        DllCall("SetWindowPos", "Ptr", hBar, "Ptr", -1, "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x0003)
        DllCall("SetWindowPos", "Ptr", hHL, "Ptr", -1, "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x0003)
    }
}

CheckTaskbarZone() {
    global PickingMode, hMask
    if (!PickingMode)
        return
    MouseGetPos &mx, &my, , , 1
    if (my >= A_ScreenHeight - 40)
        DllCall("ShowWindow", "Ptr", hMask, "Int", 0)
    else
        DllCall("ShowWindow", "Ptr", hMask, "Int", 4)
}
SetTimer(CheckTaskbarZone, 80)

RefreshHighlights() {
    global hHL, PickingWindows, HighlightColor, HighlightRadius, ScreenW, ScreenH, HighlightDurationMs
    if (PickingWindows.Length = 0) {
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
    for _, hwnd in PickingWindows {
        if !WinExist("ahk_id " hwnd)
            continue
        try WinGetPos &wx, &wy, &ww, &wh, "ahk_id " hwnd
        if (ww <= 0 || wh <= 0)
            continue
        pPath := 0
        DllCall("gdiplus\GdipCreatePath", "Int", 0, "Ptr*", &pPath)
        DllCall("gdiplus\GdipAddPathArc", "Ptr", pPath, "Float", wx, "Float", wy, "Float", d, "Float", d, "Float", 180, "Float", 90)
        DllCall("gdiplus\GdipAddPathArc", "Ptr", pPath, "Float", wx + ww - d, "Float", wy, "Float", d, "Float", d, "Float", 270, "Float", 90)
        DllCall("gdiplus\GdipAddPathArc", "Ptr", pPath, "Float", wx + ww - d, "Float", wy + wh - d, "Float", d, "Float", d, "Float", 0, "Float", 90)
        DllCall("gdiplus\GdipAddPathArc", "Ptr", pPath, "Float", wx, "Float", wy + wh - d, "Float", d, "Float", d, "Float", 90, "Float", 90)
        DllCall("gdiplus\GdipClosePathFigure", "Ptr", pPath)
        DllCall("gdiplus\GdipFillPath", "Ptr", pGraphics, "Ptr", pBrush, "Ptr", pPath)
        DllCall("gdiplus\GdipDeletePath", "Ptr", pPath)
    }
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
    try WinGetPos &wx, &wy, &ww, &wh, "ahk_id " hwnd
    if (ww <= 0 || wh <= 0)
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
            y := TopMargin + row * (FrameSize + GapY)
            DrawBox(pGraphics, x, y, FrameSize, CornerRadius, PickingDoneFrame)
            DrawCenteredText(pGraphics, String(idx), x, y, FrameSize, pFontNum, pSf, PickingDoneText)
        }
    } else {
        Loop MaxWs {
            idx := A_Index
            col := Mod(idx - 1, GridCols)
            row := (idx - 1) // GridCols
            x := LeftMargin + col * (FrameSize + GapX)
            y := TopMargin + row * (FrameSize + GapY)
            cFrame := (idx = CurrentWs) ? FrameColorActive : FrameColor
            cText  := (idx = CurrentWs) ? TextColorActive  : TextColor
            DrawBox(pGraphics, x, y, FrameSize, CornerRadius, cFrame)
            DrawCenteredText(pGraphics, String(idx), x, y, FrameSize, pFontNum, pSf, cText)
        }
    }

    N := Layouts.Length
    Loop PaletteSlots {
        slot := A_Index
        slotY := (slot - 1) * PaletteSlotH
        slotCenterY := slotY + PaletteSlotH // 2
        slotCenterX := BarWidth + PaletteWidth // 2
        layoutIdx := Mod(PaletteScrollOffset - 1 + (slot - 2) + N, N) + 1
        isActive := (slot = 2)
        radius := isActive ? PaletteRadiusActive : PaletteRadiusIdle

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

ScanWindows() {
    global WinToWs, CurrentWs, hBar, Switching, LastSwitchEnd, SwitchGuardMs, ScriptMinimized
    global PickingMode

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
    Log("ApplyLayout: " L.name " workarea=" wa.x "," wa.y " " wa.w "x" wa.h)
    Loop Min(L.windows, windowList.Length) {
        hwnd := windowList[A_Index]
        cell := L.cells[A_Index]
        if !WinExist("ahk_id " hwnd)
            continue
        try {
            if (WinGetMinMax("ahk_id " hwnd) = -1)
                WinRestore("ahk_id " hwnd)
        }
        x := wa.x + Round(cell[1] * wa.w)
        y := wa.y + Round(cell[2] * wa.h)
        w := Round(cell[3] * wa.w)
        h := Round(cell[4] * wa.h)
        try WinMove(x, y, w, h, "ahk_id " hwnd)
        Log("  窗口 " A_Index " hwnd=" hwnd " -> " x "," y " " w "x" h)
    }
}

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
    global PickingMode, PickingWindows
    if (!PickingMode)
        return
    PickingMode := false
    PickingWindows := []
    Log("退出冻结模式")
    HideHighlight()
    ShowMask(false)
    Render()
}

ProcessPickWindow(mhwnd) {
    global PickingMode, PickingWindows, PickingSelected, PickingLayoutIdx, Layouts
    global CurrentWs, WinToWs, hBar, hMask, hHL

    if (!PickingMode)
        return
    if (mhwnd = hBar || mhwnd = hMask || mhwnd = hHL)
        return

    realHwnd := FindTrackableWindow(mhwnd)
    if (!realHwnd) {
        Log("选取：未找到可追踪窗口 (mhwnd=" mhwnd ")")
        ShowHighlight(mhwnd)
        return
    }

    if (!WinToWs.Has(realHwnd)) {
        Log("选取：窗口未追踪，主动扫描 hwnd=" realHwnd " title=" WinGetTitle("ahk_id " realHwnd))
        ScanWindows()
    }

    if (!WinToWs.Has(realHwnd)) {
        Log("选取：扫描后仍未追踪 hwnd=" realHwnd)
        ShowHighlight(realHwnd)
        return
    }
    if (WinToWs[realHwnd] != CurrentWs) {
        Log("选取：窗口属于 ws" WinToWs[realHwnd] "，不属于当前 ws" CurrentWs " → 拒绝")
        ShowHighlight(realHwnd)
        return
    }
    for _, h in PickingWindows {
        if (h = realHwnd) {
            Log("选取：已选过 hwnd=" realHwnd)
            ShowHighlight(realHwnd)
            return
        }
    }

    PickingWindows.Push(realHwnd)
    PickingSelected := PickingWindows.Length
    need := Layouts[PickingLayoutIdx].windows
    Log("选取：加入 hwnd=" realHwnd " title=" WinGetTitle("ahk_id " realHwnd) " (" PickingSelected "/" need ")")

    RefreshHighlights()
    Render()

    if (PickingSelected >= need) {
        Log("选取完成 → 等高亮 " HighlightDurationMs "ms 后应用布局")
        SetTimer(FinishSelection, -HighlightDurationMs)
    }
}

FinishSelection() {
    global PickingLayoutIdx, PickingWindows
    HideHighlight()
    ApplyLayout(PickingLayoutIdx, PickingWindows)
    SetTimer(FinishPicking, -200)
}

FinishPicking() {
    ExitPicking()
}

HandlePickingClick() {
    global PickingMode, hBar, hMask, hHL

    if (!PickingMode)
        return

    MouseGetPos &mx, &my, &mhwnd, , 1
    if (mhwnd = hBar || mhwnd = hMask || mhwnd = hHL)
        return

    if (IsTaskbarWindow(mhwnd)) {
        Log("选取：点击任务栏 hwnd=" mhwnd " cls=" WinGetClass("ahk_id " mhwnd) " → 放行点击，延迟检查前台")
        SendInput "{LButton}"
        SetTimer(CheckForegroundAfterTaskbarClick, -200)
        return
    }

    ProcessPickWindow(mhwnd)
}

CheckForegroundAfterTaskbarClick() {
    global PickingMode
    if (!PickingMode)
        return
    fg := WinExist("A")
    if (!fg)
        return
    fgTitle := ""
    try fgTitle := WinGetTitle("ahk_id " fg)
    Log("选取：任务栏点击后检查前台 hwnd=" fg " title=[" fgTitle "]")
    ProcessPickWindow(fg)
}

IsOverScrollZone() {
    global TotalWidth, TopHotZoneHeight, ScreenW, ScreenH
    MouseGetPos &mx, &my, , , 1
    inTop := (my >= 0 && my <= TopHotZoneHeight && mx >= 0 && mx <= ScreenW)
    inLeft := (mx >= 0 && mx <= TotalWidth && my >= 0 && my <= ScreenH)
    return inTop || inLeft
}

IsOverPaletteZone() {
    global BarWidth, PaletteWidth, BarHeight
    MouseGetPos &mx, &my, , , 1
    return (mx >= BarWidth && mx <= BarWidth + PaletteWidth && my >= 0 && my <= BarHeight)
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

#HotIf IsOverScrollZone() && !PickingMode
WheelUp:: {
    if (IsOverPaletteZone()) {
        PaletteScroll(-1)
        return
    }
    global CurrentWs, MaxWs
    t := (CurrentWs > 1) ? CurrentWs - 1 : MaxWs
    SwitchToWs(t)
}
WheelDown:: {
    if (IsOverPaletteZone()) {
        PaletteScroll(1)
        return
    }
    global CurrentWs, MaxWs
    t := (CurrentWs < MaxWs) ? CurrentWs + 1 : 1
    SwitchToWs(t)
}
#HotIf

OnMessage(0x0201, WM_LBUTTONDOWN)
WM_LBUTTONDOWN(wParam, lParam, msg, hwnd) {
    global hBar, MaxWs, GridCols, GridRows, LeftMargin, TopMargin, FrameSize, GapX, GapY
    global BarWidth, PickingMode
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
    if (mx >= BarWidth)
        return
    if (mx < LeftMargin || my < TopMargin)
        return
    col := (mx - LeftMargin) // (FrameSize + GapX)
    row := (my - TopMargin) // (FrameSize + GapY)
    if (col >= GridCols || row >= GridRows)
        return
    fx := LeftMargin + col * (FrameSize + GapX)
    fy := TopMargin + row * (FrameSize + GapY)
    if (mx > fx + FrameSize || my > fy + FrameSize)
        return
    idx := row * GridCols + col + 1
    if (idx <= MaxWs)
        SwitchToWs(idx)
}

OnMessage(0x0203, WM_LBUTTONDBLCLK)
WM_LBUTTONDBLCLK(wParam, lParam, msg, hwnd) {
    global hBar, BarWidth, PaletteWidth, BarHeight, PickingMode, PaletteScrollOffset
    if (hwnd != hBar)
        return
    mx := (lParam & 0xFFFF)
    my := ((lParam >> 16) & 0xFFFF)
    if (mx > 32767)
        mx -= 65536
    if (my > 32767)
        my -= 65536
    if (mx >= BarWidth && mx <= BarWidth + PaletteWidth && my >= 0 && my <= BarHeight) {
        if (PickingMode)
            ExitPicking()
        else
            EnterPicking(PaletteScrollOffset)
    }
}

#HotIf PickingMode
$LButton::HandlePickingClick()
Esc::ExitPicking()
#HotIf

!1:: SwitchToWs(1)
!2:: SwitchToWs(2)
!3:: SwitchToWs(3)
!4:: SwitchToWs(4)

^!1:: MoveWindowToWs(1)
^!2:: MoveWindowToWs(2)
^!3:: MoveWindowToWs(3)
^!4:: MoveWindowToWs(4)

![:: {
    global CurrentWs, GridCols
    col := Mod(CurrentWs - 1, GridCols)
    row := (CurrentWs - 1) // GridCols
    col := Mod(col - 1 + GridCols, GridCols)
    SwitchToWs(row * GridCols + col + 1)
}

!]:: {
    global CurrentWs, GridCols, GridRows
    col := Mod(CurrentWs - 1, GridCols)
    row := (CurrentWs - 1) // GridCols
    row := Mod(row + 1, GridRows)
    SwitchToWs(row * GridCols + col + 1)
}

F9:: ReloadLayouts()

ScanWindows()
Render()
DllCall("ShowWindow", "Ptr", hBar, "Int", 4)
Log("启动完成")

F10:: {
    Log("========== F10 退出 ==========")
    ExitApp
}