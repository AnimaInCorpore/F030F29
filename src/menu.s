; -----------------------------------------------------------------------------
; start menu: title, START / EXIT, arrow-key navigation
; -----------------------------------------------------------------------------
;
; Shown before the game loop proper runs. Own 5x7 bitmap font (original
; design, not derived from the game - see tools/gen_menu_font.py), drawn at
; 2x pixel scale so it reads clearly at 320x240, unlike the existing 4x5
; debug font in f29.s which is sized for a dense numeric readout, not menu
; text. Background is a flat fill via the same blitter halftone trick
; draw_horizon uses, just one colour and no per-line runs.
;
; Navigation is edge-detected against key_value's low byte: that field is a
; raw IKBD scancode latch with no debounce of its own (src/keyboard.s), so
; every frame the current byte is compared against what it was last frame,
; and the menu only reacts on a change. Confirm uses Return, not Space -
; f29.s's main loop already treats Space as "quit the whole program" on the
; very next frame (unconditionally, not edge-detected), which would collide
; with using it as the menu's own confirm key.
; -----------------------------------------------------------------------------
	global	menu_init, menu_update, menu_draw
	global	menu_active, menu_quit

SCREEN_WIDTH = 320
SCREEN_HEIGHT = 240

Halftone = $ffff8a00

Dst_Xinc = $ffff8a2e
Dst_Yinc = $ffff8a30
Dst_Addr = $ffff8a32

Endmask1 = $ffff8a28
Endmask2 = $ffff8a2a
Endmask3 = $ffff8a2c

X_Count = $ffff8a36
Y_Count = $ffff8a38

HOP = $ffff8a3a
OP = $ffff8a3b

Line_Num = $ffff8a3c

KEY_ARROW_U = 72
KEY_ARROW_D = 80
KEY_RETURN = 28

MENU_ITEM_COUNT = 2

; Glyph cell: 5x7 font pixels at 2x2 screen pixels each = 10x14, plus a 2px
; gap between columns. X positions and the pitch are all byte offsets (screen
; pixels * 2, same convention as HUD_AIRSPEED_X etc. in hud.s), since they get
; added straight into an address; Y positions stay plain pixel rows, scaled
; by SCREEN_WIDTH*2 at the point of use.
MENU_CHAR_PITCH = 12*2

MENU_TITLE_X = 143*2
MENU_TITLE_Y = 40
MENU_START_X = 150*2
MENU_START_Y = 120
MENU_EXIT_X = 150*2
MENU_EXIT_Y = 150
MENU_CURSOR_X = 130*2

MENU_BG_COLOUR = ((31*1/10)<<11)+((63*1/10)<<5)+(31*3/10)
MENU_BG_FILL = (MENU_BG_COLOUR<<16)+MENU_BG_COLOUR
MENU_HALF_SCREEN = SCREEN_WIDTH*SCREEN_HEIGHT/2

; -----------------------------------------------------------------------------
	text
; -----------------------------------------------------------------------------

menu_init
	clr		menu_selection
	move.b	key_value,menu_prev_key
	move.b	#-1,menu_active
	clr.b	menu_quit
	rts

; -----------------------------------------------------------------------------
; Reads key_value once, acts only if it differs from last frame's.
; -----------------------------------------------------------------------------

menu_update
	move.b	key_value,d0
	cmp.b	menu_prev_key,d0
	beq		.mu_done

	cmp.b	#KEY_ARROW_U,d0
	bne.s	.mu_not_up
	moveq	#0,d1
	move	menu_selection,d1
	subq	#1,d1
	bpl.s	.mu_up_ok
	moveq	#MENU_ITEM_COUNT-1,d1
.mu_up_ok
	move	d1,menu_selection
	bra		.mu_done

.mu_not_up
	cmp.b	#KEY_ARROW_D,d0
	bne.s	.mu_not_down
	moveq	#0,d1
	move	menu_selection,d1
	addq	#1,d1
	cmp		#MENU_ITEM_COUNT,d1
	blt.s	.mu_down_ok
	moveq	#0,d1
.mu_down_ok
	move	d1,menu_selection
	bra		.mu_done

.mu_not_down
	cmp.b	#KEY_RETURN,d0
	bne.s	.mu_done

	tst		menu_selection
	bne.s	.mu_confirm_exit
	clr.b	menu_active				; START - dismiss, let the game run
	bra.s	.mu_done
.mu_confirm_exit
	move.b	#-1,menu_quit				; EXIT - f29.s ends the program

.mu_done
	move.b	d0,menu_prev_key
	rts

; -----------------------------------------------------------------------------
; a0.l = screen address (work_screen)
; -----------------------------------------------------------------------------

menu_draw
	move.l	a0,a2
	bsr		menu_clear

	move.l	a2,a0
	lea		MENU_TITLE_X+MENU_TITLE_Y*SCREEN_WIDTH*2(a0),a0
	lea		menu_title_text,a1
	bsr		draw_text

	move.l	a2,a0
	lea		MENU_START_X+MENU_START_Y*SCREEN_WIDTH*2(a0),a0
	lea		menu_start_text,a1
	bsr		draw_text

	move.l	a2,a0
	lea		MENU_EXIT_X+MENU_EXIT_Y*SCREEN_WIDTH*2(a0),a0
	lea		menu_exit_text,a1
	bsr		draw_text

	move.l	a2,a0
	tst		menu_selection
	bne.s	.md_cursor_exit
	lea		MENU_CURSOR_X+MENU_START_Y*SCREEN_WIDTH*2(a0),a0
	bra.s	.md_cursor_draw
.md_cursor_exit
	lea		MENU_CURSOR_X+MENU_EXIT_Y*SCREEN_WIDTH*2(a0),a0
.md_cursor_draw
	moveq	#1,d0						; the cursor glyph, not a letter
	bsr		draw_char

	rts

; -----------------------------------------------------------------------------
; Fills work_screen with a flat colour, the same halftone-fill blitter trick
; draw_horizon uses. Two runs because Y_Count is 16 bit and one run of the
; whole 320x240 screen does not fit.
;
; a0.l = screen address
; trashes d1/d6/a1,a3,a4,a5,a6 - a2 deliberately left alone, menu_draw keeps
; the screen base there across this call and the draw_text calls after it
; -----------------------------------------------------------------------------

menu_clear
	move.b	#%01,HOP.w
	move.b	#%0011,OP.w
	move	#-1,Endmask1.w
	move	#-1,Endmask2.w
	move	#-1,Endmask3.w
	move	#0,Dst_Xinc.w
	move	#2,Dst_Yinc.w
	move	#1,X_Count.w

	lea		Halftone.w,a3
	move.l	#MENU_BG_FILL,d1

	rept 8
	move.l	d1,(a3)+
	endr
	lea		-32(a3),a3

	lea		Dst_Addr.w,a5
	lea		Y_Count.w,a4
	lea		Line_Num.w,a6
	move.b	#%11000000,d6

	move.l	a0,(a5)
	move	#MENU_HALF_SCREEN,(a4)
	move.b	d6,(a6)

	add.l	#MENU_HALF_SCREEN*2,a0
	move.l	a0,(a5)
	move	#MENU_HALF_SCREEN,(a4)
	move.b	d6,(a6)

	rts

; -----------------------------------------------------------------------------
; a0.l = screen dest, top-left pixel of the first glyph cell (consumed)
; a1.l = zero-terminated ASCII string
; -----------------------------------------------------------------------------

draw_text
.dt_loop
	move.b	(a1)+,d0
	beq.s	.dt_done
	bsr		draw_char
	lea		MENU_CHAR_PITCH(a0),a0
	bra.s	.dt_loop
.dt_done
	rts

; -----------------------------------------------------------------------------
; Draws one glyph at 2x2 pixel scale. Character index is computed with
; arithmetic (space=0, '0'-'9'=1..10, 'A'-'Z'=11..36) rather than a second
; lookup table - anything outside those ranges other than the cursor byte
; falls back to a blank cell.
;
; a0.l = screen dest, top-left pixel of this glyph cell (preserved)
; d0.b = ASCII character, or 1 for the cursor glyph
; trashes d0-d4/a3,a4,a6 - a1 deliberately left alone since draw_text keeps
; the string pointer there across this call, likewise a2 for menu_draw's
; screen base across several draw_text/draw_char calls in a row
; -----------------------------------------------------------------------------

draw_char
	move.b	d0,d1
	moveq	#0,d2
	cmp.b	#1,d1
	bne.s	.dc_not_cursor
	moveq	#37,d2
	bra		.dc_index_ready

.dc_not_cursor
	cmp.b	#'0',d1
	blt.s	.dc_index_ready			; below '0', incl. space -> blank
	cmp.b	#'9',d1
	bgt.s	.dc_try_letter
	move.b	d1,d2
	sub.b	#'0',d2
	addq	#1,d2
	bra.s	.dc_index_ready

.dc_try_letter
	cmp.b	#'A',d1
	blt.s	.dc_index_ready			; punctuation between '9' and 'A' -> blank
	cmp.b	#'Z',d1
	bgt.s	.dc_index_ready			; past 'Z' -> blank
	move.b	d1,d2
	sub.b	#'A',d2
	add.b	#11,d2

.dc_index_ready
	and.l	#$ff,d2
	lea		menu_chars,a6
	move.l	(a6,d2.w*4),a6

	move.l	a0,a3
	moveq	#7-1,d3
.dc_row
	move.l	a3,a4
	moveq	#5-1,d4
.dc_col
	move	(a6)+,d0
	move	d0,(a4)
	move	d0,2(a4)
	move	d0,SCREEN_WIDTH*2(a4)
	move	d0,SCREEN_WIDTH*2+2(a4)
	addq	#4,a4
	dbra	d4,.dc_col
	lea		2*SCREEN_WIDTH*2(a3),a3
	dbra	d3,.dc_row

	rts

; -----------------------------------------------------------------------------
	data
; -----------------------------------------------------------------------------

menu_title_text
	dc.b	'F29',0
menu_start_text
	dc.b	'START',0
menu_exit_text
	dc.b	'EXIT',0
	even

; 5x7 bitmap font, one word per pixel (0 = off, -1 = on) - see
; tools/gen_menu_font.py. Fixed order: space, '0'-'9', 'A'-'Z', cursor block;
; draw_char's index arithmetic depends on this exact order.

menu_chars
	dc.l	mchar_space
	dc.l	mchar_0
	dc.l	mchar_1
	dc.l	mchar_2
	dc.l	mchar_3
	dc.l	mchar_4
	dc.l	mchar_5
	dc.l	mchar_6
	dc.l	mchar_7
	dc.l	mchar_8
	dc.l	mchar_9
	dc.l	mchar_A
	dc.l	mchar_B
	dc.l	mchar_C
	dc.l	mchar_D
	dc.l	mchar_E
	dc.l	mchar_F
	dc.l	mchar_G
	dc.l	mchar_H
	dc.l	mchar_I
	dc.l	mchar_J
	dc.l	mchar_K
	dc.l	mchar_L
	dc.l	mchar_M
	dc.l	mchar_N
	dc.l	mchar_O
	dc.l	mchar_P
	dc.l	mchar_Q
	dc.l	mchar_R
	dc.l	mchar_S
	dc.l	mchar_T
	dc.l	mchar_U
	dc.l	mchar_V
	dc.l	mchar_W
	dc.l	mchar_X
	dc.l	mchar_Y
	dc.l	mchar_Z
	dc.l	mchar_cursor

mchar_space			; index 0
	dc.w	0, 0, 0, 0, 0
	dc.w	0, 0, 0, 0, 0
	dc.w	0, 0, 0, 0, 0
	dc.w	0, 0, 0, 0, 0
	dc.w	0, 0, 0, 0, 0
	dc.w	0, 0, 0, 0, 0
	dc.w	0, 0, 0, 0, 0
mchar_0			; index 1
	dc.w	0, -1, -1, -1, 0
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, 0, -1, -1
	dc.w	-1, 0, -1, 0, -1
	dc.w	-1, -1, 0, 0, -1
	dc.w	-1, 0, 0, 0, -1
	dc.w	0, -1, -1, -1, 0
mchar_1			; index 2
	dc.w	0, 0, -1, 0, 0
	dc.w	0, -1, -1, 0, 0
	dc.w	0, 0, -1, 0, 0
	dc.w	0, 0, -1, 0, 0
	dc.w	0, 0, -1, 0, 0
	dc.w	0, 0, -1, 0, 0
	dc.w	0, -1, -1, -1, 0
mchar_2			; index 3
	dc.w	0, -1, -1, -1, 0
	dc.w	-1, 0, 0, 0, -1
	dc.w	0, 0, 0, 0, -1
	dc.w	0, 0, 0, -1, 0
	dc.w	0, 0, -1, 0, 0
	dc.w	0, -1, 0, 0, 0
	dc.w	-1, -1, -1, -1, -1
mchar_3			; index 4
	dc.w	0, -1, -1, -1, 0
	dc.w	-1, 0, 0, 0, -1
	dc.w	0, 0, 0, 0, -1
	dc.w	0, 0, -1, -1, 0
	dc.w	0, 0, 0, 0, -1
	dc.w	-1, 0, 0, 0, -1
	dc.w	0, -1, -1, -1, 0
mchar_4			; index 5
	dc.w	0, 0, 0, -1, 0
	dc.w	0, 0, -1, -1, 0
	dc.w	0, -1, 0, -1, 0
	dc.w	-1, 0, 0, -1, 0
	dc.w	-1, -1, -1, -1, -1
	dc.w	0, 0, 0, -1, 0
	dc.w	0, 0, 0, -1, 0
mchar_5			; index 6
	dc.w	-1, -1, -1, -1, -1
	dc.w	-1, 0, 0, 0, 0
	dc.w	-1, -1, -1, -1, 0
	dc.w	0, 0, 0, 0, -1
	dc.w	0, 0, 0, 0, -1
	dc.w	-1, 0, 0, 0, -1
	dc.w	0, -1, -1, -1, 0
mchar_6			; index 7
	dc.w	0, 0, -1, -1, 0
	dc.w	0, -1, 0, 0, 0
	dc.w	-1, 0, 0, 0, 0
	dc.w	-1, -1, -1, -1, 0
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, 0, 0, -1
	dc.w	0, -1, -1, -1, 0
mchar_7			; index 8
	dc.w	-1, -1, -1, -1, -1
	dc.w	0, 0, 0, 0, -1
	dc.w	0, 0, 0, -1, 0
	dc.w	0, 0, -1, 0, 0
	dc.w	0, -1, 0, 0, 0
	dc.w	0, -1, 0, 0, 0
	dc.w	0, -1, 0, 0, 0
mchar_8			; index 9
	dc.w	0, -1, -1, -1, 0
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, 0, 0, -1
	dc.w	0, -1, -1, -1, 0
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, 0, 0, -1
	dc.w	0, -1, -1, -1, 0
mchar_9			; index 10
	dc.w	0, -1, -1, -1, 0
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, 0, 0, -1
	dc.w	0, -1, -1, -1, -1
	dc.w	0, 0, 0, 0, -1
	dc.w	0, 0, 0, -1, 0
	dc.w	0, -1, -1, 0, 0
mchar_A			; index 11
	dc.w	0, -1, -1, -1, 0
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, -1, -1, -1, -1
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, 0, 0, -1
mchar_B			; index 12
	dc.w	-1, -1, -1, -1, 0
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, -1, -1, -1, 0
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, -1, -1, -1, 0
mchar_C			; index 13
	dc.w	0, -1, -1, -1, -1
	dc.w	-1, 0, 0, 0, 0
	dc.w	-1, 0, 0, 0, 0
	dc.w	-1, 0, 0, 0, 0
	dc.w	-1, 0, 0, 0, 0
	dc.w	-1, 0, 0, 0, 0
	dc.w	0, -1, -1, -1, -1
mchar_D			; index 14
	dc.w	-1, -1, -1, -1, 0
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, -1, -1, -1, 0
mchar_E			; index 15
	dc.w	-1, -1, -1, -1, -1
	dc.w	-1, 0, 0, 0, 0
	dc.w	-1, 0, 0, 0, 0
	dc.w	-1, -1, -1, -1, 0
	dc.w	-1, 0, 0, 0, 0
	dc.w	-1, 0, 0, 0, 0
	dc.w	-1, -1, -1, -1, -1
mchar_F			; index 16
	dc.w	-1, -1, -1, -1, -1
	dc.w	-1, 0, 0, 0, 0
	dc.w	-1, 0, 0, 0, 0
	dc.w	-1, -1, -1, -1, 0
	dc.w	-1, 0, 0, 0, 0
	dc.w	-1, 0, 0, 0, 0
	dc.w	-1, 0, 0, 0, 0
mchar_G			; index 17
	dc.w	0, -1, -1, -1, -1
	dc.w	-1, 0, 0, 0, 0
	dc.w	-1, 0, 0, 0, 0
	dc.w	-1, 0, -1, -1, -1
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, 0, 0, -1
	dc.w	0, -1, -1, -1, -1
mchar_H			; index 18
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, -1, -1, -1, -1
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, 0, 0, -1
mchar_I			; index 19
	dc.w	-1, -1, -1, -1, -1
	dc.w	0, 0, -1, 0, 0
	dc.w	0, 0, -1, 0, 0
	dc.w	0, 0, -1, 0, 0
	dc.w	0, 0, -1, 0, 0
	dc.w	0, 0, -1, 0, 0
	dc.w	-1, -1, -1, -1, -1
mchar_J			; index 20
	dc.w	0, 0, -1, -1, -1
	dc.w	0, 0, 0, -1, 0
	dc.w	0, 0, 0, -1, 0
	dc.w	0, 0, 0, -1, 0
	dc.w	0, 0, 0, -1, 0
	dc.w	-1, 0, 0, -1, 0
	dc.w	0, -1, -1, 0, 0
mchar_K			; index 21
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, 0, -1, 0
	dc.w	-1, 0, -1, 0, 0
	dc.w	-1, -1, 0, 0, 0
	dc.w	-1, 0, -1, 0, 0
	dc.w	-1, 0, 0, -1, 0
	dc.w	-1, 0, 0, 0, -1
mchar_L			; index 22
	dc.w	-1, 0, 0, 0, 0
	dc.w	-1, 0, 0, 0, 0
	dc.w	-1, 0, 0, 0, 0
	dc.w	-1, 0, 0, 0, 0
	dc.w	-1, 0, 0, 0, 0
	dc.w	-1, 0, 0, 0, 0
	dc.w	-1, -1, -1, -1, -1
mchar_M			; index 23
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, -1, 0, -1, -1
	dc.w	-1, 0, -1, 0, -1
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, 0, 0, -1
mchar_N			; index 24
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, -1, 0, 0, -1
	dc.w	-1, 0, -1, 0, -1
	dc.w	-1, 0, 0, -1, -1
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, 0, 0, -1
mchar_O			; index 25
	dc.w	0, -1, -1, -1, 0
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, 0, 0, -1
	dc.w	0, -1, -1, -1, 0
mchar_P			; index 26
	dc.w	-1, -1, -1, -1, 0
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, -1, -1, -1, 0
	dc.w	-1, 0, 0, 0, 0
	dc.w	-1, 0, 0, 0, 0
	dc.w	-1, 0, 0, 0, 0
mchar_Q			; index 27
	dc.w	0, -1, -1, -1, 0
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, -1, 0, -1
	dc.w	-1, 0, 0, -1, 0
	dc.w	0, -1, -1, 0, -1
mchar_R			; index 28
	dc.w	-1, -1, -1, -1, 0
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, -1, -1, -1, 0
	dc.w	-1, 0, -1, 0, 0
	dc.w	-1, 0, 0, -1, 0
	dc.w	-1, 0, 0, 0, -1
mchar_S			; index 29
	dc.w	0, -1, -1, -1, -1
	dc.w	-1, 0, 0, 0, 0
	dc.w	-1, 0, 0, 0, 0
	dc.w	0, -1, -1, -1, 0
	dc.w	0, 0, 0, 0, -1
	dc.w	0, 0, 0, 0, -1
	dc.w	-1, -1, -1, -1, 0
mchar_T			; index 30
	dc.w	-1, -1, -1, -1, -1
	dc.w	0, 0, -1, 0, 0
	dc.w	0, 0, -1, 0, 0
	dc.w	0, 0, -1, 0, 0
	dc.w	0, 0, -1, 0, 0
	dc.w	0, 0, -1, 0, 0
	dc.w	0, 0, -1, 0, 0
mchar_U			; index 31
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, 0, 0, -1
	dc.w	0, -1, -1, -1, 0
mchar_V			; index 32
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, 0, 0, -1
	dc.w	0, -1, 0, -1, 0
	dc.w	0, 0, -1, 0, 0
mchar_W			; index 33
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, -1, 0, -1
	dc.w	-1, 0, -1, 0, -1
	dc.w	-1, -1, 0, -1, -1
	dc.w	-1, 0, 0, 0, -1
mchar_X			; index 34
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, 0, 0, -1
	dc.w	0, -1, 0, -1, 0
	dc.w	0, 0, -1, 0, 0
	dc.w	0, -1, 0, -1, 0
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, 0, 0, -1
mchar_Y			; index 35
	dc.w	-1, 0, 0, 0, -1
	dc.w	-1, 0, 0, 0, -1
	dc.w	0, -1, 0, -1, 0
	dc.w	0, 0, -1, 0, 0
	dc.w	0, 0, -1, 0, 0
	dc.w	0, 0, -1, 0, 0
	dc.w	0, 0, -1, 0, 0
mchar_Z			; index 36
	dc.w	-1, -1, -1, -1, -1
	dc.w	0, 0, 0, 0, -1
	dc.w	0, 0, 0, -1, 0
	dc.w	0, 0, -1, 0, 0
	dc.w	0, -1, 0, 0, 0
	dc.w	-1, 0, 0, 0, 0
	dc.w	-1, -1, -1, -1, -1
mchar_cursor			; index 37
	dc.w	-1, -1, -1, -1, -1
	dc.w	-1, -1, -1, -1, -1
	dc.w	-1, -1, -1, -1, -1
	dc.w	-1, -1, -1, -1, -1
	dc.w	-1, -1, -1, -1, -1
	dc.w	-1, -1, -1, -1, -1
	dc.w	-1, -1, -1, -1, -1

; -----------------------------------------------------------------------------
	bss
; -----------------------------------------------------------------------------

menu_selection
	ds.w	1
menu_prev_key
	ds.b	1
menu_active
	ds.b	1
menu_quit
	ds.b	1
	even

	end
