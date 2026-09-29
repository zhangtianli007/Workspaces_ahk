; ============================================================================
;  Workspaces.ahk  ——  工作区 / 布局管理器
; ============================================================================
;  功能概览
;    · 4 个工作区，每个工作区独立管理一组窗口
;    · 屏幕左侧常驻一个悬浮侧边栏：
;        - 数字格子（2×2）  → 单击切换工作区
;        - 右侧转盘（3 个槽）→ 滚轮翻页，双击进入"冻结模式"
;    · 冻结模式下点击窗口，按所选布局排列窗口
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
;  跨进程操作窗口需要管理员权限，非管理员启动时自动以管理员身份重启。
if !A_IsAdmin {
    try Run '*RunAs "' A_ScriptFullPath '"'
    ExitApp
}

; ============================================================================
;  2. 日志系统
; ============================================================================
DEBUG := false
LOG_PATH := A_Desktop "\Workspaces.log"

; 输出一行日志（仅在 DEBUG 为 true 时生效）
Log(msg) {
    global DEBUG, LOG_PATH
    if !DEBUG
        return
    try {
        t := FormatTime(A_Now, "HH:mm:ss") "." SubStr(Format("{:03}", A_MSec), 1, 3)
        FileAppend t "  " msg "`n", LOG_PATH, "UTF-8"
    }
}

; 每次启动清空旧日志
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
Switching     := false   ; 是否正在切换工作区（用于屏蔽 ScanWindows 重入）
LastSwitchEnd := 0       ; 上次切换结束时刻
SwitchGuardMs := 300     ; 切换后多少毫秒内忽略前台变化

LastFocused     := Map()    ; ws   => 该工作区最近获得焦点的窗口 hwnd
ScriptMinimized := Map()    ; hwnd => true（被脚本最小化，切回时恢复）

ExcludedProcesses := ["python.exe", "pythonw.exe"]              ; 不纳入管理的进程
ExcludedClasses   := ["XamlExplorerHostIslandWindow_WASDK"]     ; 不纳入管理的窗口类

; ============================================================================
;  5. 工作区
; ============================================================================
MaxWs     := 4          ; 工作区总数
CurrentWs := 1          ; 当前工作区编号
WinToWs   := Map()      ; hwnd => 所属工作区

; ============================================================================
;  6. 侧边栏几何参数
; ============================================================================
GridCols         := 2   ; 数字格子列数
GridRows         := 2   ; 数字格子行数
FrameSize        := 40  ; 单个格子边长
GapX             := 8   ; 格子水平间距
GapY             := 8   ; 格子垂直间距
LeftMargin       := 4   ; 侧边栏左边距
TopMargin        := 4   ; 侧边栏上边距
FontSize         := 22  ; 格子数字字号
CornerRadius     := 10  ; 格子圆角半径
TopHotZoneHeight := 40  ; 屏幕顶部滚轮热区高度

; 数字格子配色（ARGB）
FrameColor       := 0xFF1E5A2E   ; 非活动格背景
FrameColorActive := 0xFF2E8B47   ; 当前工作区格背景
TextColor        := 0xFFB3D9FF   ; 非活动格文字
TextColorActive  := 0xFFFFFFFF   ; 活动格文字

; 转盘配色（ARGB）
PaletteFrameColor  := 0xFF1E3A5A
PaletteFrameActive := 0xFF2E6AB0
PaletteTextColor   := 0xFFA8C8E8
PaletteTextActive  := 0xFFFFFFFF

; 冻结模式下的格子配色
PickingIdleFrame := 0xFF3A3A3A
PickingIdleText  := 0xFF888888
PickingDoneFrame := 0xFFAAAAAA   ; 已选窗口对应的格
PickingDoneText  := 0xFFFFFFFF

; 选中窗口高亮
HighlightColor      := 0x1E00FFCC ; 半透明青色（alpha = 30 / 255）
HighlightRadius     := 28         ; 圆角半径，数值越大越圆
HighlightDurationMs := 350        ; 高亮停留时长（毫秒）

; 侧边栏总尺寸（由上面几何参数推导）
BarWidth  := LeftMargin * 2 + GridCols * FrameSize + (GridCols - 1) * GapX
BarHeight := TopMargin  * 2 + GridRows * FrameSize + (GridRows - 1) * GapY

PaletteWidth := 40                        ; 转盘宽度
TotalWidth   := BarWidth + PaletteWidth   ; 侧边栏总宽
PaletteSlots := 3                         ; 转盘可见槽数（中间为激活槽）
PaletteSlotH := BarHeight // PaletteSlots ; 每个槽的高度

PaletteRadiusActive := 17   ; 中间槽半径
PaletteRadiusIdle   := 6    ; 上下槽半径
PaletteFontActive   := 19   ; 中间槽字号
PaletteFontIdle     := 11   ; 上下槽字号

; ============================================================================
;  7. 布局定义
; ============================================================================
;  每个布局字段：
;    id       : 编号（显示在转盘上）
;    name     : 名称（仅用于日志）
;    windows  : 需要的窗口数量
;    cells    : 每个窗口的相对位置 [x, y, w, h]，取值 0.0~1.0，相对工作区
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

; 把 DefaultLayouts 序列化为 JSON 字符串（首次运行时生成模板）
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

; 首次运行时生成 JSON 模板
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

; 从 JSON 文件加载布局（正则解析固定结构，避免外部依赖）
; 返回 true 表示成功；失败时全局 Layouts 保持不变
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

    ; 去掉 UTF-8 BOM
    if (SubStr(text, 1, 1) = Chr(0xFEFF))
        text := SubStr(text, 2)

    ; 单个布局对象
    layoutPattern := '(?s)"id"\s*:\s*(\d+)\s*,\s*"name"\s*:\s*"([^"]*)"\s*,\s*"windows"\s*:\s*(\d+)\s*,\s*"cells"\s*:\s*(\[\[.*?\]\])'
    ; 单个 cell [x, y, w, h]
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

        ; cell 数量少于 windows 数量 → 布局无效，跳过
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

; 加载布局；失败时回退到内置默认布局
Layouts := []
if (!LoadLayouts()) {
    Layouts := DefaultLayouts.Clone()
    Log("使用内置默认布局: " Layouts.Length " 个")
    EnsureLayoutsFile()
}

; ============================================================================
;  8. 冻结模式状态
; ============================================================================
PaletteScrollOffset := 1        ; 转盘对齐到第几个布局（1-based）

PickingMode      := false       ; 是否处于冻结模式
PickingLayoutIdx := 0           ; 冻结模式下选中的布局索引
PickingSelected  := 0           ; 已选窗口数量
PickingWindows   := []          ; 已选窗口 hwnd 列表

TaskbarClickRetry := 0          ; 通过任务栏选择时的重试计数
MaskShown         := false      ; 暗幕是否可见（防止重复 ShowWindow 造成闪烁）

; ============================================================================
;  9. GDI+ 初始化与屏幕尺寸
; ============================================================================
si := Buffer(24, 0)
NumPut("UInt", 1, si, 0)
GdipToken := 0
DllCall("gdiplus\GdiplusStartup", "UPtr*", &GdipToken, "Ptr", si, "Ptr", 0)

ScreenW := A_ScreenWidth
ScreenH := A_ScreenHeight
MaskH   := ScreenH - 20          ; 暗幕高度（底部留 20px 给任务栏）

; ============================================================================
;  10. 创建三个分层窗口
; ============================================================================
;  hBar  : 侧边栏
;  hMask : 冻结模式下的全屏暗幕
;  hHL   : 选中窗口高亮层
; ============================================================================

gBar := Gui("-Caption +AlwaysOnTop +ToolWindow +E0x08000000 +E0x80000")
gBar.Show("x0 y0 w" TotalWidth " h" BarHeight " NoActivate")
hBar := gBar.Hwnd
Log("侧边栏 hwnd=" hBar)

gMask := Gui("-Caption +AlwaysOnTop +ToolWindow +E0x08000000 +E0x80000 +E0x20")
gMask.Show("x0 y0 w" ScreenW " h" MaskH " NoActivate Hide")
hMask := gMask.Hwnd

gHL := Gui("-Caption +AlwaysOnTop +ToolWindow +E0x08000000 +E0x80000 +E0x20")
gHL.Show("x0 y0 w" ScreenW " h" ScreenH " NoActivate Hide")
hHL := gHL.Hwnd

; ----------------------------------------------------------------------------
;  10.1 渲染暗幕位图并绑定到 hMask
;       只绘制一次，之后 ShowWindow 即可，不需要每帧重画
; ----------------------------------------------------------------------------
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

; ----------------------------------------------------------------------------
;  10.2 显示/隐藏暗幕
;       MaskShown 记录状态，避免重复 ShowWindow 造成 DWM 重绘闪烁
; ----------------------------------------------------------------------------
ShowMask(show) {
    global hMask, hBar, hHL, MaskShown
    if (show = MaskShown)
        return
    MaskShown := show
    DllCall("ShowWindow", "Ptr", hMask, "Int", show ? 4 : 0)
    if (show) {
        ; 显示暗幕时把侧边栏和高亮层置顶
        DllCall("SetWindowPos", "Ptr", hBar, "Ptr", -1, "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x0003)
        DllCall("SetWindowPos", "Ptr", hHL, "Ptr", -1, "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x0003)
    }
}

; ----------------------------------------------------------------------------
;  10.3 鼠标靠近任务栏时临时隐藏暗幕
;       让用户能看到并点击任务栏图标
; ----------------------------------------------------------------------------
CheckTaskbarZone() {
    global PickingMode, hMask, MaskShown
    if (!PickingMode)
        return
    MouseGetPos &mx, &my, , , 1
    want := (my < A_ScreenHeight - 40)
    if (want = MaskShown)
        return
    MaskShown := want
    DllCall("ShowWindow", "Ptr", hMask, "Int", want ? 4 : 0)
    Log("Mask " (want ? "显示" : "隐藏"))
}
SetTimer(CheckTaskbarZone, 80)

; ============================================================================
;  11. 高亮效果
; ============================================================================
;  只高亮"最新加入选列表"的窗口。
;  每次选中时重绘整个高亮层，HighlightDurationMs 后自动隐藏。
; ============================================================================
RefreshHighlights() {
    global hHL, PickingWindows, HighlightColor, HighlightRadius, ScreenW, ScreenH, HighlightDurationMs

    if (PickingWindows.Length = 0) {
        DllCall("ShowWindow", "Ptr", hHL, "Int", 0)
        return
    }

    ; 只取最后一个窗口
    hwnd := PickingWindows[PickingWindows.Length]
    if !WinExist("ahk_id " hwnd) {
        Log("RefreshHL: 最新 hwnd=" hwnd " 已失效")
        DllCall("ShowWindow", "Ptr", hHL, "Int", 0)
        return
    }

    ; 取窗口位置；失败则放弃本次高亮
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

    ; 过滤异常坐标（最小化残留 / 超出屏幕）
    if (ww <= 0 || wh <= 0 || wx <= -10000 || wy <= -10000 || ww > ScreenW || wh > ScreenH) {
        Log("RefreshHL:   坐标异常，跳过")
        DllCall("ShowWindow", "Ptr", hHL, "Int", 0)
        return
    }

    ; ---- 绘制全屏透明位图，在窗口位置画一个圆角矩形 ----
    pBitmap := 0
    DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", ScreenW, "Int", ScreenH, "Int", 0, "Int", 0x000E200B, "Ptr", 0, "Ptr*", &pBitmap)
    pGraphics := 0
    DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", pBitmap, "Ptr*", &pGraphics)
    DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", pGraphics, "Int", 4)

    ; 铺一层几乎全透明的背景，保证 layered window 有内容
    pBg := 0
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", 0x01000000, "Ptr*", &pBg)
    DllCall("gdiplus\GdipFillRectangleI", "Ptr", pGraphics, "Ptr", pBg, "Int", 0, "Int", 0, "Int", ScreenW, "Int", ScreenH)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", pBg)

    ; 用 4 段圆弧拼出圆角矩形路径并填充
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

    ; ---- 把位图贴到 hHL ----
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

; 高亮任意 hwnd（用于"选中失败"时的反馈）
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

    ; ---- 位图与画布 ----
    pBitmap := 0
    DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", TotalWidth, "Int", BarHeight, "Int", 0, "Int", 0x000E200B, "Ptr", 0, "Ptr*", &pBitmap)
    pGraphics := 0
    DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", pBitmap, "Ptr*", &pGraphics)
    DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", pGraphics, "Int", 4)
    DllCall("gdiplus\GdipSetTextRenderingHint", "Ptr", pGraphics, "Int", 5)

    ; 整块背景
    pBgBrush := 0
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", 0x01000000, "Ptr*", &pBgBrush)
    DllCall("gdiplus\GdipFillRectangleI", "Ptr", pGraphics, "Ptr", pBgBrush, "Int", 0, "Int", 0, "Int", TotalWidth, "Int", BarHeight)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", pBgBrush)

    ; ---- 字体与排版 ----
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

    ; ---- 数字格子 ----
    if (PickingMode) {
        ; 冻结模式：显示已选数量
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
        ; 普通模式：显示工作区编号，当前工作区高亮
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

    ; ---- 转盘 ----
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

        ; 圆形背景
        pBrush := 0
        DllCall("gdiplus\GdipCreateSolidFill", "UInt", cFrame, "Ptr*", &pBrush)
        DllCall("gdiplus\GdipFillEllipse", "Ptr", pGraphics, "Ptr", pBrush, "Float", slotCenterX - radius, "Float", slotCenterY - radius, "Float", radius * 2, "Float", radius * 2)
        DllCall("gdiplus\GdipDeleteBrush", "Ptr", pBrush)

        ; 居中文字
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

    ; ---- 释放 ----
    DllCall("gdiplus\GdipDeleteFont", "Ptr", pFontNum)
    DllCall("gdiplus\GdipDeleteFont", "Ptr", pFontActive)
    DllCall("gdiplus\GdipDeleteFont", "Ptr", pFontIdle)
    DllCall("gdiplus\GdipDeleteFontFamily", "Ptr", pFamily)
    DllCall("gdiplus\GdipDeleteStringFormat", "Ptr", pSf)
    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", pGraphics)

    ; ---- 贴到 hBar ----
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

; 画一个圆角方块
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

; 在 size×size 的方块里居中绘制文字
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

; 取窗口的 owner（GW_OWNER）
GetOwner(hwnd) {
    try {
        return DllCall("GetWindow", "Ptr", hwnd, "UInt", 4, "Ptr")
    } catch {
        return 0
    }
}

; 从 hwnd 一路沿 owner 向上找第一个"可追踪"窗口
; 找不到返回 0
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

; 是否是任务栏 / 缩略图相关窗口
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

; 判断一个窗口是否应该被本脚本管理
ShouldTrack(hwnd) {
    global hBar, hMask, hHL, ExcludedProcesses, ExcludedClasses
    if (hwnd = hBar || hwnd = hMask || hwnd = hHL)
        return false
    try {
        cls := WinGetClass("ahk_id " hwnd)
        ; 桌面 / 任务栏
        if (cls = "Shell_TrayWnd" || cls = "Shell_SecondaryTrayWnd" || cls = "Progman" || cls = "WorkerW")
            return false
        ; 用户排除类
        for _, c in ExcludedClasses {
            if (cls = c)
                return false
        }
        ; 工具窗口（WS_EX_TOOLWINDOW）
        exStyle := WinGetExStyle("ahk_id " hwnd)
        if (exStyle & 0x80)
            return false
        ; 无标题窗口
        title := WinGetTitle("ahk_id " hwnd)
        if (title = "")
            return false
        ; 用户排除进程
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

; ============================================================================
;  14. 工作区切换
; ============================================================================

; 切到目标工作区：把当前 ws 的窗口最小化，恢复目标 ws 的窗口
SwitchToWs(target) {
    global CurrentWs, WinToWs, MaxWs, Switching, LastSwitchEnd
    global LastFocused, ScriptMinimized
    if (target < 1 || target > MaxWs)
        return
    if (target = CurrentWs)
        return

    Switching := true
    old := CurrentWs

    ; 记录当前 ws 的前台窗口
    fg := WinExist("A")
    realFg := FindTrackableWindow(fg)
    if (realFg && WinToWs.Has(realFg) && WinToWs[realFg] = old)
        LastFocused[old] := realFg

    CurrentWs := target
    Log("SwitchToWs " old " -> " target)

    ; 最小化所有不属于 target 的窗口
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

    ; 恢复 target 组里被脚本最小化的窗口（优先恢复上次的焦点窗口）
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

    ; 最后恢复上次焦点窗口并激活
    if (lf && WinToWs.Has(lf) && WinToWs[lf] = target && ScriptMinimized.Has(lf) && WinExist("ahk_id " lf)) {
        try {
            WinRestore("ahk_id " lf)
            ScriptMinimized.Delete(lf)
            ; 同时恢复其附属窗口
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

; 把当前窗口移动到目标工作区；如果目标不是当前 ws，顺带切过去
MoveWindowToWs(target) {
    global WinToWs, CurrentWs, MaxWs, ScriptMinimized, LastFocused
    if (target < 1 || target > MaxWs)
        return

    fg := WinExist("A")
    targetHwnd := 0

    ; 优先取前台窗口
    if (fg) {
        candidate := FindTrackableWindow(fg)
        if (candidate)
            targetHwnd := candidate
    }
    ; 退而取当前 ws 上一次的焦点窗口
    if (!targetHwnd && LastFocused.Has(CurrentWs)) {
        lf := LastFocused[CurrentWs]
        if (WinExist("ahk_id " lf) && WinToWs.Has(lf) && WinToWs[lf] = CurrentWs)
            targetHwnd := lf
    }
    ; 再退而取当前 ws 里任意一个可见窗口
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

    ; 有 owner 就跟着 owner 一起走
    owner := GetOwner(targetHwnd)
    if (owner && (WinToWs.Has(owner) || ShouldTrack(owner)))
        targetHwnd := owner

    WinToWs[targetHwnd] := target
    for h, ws in WinToWs.Clone() {
        if (GetOwner(h) = targetHwnd)
            WinToWs[h] := target
    }
    LastFocused[target] := targetHwnd

    ; 目标非当前 ws → 立刻最小化并切过去
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
    global PickingMode

    ; ---- 1) 发现新窗口，登记到当前 ws ----
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
        ; 有 owner 已登记 → 跟随其 ws
        owner := GetOwner(hwnd)
        if (owner && WinToWs.Has(owner)) {
            WinToWs[hwnd] := WinToWs[owner]
            continue
        }
        WinToWs[hwnd] := CurrentWs
    }

    ; ---- 2) 清理已销毁的窗口 ----
    for hwnd, ws in WinToWs.Clone() {
        if !WinExist("ahk_id " hwnd) {
            WinToWs.Delete(hwnd)
            if (ScriptMinimized.Has(hwnd))
                ScriptMinimized.Delete(hwnd)
        }
    }

    ; ---- 3) 前台窗口属于其他 ws 时自动跟随 ----
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

; 取当前显示器工作区（排除任务栏后的可用区域）
GetWorkArea() {
    rect := Buffer(16, 0)
    DllCall("SystemParametersInfoW", "UInt", 0x0030, "UInt", 0, "Ptr", rect, "UInt", 0)
    x := NumGet(rect, 0, "Int")
    y := NumGet(rect, 4, "Int")
    r := NumGet(rect, 8, "Int")
    b := NumGet(rect, 12, "Int")
    return { x: x, y: y, w: r - x, h: b - y }
}

; 把窗口列表按指定布局排列
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
        ; 最小化的先恢复
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

; 进入冻结模式，等待用户挑选 layoutIdx 所需数量的窗口
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

; 退出冻结模式
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

; 处理"冻结模式下点击了某个窗口"
ProcessPickWindow(mhwnd) {
    global PickingMode, PickingWindows, PickingSelected, PickingLayoutIdx, Layouts
    global CurrentWs, WinToWs, hBar, hMask, hHL, HighlightDurationMs

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

    ; 未登记 → 主动扫描一次；仍无 → 兜底登记到当前 ws
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

    PickingWindows.Push(realHwnd)
    PickingSelected := PickingWindows.Length
    need := Layouts[PickingLayoutIdx].windows
    Log("Pick: 加入选列表 (" PickingSelected "/" need ") hwnd=" realHwnd)

    RefreshHighlights()
    Render()

    ; 选够 → 延迟一点应用布局，让用户看到高亮
    if (PickingSelected >= need) {
        Log("Pick: 选取完成，" HighlightDurationMs "ms 后应用布局")
        SetTimer(FinishSelection, -HighlightDurationMs)
    }
}

; 选够窗口后真正应用布局
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
;  18. 冻结模式下的鼠标交互
; ============================================================================

; 冻结模式下左键点击
HandlePickingClick() {
    global PickingMode, hBar, hMask, hHL, TaskbarClickRetry

    if (!PickingMode)
        return

    MouseGetPos &mx, &my, &mhwnd, , 1
    mClass := "", mTitle := ""
    try mClass := WinGetClass("ahk_id " mhwnd)
    try mTitle := WinGetTitle("ahk_id " mhwnd)
    Log("PickingClick: pos=" mx "," my " hwnd=" mhwnd " cls=[" mClass "] title=[" mTitle "]")

    if (mhwnd = hBar || mhwnd = hMask || mhwnd = hHL) {
        Log("PickingClick: 命中脚本窗口，忽略")
        return
    }

    ; 点在任务栏 / 缩略图上 → 转发点击，稍后检查前台
    if (IsTaskbarWindow(mhwnd)) {
        Log("PickingClick: 命中任务栏/缩略图 cls=[" mClass "]，转发点击并延迟检查前台")
        SendInput "{LButton}"
        TaskbarClickRetry := 0
        SetTimer(CheckForegroundAfterTaskbarClick, -250)
        return
    }

    ProcessPickWindow(mhwnd)
}

; 任务栏点击后，延迟检查前台窗口（最多重试 15 次 × 200ms）
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

    ; 前台仍是任务栏相关窗口 → 再等
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

; 屏幕顶部横条 或 左侧竖条（缩窄到 60%） 或 转盘区
IsOverScrollZone() {
    global TotalWidth, BarWidth, BarHeight, TopHotZoneHeight, ScreenW, ScreenH
    MouseGetPos &mx, &my, , , 1
    inTop     := (my >= 0 && my <= TopHotZoneHeight && mx >= 0 && mx <= ScreenW)
    inLeft    := (mx >= 0 && mx <= TotalWidth * 0.6 && my >= 0 && my <= ScreenH)
    inPalette := (mx >= BarWidth && mx <= TotalWidth && my >= 0 && my <= BarHeight)
    return inTop || inLeft || inPalette
}

; 鼠标是否在转盘区
IsOverPaletteZone() {
    global BarWidth, PaletteWidth, BarHeight
    MouseGetPos &mx, &my, , , 1
    return (mx >= BarWidth && mx <= BarWidth + PaletteWidth && my >= 0 && my <= BarHeight)
}

; 转盘滚动
PaletteScroll(delta) {
    global PaletteScrollOffset, Layouts
    N := Layouts.Length
    PaletteScrollOffset := Mod(PaletteScrollOffset - 1 + delta + N, N) + 1
    Log("转盘滚动 -> idx=" PaletteScrollOffset " (id=" Layouts[PaletteScrollOffset].id ")")
    Render()
}

; 重新从 JSON 加载布局
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

; 侧边栏左键单击：切换工作区
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

; 侧边栏左键双击：进入 / 退出冻结模式
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

; 冻结模式下的按键绑定
#HotIf PickingMode
$LButton::HandlePickingClick()
Esc::ExitPicking()
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
Log("启动完成")
