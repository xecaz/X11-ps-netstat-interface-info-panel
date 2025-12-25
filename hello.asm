default rel
global main

; Xlib
extern XOpenDisplay
extern XDefaultScreen
extern XRootWindow
extern XCreateSimpleWindow
extern XSelectInput
extern XMapWindow
extern XNextEvent
extern XPending
extern XStoreName
extern XFlush
extern XDefaultVisual
extern XDisplayWidth
extern XDisplayHeight
extern XInternAtom
extern XChangeProperty
extern XGrabKeyboard
extern XUngrabKeyboard
extern exit

; timing
extern clock_gettime
extern nanosleep

; shim
extern shim_get_window_size
extern shim_query_pointer
extern shim_netstat
extern shim_ps_tree
extern shim_netdev
extern shim_count_lines
extern shim_slice_lines

; Cairo
extern cairo_xlib_surface_create
extern cairo_xlib_surface_set_size
extern cairo_create
extern cairo_destroy
extern cairo_surface_destroy
extern cairo_set_source_rgb
extern cairo_paint
extern cairo_move_to
extern cairo_rectangle
extern cairo_fill
extern cairo_stroke
extern cairo_set_line_width

; Pango
extern pango_cairo_create_layout
extern pango_cairo_show_layout
extern pango_layout_set_text
extern pango_layout_set_width
extern pango_font_description_from_string
extern pango_layout_set_font_description
extern pango_font_description_free

; X11 constants
%define KeyPress            2
%define ButtonPress         4
%define Expose             12
%define ConfigureNotify    22

%define KeyPressMask           0x00000001
%define ButtonPressMask        0x00000004
%define ExposureMask           0x00008000
%define StructureNotifyMask    0x00020000

%define CLOCK_MONOTONIC 1

%define PropModeReplace 0
%define GrabModeAsync 1
%define CurrentTime   0

; Views
%define VIEW_NETSTAT 0
%define VIEW_PS      1
%define VIEW_NET     2

; UI sizes
%define Y_OFFSET   48          ; push dock down to avoid top bar covering tabs
%define TOPBAR_H   72
%define BOTBAR_H   52

; Layout positions (in pixels)
%define HDR_Y      105
%define BODY_Y     165

; Scroll
%define LINE_PX    32          ; approx line height for font 24
%define SCROLL_STEP 5          ; lines per click

SECTION .rodata
dq_0 dq 0.0
dq_1 dq 1.0
dq_2 dq 2.0
dq_4 dq 4.0
dq_10 dq 10.0
dq_12 dq 12.0
dq_18 dq 18.0
dq_22 dq 22.0
dq_28 dq 28.0
dq_44 dq 44.0
dq_56 dq 56.0
dq_hdr_y dq HDR_Y
dq_body_y dq BODY_Y

; Colors
dq_bg_r dq 0.0
dq_bg_g dq 0.0
dq_bg_b dq 0.0

dq_bar_r dq 0.10
dq_bar_g dq 0.10
dq_bar_b dq 0.10

dq_btn_r dq 0.18
dq_btn_g dq 0.18
dq_btn_b dq 0.18

dq_green_r dq 0.0
dq_green_g dq 1.0
dq_green_b dq 0.0

dq_btn_h dq 44.0
dq_ul_h  dq 4.0

SECTION .data
wintitle db "ASM Dock Panel (Netstat / PS / Net)", 0
header   db "Dock panel — tabs + scroll; any key exits — 世界 🌍", 0
fontdesc_str db "DejaVu Sans Bold 24", 0

label_netstat db "Netstat",0
label_ps      db "PS",0
label_net     db "Net",0
label_up      db "Up",0
label_down    db "Down",0

; atoms names
str_ATOM                    db "ATOM",0
str_CARDINAL                db "CARDINAL",0
str_NET_WM_STATE            db "_NET_WM_STATE",0
str_NET_WM_STATE_ABOVE      db "_NET_WM_STATE_ABOVE",0
str_NET_WM_WINDOW_TYPE      db "_NET_WM_WINDOW_TYPE",0
str_NET_WM_WINDOW_TYPE_DOCK db "_NET_WM_WINDOW_TYPE_DOCK",0
str_NET_WM_STRUT            db "_NET_WM_STRUT",0
str_NET_WM_STRUT_PARTIAL    db "_NET_WM_STRUT_PARTIAL",0
str_MOTIF_WM_HINTS          db "_MOTIF_WM_HINTS",0

SECTION .bss
event resb 192

dpy    resq 1
win    resq 1
screen resd 1
visual resq 1

screen_w resd 1
screen_h resd 1

w_width  resd 1
w_height resd 1

mouse_x resd 1
mouse_y resd 1

view_mode  resd 1
scroll_line resd 1
total_lines resd 1

cairo_surface resq 1
cairo_ctx     resq 1
pango_layout  resq 1
pango_fontdesc resq 1

; Full output (big), and the sliced view (what we render)
fullbuf resb 65536
viewbuf resb 16384

; timespecs
ts_now   resq 2
ts_next  resq 2
ts_sleep resq 2

; atoms
atom_ATOM resq 1
atom_CARDINAL resq 1
atom_NET_WM_STATE resq 1
atom_NET_WM_STATE_ABOVE resq 1
atom_NET_WM_WINDOW_TYPE resq 1
atom_NET_WM_WINDOW_TYPE_DOCK resq 1
atom_NET_WM_STRUT resq 1
atom_NET_WM_STRUT_PARTIAL resq 1
atom_MOTIF_WM_HINTS resq 1

state_above_list resq 1
type_dock_list   resq 1
motif_hints      resd 5

strut_partial resd 12
strut_basic   resd 4

SECTION .text

; -------------------------
; helpers
; -------------------------
update_mouse_coords:
    sub rsp, 8
    mov rdi, [dpy]
    mov rsi, [win]
    lea rdx, [mouse_x]
    lea rcx, [mouse_y]
    call shim_query_pointer
    add rsp, 8
    ret

update_window_size:
    sub rsp, 8
    mov rdi, [dpy]
    mov rsi, [win]
    lea rdx, [w_width]
    lea rcx, [w_height]
    call shim_get_window_size
    add rsp, 8
    ret

; max_lines_visible = (w_height - BOTBAR_H - BODY_Y) / LINE_PX, at least 1
get_max_lines_visible:
    mov eax, [w_height]
    sub eax, BOTBAR_H
    sub eax, BODY_Y
    cmp eax, LINE_PX
    jge .ok
    mov eax, 1
    ret
.ok:
    cdq
    mov ecx, LINE_PX
    idiv ecx
    cmp eax, 1
    jge .done
    mov eax, 1
.done:
    ret

; clamp scroll_line into [0, max(0, total_lines - max_lines)]
clamp_scroll:
    sub rsp, 8
    ; total_lines = shim_count_lines(fullbuf)
    lea rdi, [fullbuf]
    call shim_count_lines
    mov [total_lines], eax

    call get_max_lines_visible
    mov ebx, eax                 ; max_lines

    mov eax, [total_lines]
    sub eax, ebx
    cmp eax, 0
    jg .have_max
    xor eax, eax                 ; max_scroll = 0
.have_max:
    mov ecx, [scroll_line]
    cmp ecx, 0
    jge .chk_hi
    mov dword [scroll_line], 0
    jmp .done
.chk_hi:
    cmp ecx, eax
    jle .done
    mov [scroll_line], eax
.done:
    add rsp, 8
    ret

; slice fullbuf into viewbuf based on scroll_line & max_lines_visible
slice_for_render:
    sub rsp, 8
    call get_max_lines_visible
    mov r9d, eax               ; max_lines

    lea rdi, [fullbuf]         ; src
    lea rsi, [viewbuf]         ; dst
    mov edx, 16384             ; dstlen
    mov ecx, [scroll_line]     ; start_line
    mov r8d, r9d               ; max_lines
    call shim_slice_lines
    add rsp, 8
    ret

; fetch fullbuf based on active view
fetch_view_output:
    sub rsp, 8
    cmp dword [view_mode], VIEW_PS
    je .ps
    cmp dword [view_mode], VIEW_NET
    je .net

    ; netstat
    lea rdi, [fullbuf]
    mov esi, 65536
    call shim_netstat
    jmp .done
.ps:
    lea rdi, [fullbuf]
    mov esi, 65536
    call shim_ps_tree
    jmp .done
.net:
    lea rdi, [fullbuf]
    mov esi, 65536
    call shim_netdev
.done:
    add rsp, 8
    ret

time_due:
    mov rax, [ts_now + 0]
    mov rdx, [ts_next + 0]
    cmp rax, rdx
    ja  .yes
    jb  .no
    mov rax, [ts_now + 8]
    mov rdx, [ts_next + 8]
    cmp rax, rdx
    jae .yes
.no:
    xor eax, eax
    ret
.yes:
    mov eax, 1
    ret

set_next_plus_1s:
    mov rax, [ts_now + 0]
    inc rax
    mov [ts_next + 0], rax
    mov rax, [ts_now + 8]
    mov [ts_next + 8], rax
    ret

create_cairo_objects:
    sub rsp, 8

    mov rdi, [dpy]
    mov rsi, [win]
    mov rdx, [visual]
    mov ecx, [w_width]
    mov r8d, [w_height]
    call cairo_xlib_surface_create
    mov [cairo_surface], rax

    mov rdi, rax
    call cairo_create
    mov [cairo_ctx], rax

    mov rdi, [cairo_ctx]
    call pango_cairo_create_layout
    mov [pango_layout], rax

    lea rdi, [fontdesc_str]
    call pango_font_description_from_string
    mov [pango_fontdesc], rax

    mov rdi, [pango_layout]
    mov rsi, [pango_fontdesc]
    call pango_layout_set_font_description

    ; width in Pango units = px * 1024
    mov eax, [w_width]
    imul eax, eax, 1024
    mov rdi, [pango_layout]
    mov esi, eax
    call pango_layout_set_width

    add rsp, 8
    ret

destroy_cairo_objects:
    sub rsp, 8
    mov rax, [pango_fontdesc]
    test rax, rax
    jz .skip_font
    mov rdi, rax
    call pango_font_description_free
    mov qword [pango_fontdesc], 0
.skip_font:
    mov rax, [cairo_ctx]
    test rax, rax
    jz .skip_cr
    mov rdi, rax
    call cairo_destroy
    mov qword [cairo_ctx], 0
.skip_cr:
    mov rax, [cairo_surface]
    test rax, rax
    jz .done
    mov rdi, rax
    call cairo_surface_destroy
    mov qword [cairo_surface], 0
.done:
    add rsp, 8
    ret

sync_pango_width:
    sub rsp, 8
    mov eax, [w_width]
    imul eax, eax, 1024
    mov rdi, [pango_layout]
    mov esi, eax
    call pango_layout_set_width
    add rsp, 8
    ret

; ---- Set DOCK + ABOVE + no decorations + right strut ----
set_dock_properties:
    sub rsp, 8

    ; Intern needed atoms
    mov rdi, [dpy]
    lea rsi, [str_ATOM]
    xor edx, edx
    call XInternAtom
    mov [atom_ATOM], rax

    mov rdi, [dpy]
    lea rsi, [str_CARDINAL]
    xor edx, edx
    call XInternAtom
    mov [atom_CARDINAL], rax

    mov rdi, [dpy]
    lea rsi, [str_NET_WM_STATE]
    xor edx, edx
    call XInternAtom
    mov [atom_NET_WM_STATE], rax

    mov rdi, [dpy]
    lea rsi, [str_NET_WM_STATE_ABOVE]
    xor edx, edx
    call XInternAtom
    mov [atom_NET_WM_STATE_ABOVE], rax

    mov rdi, [dpy]
    lea rsi, [str_NET_WM_WINDOW_TYPE]
    xor edx, edx
    call XInternAtom
    mov [atom_NET_WM_WINDOW_TYPE], rax

    mov rdi, [dpy]
    lea rsi, [str_NET_WM_WINDOW_TYPE_DOCK]
    xor edx, edx
    call XInternAtom
    mov [atom_NET_WM_WINDOW_TYPE_DOCK], rax

    mov rdi, [dpy]
    lea rsi, [str_NET_WM_STRUT]
    xor edx, edx
    call XInternAtom
    mov [atom_NET_WM_STRUT], rax

    mov rdi, [dpy]
    lea rsi, [str_NET_WM_STRUT_PARTIAL]
    xor edx, edx
    call XInternAtom
    mov [atom_NET_WM_STRUT_PARTIAL], rax

    mov rdi, [dpy]
    lea rsi, [str_MOTIF_WM_HINTS]
    xor edx, edx
    call XInternAtom
    mov [atom_MOTIF_WM_HINTS], rax

    ; _NET_WM_STATE = [ABOVE]
    mov rax, [atom_NET_WM_STATE_ABOVE]
    mov [state_above_list], rax
    mov rdi, [dpy]
    mov rsi, [win]
    mov rdx, [atom_NET_WM_STATE]
    mov rcx, [atom_ATOM]
    mov r8d, 32
    mov r9d, PropModeReplace
    sub rsp, 32
    lea rax, [state_above_list]
    mov [rsp+0], rax
    mov dword [rsp+8], 1
    call XChangeProperty
    add rsp, 32

    ; _NET_WM_WINDOW_TYPE = [DOCK]
    mov rax, [atom_NET_WM_WINDOW_TYPE_DOCK]
    mov [type_dock_list], rax
    mov rdi, [dpy]
    mov rsi, [win]
    mov rdx, [atom_NET_WM_WINDOW_TYPE]
    mov rcx, [atom_ATOM]
    mov r8d, 32
    mov r9d, PropModeReplace
    sub rsp, 32
    lea rax, [type_dock_list]
    mov [rsp+0], rax
    mov dword [rsp+8], 1
    call XChangeProperty
    add rsp, 32

    ; Motif hints: remove decorations
    mov dword [motif_hints + 0], 2
    mov dword [motif_hints + 4], 0
    mov dword [motif_hints + 8], 0
    mov dword [motif_hints + 12], 0
    mov dword [motif_hints + 16], 0
    mov rdi, [dpy]
    mov rsi, [win]
    mov rdx, [atom_MOTIF_WM_HINTS]
    mov rcx, [atom_MOTIF_WM_HINTS]
    mov r8d, 32
    mov r9d, PropModeReplace
    sub rsp, 32
    lea rax, [motif_hints]
    mov [rsp+0], rax
    mov dword [rsp+8], 5
    call XChangeProperty
    add rsp, 32

    ; ---- STRUT: reserve right side from y=Y_OFFSET to bottom ----
    mov dword [strut_basic + 0], 0
    mov eax, [w_width]
    mov dword [strut_basic + 4], eax
    mov dword [strut_basic + 8], 0
    mov dword [strut_basic + 12], 0

    mov dword [strut_partial + 0], 0
    mov eax, [w_width]
    mov dword [strut_partial + 4], eax
    mov dword [strut_partial + 8], 0
    mov dword [strut_partial + 12], 0

    mov dword [strut_partial + 16], 0
    mov dword [strut_partial + 20], 0

    mov eax, Y_OFFSET
    mov dword [strut_partial + 24], eax     ; right_start_y
    mov eax, [screen_h]
    dec eax
    mov dword [strut_partial + 28], eax     ; right_end_y

    mov dword [strut_partial + 32], 0
    mov dword [strut_partial + 36], 0
    mov dword [strut_partial + 40], 0
    mov dword [strut_partial + 44], 0

    ; _NET_WM_STRUT
    mov rdi, [dpy]
    mov rsi, [win]
    mov rdx, [atom_NET_WM_STRUT]
    mov rcx, [atom_CARDINAL]
    mov r8d, 32
    mov r9d, PropModeReplace
    sub rsp, 32
    lea rax, [strut_basic]
    mov [rsp+0], rax
    mov dword [rsp+8], 4
    call XChangeProperty
    add rsp, 32

    ; _NET_WM_STRUT_PARTIAL
    mov rdi, [dpy]
    mov rsi, [win]
    mov rdx, [atom_NET_WM_STRUT_PARTIAL]
    mov rcx, [atom_CARDINAL]
    mov r8d, 32
    mov r9d, PropModeReplace
    sub rsp, 32
    lea rax, [strut_partial]
    mov [rsp+0], rax
    mov dword [rsp+8], 12
    call XChangeProperty
    add rsp, 32

    add rsp, 8
    ret

; ----- UI draw -----
draw_frame:
    sub rsp, 8

    ; Update surface size
    mov rdi, [cairo_surface]
    mov esi, [w_width]
    mov edx, [w_height]
    call cairo_xlib_surface_set_size

    ; Background black
    mov rdi, [cairo_ctx]
    movsd xmm0, [rel dq_bg_r]
    movsd xmm1, [rel dq_bg_g]
    movsd xmm2, [rel dq_bg_b]
    call cairo_set_source_rgb
    mov rdi, [cairo_ctx]
    call cairo_paint

    ; Top bar fill
    mov rdi, [cairo_ctx]
    movsd xmm0, [rel dq_bar_r]
    movsd xmm1, [rel dq_bar_g]
    movsd xmm2, [rel dq_bar_b]
    call cairo_set_source_rgb
    mov rdi, [cairo_ctx]
    movsd xmm0, [rel dq_0]
    movsd xmm1, [rel dq_0]
    mov eax, [w_width]
    cvtsi2sd xmm2, eax
    mov eax, TOPBAR_H
    cvtsi2sd xmm3, eax
    call cairo_rectangle
    mov rdi, [cairo_ctx]
    call cairo_fill

    ; Bottom bar fill
    mov rdi, [cairo_ctx]
    movsd xmm0, [rel dq_bar_r]
    movsd xmm1, [rel dq_bar_g]
    movsd xmm2, [rel dq_bar_b]
    call cairo_set_source_rgb
    mov rdi, [cairo_ctx]
    movsd xmm0, [rel dq_0]
    mov eax, [w_height]
    sub eax, BOTBAR_H
    cvtsi2sd xmm1, eax
    mov eax, [w_width]
    cvtsi2sd xmm2, eax
    mov eax, BOTBAR_H
    cvtsi2sd xmm3, eax
    call cairo_rectangle
    mov rdi, [cairo_ctx]
    call cairo_fill

    ; Compute third-width for tabs
    mov eax, [w_width]
    cdq
    mov ecx, 3
    idiv ecx
    mov r12d, eax            ; tabW = w_width/3

    ; Button fill color
    mov rdi, [cairo_ctx]
    movsd xmm0, [rel dq_btn_r]
    movsd xmm1, [rel dq_btn_g]
    movsd xmm2, [rel dq_btn_b]
    call cairo_set_source_rgb

    ; Draw three tab rectangles
    ; tab0 at x=10, tab1 at x=tabW+10, tab2 at x=2*tabW+10
    ; width = tabW-15, y=12, h=44
    mov r13d, r12d
    sub r13d, 15             ; btnW

    ; tab0
    mov rdi, [cairo_ctx]
    movsd xmm0, [rel dq_10]
    movsd xmm1, [rel dq_12]
    mov eax, r13d
    cvtsi2sd xmm2, eax
    movsd xmm3, [rel dq_btn_h]
    call cairo_rectangle

    ; tab1
    mov rdi, [cairo_ctx]
    mov eax, r12d
    add eax, 10
    cvtsi2sd xmm0, eax
    movsd xmm1, [rel dq_12]
    mov eax, r13d
    cvtsi2sd xmm2, eax
    movsd xmm3, [rel dq_btn_h]
    call cairo_rectangle

    ; tab2
    mov rdi, [cairo_ctx]
    mov eax, r12d
    imul eax, 2
    add eax, 10
    cvtsi2sd xmm0, eax
    movsd xmm1, [rel dq_12]
    mov eax, r13d
    cvtsi2sd xmm2, eax
    movsd xmm3, [rel dq_btn_h]
    call cairo_rectangle

    mov rdi, [cairo_ctx]
    call cairo_fill

    ; Outline + text green
    mov rdi, [cairo_ctx]
    movsd xmm0, [rel dq_green_r]
    movsd xmm1, [rel dq_green_g]
    movsd xmm2, [rel dq_green_b]
    call cairo_set_source_rgb
    mov rdi, [cairo_ctx]
    movsd xmm0, [rel dq_2]
    call cairo_set_line_width

    ; stroke outlines
    ; tab0
    mov rdi, [cairo_ctx]
    movsd xmm0, [rel dq_10]
    movsd xmm1, [rel dq_12]
    mov eax, r13d
    cvtsi2sd xmm2, eax
    movsd xmm3, [rel dq_btn_h]
    call cairo_rectangle
    ; tab1
    mov rdi, [cairo_ctx]
    mov eax, r12d
    add eax, 10
    cvtsi2sd xmm0, eax
    movsd xmm1, [rel dq_12]
    mov eax, r13d
    cvtsi2sd xmm2, eax
    movsd xmm3, [rel dq_btn_h]
    call cairo_rectangle
    ; tab2
    mov rdi, [cairo_ctx]
    mov eax, r12d
    imul eax, 2
    add eax, 10
    cvtsi2sd xmm0, eax
    movsd xmm1, [rel dq_12]
    mov eax, r13d
    cvtsi2sd xmm2, eax
    movsd xmm3, [rel dq_btn_h]
    call cairo_rectangle

    mov rdi, [cairo_ctx]
    call cairo_stroke

    ; Active underline under selected tab
    mov eax, [view_mode]
    cmp eax, VIEW_NETSTAT
    je .ul0
    cmp eax, VIEW_PS
    je .ul1
    jmp .ul2

.ul0:
    mov rdi, [cairo_ctx]
    movsd xmm0, [rel dq_10]
    movsd xmm1, [rel dq_56]
    mov eax, r13d
    cvtsi2sd xmm2, eax
    movsd xmm3, [rel dq_4]
    call cairo_rectangle
    jmp .ul_fill
.ul1:
    mov rdi, [cairo_ctx]
    mov eax, r12d
    add eax, 10
    cvtsi2sd xmm0, eax
    movsd xmm1, [rel dq_56]
    mov eax, r13d
    cvtsi2sd xmm2, eax
    movsd xmm3, [rel dq_4]
    call cairo_rectangle
    jmp .ul_fill
.ul2:
    mov rdi, [cairo_ctx]
    mov eax, r12d
    imul eax, 2
    add eax, 10
    cvtsi2sd xmm0, eax
    movsd xmm1, [rel dq_56]
    mov eax, r13d
    cvtsi2sd xmm2, eax
    movsd xmm3, [rel dq_4]
    call cairo_rectangle
.ul_fill:
    mov rdi, [cairo_ctx]
    call cairo_fill

    ; Tab labels
    ; Netstat at (22,44)
    mov rdi, [cairo_ctx]
    movsd xmm0, [rel dq_22]
    movsd xmm1, [rel dq_44]
    call cairo_move_to
    mov rdi, [pango_layout]
    lea rsi, [label_netstat]
    mov edx, -1
    call pango_layout_set_text
    mov rdi, [cairo_ctx]
    mov rsi, [pango_layout]
    call pango_cairo_show_layout

    ; PS at (tabW+22,44)
    mov rdi, [cairo_ctx]
    mov eax, r12d
    add eax, 22
    cvtsi2sd xmm0, eax
    movsd xmm1, [rel dq_44]
    call cairo_move_to
    mov rdi, [pango_layout]
    lea rsi, [label_ps]
    mov edx, -1
    call pango_layout_set_text
    mov rdi, [cairo_ctx]
    mov rsi, [pango_layout]
    call pango_cairo_show_layout

    ; Net at (2*tabW+22,44)
    mov rdi, [cairo_ctx]
    mov eax, r12d
    imul eax, 2
    add eax, 22
    cvtsi2sd xmm0, eax
    movsd xmm1, [rel dq_44]
    call cairo_move_to
    mov rdi, [pango_layout]
    lea rsi, [label_net]
    mov edx, -1
    call pango_layout_set_text
    mov rdi, [cairo_ctx]
    mov rsi, [pango_layout]
    call pango_cairo_show_layout

    ; Header at (18, HDR_Y)
    mov rdi, [cairo_ctx]
    movsd xmm0, [rel dq_18]
    movsd xmm1, [rel dq_hdr_y]
    call cairo_move_to
    mov rdi, [pango_layout]
    lea rsi, [header]
    mov edx, -1
    call pango_layout_set_text
    mov rdi, [cairo_ctx]
    mov rsi, [pango_layout]
    call pango_cairo_show_layout

    ; Scroll buttons in bottom bar: left half = Up, right half = Down
    ; Draw labels only (bar already there)
    mov rdi, [cairo_ctx]
    movsd xmm0, [rel dq_18]
    mov eax, [w_height]
    sub eax, 16
    cvtsi2sd xmm1, eax
    call cairo_move_to
    mov rdi, [pango_layout]
    lea rsi, [label_up]
    mov edx, -1
    call pango_layout_set_text
    mov rdi, [cairo_ctx]
    mov rsi, [pango_layout]
    call pango_cairo_show_layout

    mov rdi, [cairo_ctx]
    mov eax, [w_width]
    shr eax, 1
    add eax, 18
    cvtsi2sd xmm0, eax
    mov eax, [w_height]
    sub eax, 16
    cvtsi2sd xmm1, eax
    call cairo_move_to
    mov rdi, [pango_layout]
    lea rsi, [label_down]
    mov edx, -1
    call pango_layout_set_text
    mov rdi, [cairo_ctx]
    mov rsi, [pango_layout]
    call pango_cairo_show_layout

    ; Render sliced content at (18, BODY_Y)
    call slice_for_render
    mov rdi, [cairo_ctx]
    movsd xmm0, [rel dq_18]
    movsd xmm1, [rel dq_body_y]
    call cairo_move_to
    mov rdi, [pango_layout]
    lea rsi, [viewbuf]
    mov edx, -1
    call pango_layout_set_text
    mov rdi, [cairo_ctx]
    mov rsi, [pango_layout]
    call pango_cairo_show_layout

    mov rdi, [dpy]
    call XFlush

    add rsp, 8
    ret

; Click handling:
; - if y < TOPBAR_H: select tab based on x thirds
; - if y > w_height - BOTBAR_H: scroll up/down based on x half
handle_click:
    sub rsp, 8
    call update_mouse_coords

    mov eax, [mouse_y]
    cmp eax, TOPBAR_H
    jb .tab

    mov ecx, [w_height]
    sub ecx, BOTBAR_H
    cmp eax, ecx
    jae .scroll

    jmp .done

.tab:
    mov eax, [w_width]
    cdq
    mov ecx, 3
    idiv ecx
    mov ebx, eax            ; tabW

    mov eax, [mouse_x]
    cmp eax, ebx
    jb .set_netstat
    mov edx, ebx
    add edx, ebx
    cmp eax, edx
    jb .set_ps
    jmp .set_net

.set_netstat:
    mov dword [view_mode], VIEW_NETSTAT
    jmp .tab_changed
.set_ps:
    mov dword [view_mode], VIEW_PS
    jmp .tab_changed
.set_net:
    mov dword [view_mode], VIEW_NET

.tab_changed:
    mov dword [scroll_line], 0
    call fetch_view_output
    call clamp_scroll
    call draw_frame
    jmp .done

.scroll:
    mov eax, [w_width]
    shr eax, 1
    mov edx, [mouse_x]
    cmp edx, eax
    jb .scroll_up

    ; down
    mov eax, [scroll_line]
    add eax, SCROLL_STEP
    mov [scroll_line], eax
    call clamp_scroll
    call draw_frame
    jmp .done

.scroll_up:
    mov eax, [scroll_line]
    sub eax, SCROLL_STEP
    mov [scroll_line], eax
    call clamp_scroll
    call draw_frame

.done:
    add rsp, 8
    ret

main:
    sub rsp, 8

    xor rdi, rdi
    call XOpenDisplay
    test rax, rax
    jz .quit
    mov [dpy], rax

    mov rdi, [dpy]
    call XDefaultScreen
    mov [screen], eax

    mov rdi, [dpy]
    mov esi, [screen]
    call XDefaultVisual
    mov [visual], rax

    ; screen size
    mov rdi, [dpy]
    mov esi, [screen]
    call XDisplayWidth
    mov [screen_w], eax

    mov rdi, [dpy]
    mov esi, [screen]
    call XDisplayHeight
    mov [screen_h], eax

    ; panel: width=screen_w/4, height=screen_h - Y_OFFSET, x=screen_w-w, y=Y_OFFSET
    mov eax, [screen_w]
    shr eax, 2
    mov [w_width], eax

    mov eax, [screen_h]
    sub eax, Y_OFFSET
    mov [w_height], eax

    ; root
    mov rdi, [dpy]
    mov esi, [screen]
    call XRootWindow
    mov r15, rax

    ; x = screen_w - w_width
    mov eax, [screen_w]
    sub eax, [w_width]
    mov edx, eax             ; x

    mov ecx, Y_OFFSET        ; y

    mov rdi, [dpy]
    mov rsi, r15
    mov r8d, [w_width]
    mov r9d, [w_height]

    sub rsp, 32
    mov dword [rsp+0], 1
    mov qword [rsp+8],  0x202020
    mov qword [rsp+16], 0x000000
    call XCreateSimpleWindow
    add rsp, 32
    mov [win], rax

    mov rdi, [dpy]
    mov rsi, [win]
    lea rdx, [wintitle]
    call XStoreName

    call set_dock_properties

    mov rdi, [dpy]
    mov rsi, [win]
    mov edx, (ExposureMask | KeyPressMask | ButtonPressMask | StructureNotifyMask)
    call XSelectInput

    mov rdi, [dpy]
    mov rsi, [win]
    call XMapWindow

    ; grab keyboard so any key exits even if WM won’t focus docks
    mov rdi, [dpy]
    mov rsi, [win]
    mov edx, 1
    mov ecx, GrabModeAsync
    mov r8d, GrabModeAsync
    mov r9d, CurrentTime
    call XGrabKeyboard

    mov dword [view_mode], VIEW_NETSTAT
    mov dword [scroll_line], 0

    call fetch_view_output
    call clamp_scroll
    call create_cairo_objects
    call draw_frame

    lea rsi, [ts_now]
    mov edi, CLOCK_MONOTONIC
    call clock_gettime
    call set_next_plus_1s

.loop:
.evcheck:
    mov rdi, [dpy]
    call XPending
    test eax, eax
    jz .timecheck

    mov rdi, [dpy]
    lea rsi, [event]
    call XNextEvent

    mov eax, dword [event]
    cmp eax, KeyPress
    je .exit_now
    cmp eax, ButtonPress
    je .click
    cmp eax, Expose
    je .redraw
    cmp eax, ConfigureNotify
    je .redraw
    jmp .evcheck

.click:
    call handle_click
    jmp .evcheck

.redraw:
    call update_window_size
    call sync_pango_width
    call clamp_scroll
    call draw_frame
    jmp .evcheck

.timecheck:
    lea rsi, [ts_now]
    mov edi, CLOCK_MONOTONIC
    call clock_gettime

    call time_due
    test al, al
    jz .sleep

    call fetch_view_output
    call set_next_plus_1s
    call clamp_scroll
    call draw_frame

.sleep:
    mov qword [ts_sleep + 0], 0
    mov qword [ts_sleep + 8], 10000000
    lea rdi, [ts_sleep]
    xor rsi, rsi
    call nanosleep
    jmp .loop

.exit_now:
    mov rdi, [dpy]
    mov rsi, CurrentTime
    call XUngrabKeyboard

    call destroy_cairo_objects
    mov edi, 0
    call exit

.quit:
    mov edi, 1
    call exit

