; ----------------------------------
; polygon routine (c) 1994 by Sascha Springer
; ----------------------------------

    global draw_poly_hc_l, screen_low_high_work, screen_low_high_display

; ----------------------------------

SCREEN_WIDTH = 320

Halftone = $ffff8a00

Src_Xinc = $ffff8a20
Src_Yinc = $ffff8a22
Src_Addr = $ffff8a24

Endmask1 = $ffff8a28
Endmask2 = $ffff8a2a
Endmask3 = $ffff8a2c

Dst_Xinc = $ffff8a2e
Dst_Yinc = $ffff8a30
Dst_Addr = $ffff8a32

X_Count = $ffff8a36
Y_Count = $ffff8a38

HOP = $ffff8a3a

OP = $ffff8a3b

Line_Num = $ffff8a3c

Skew = $ffff8a3d

; ----------------------------------
	text
; ----------------------------------

; a0.l = screen address
; a1.l = leftright table

draw_poly_hc_l
	move.b	#%01,HOP.w				; source = halftone
	move.b	#%0011,OP.w				; destination = source
	move	#-1,Endmask1.w
	move	#-1,Endmask2.w
	move	#-1,Endmask3.w
	move	#0,Dst_Xinc.w
	move	#2,Dst_Yinc.w
	move	#1,X_Count.w

	move.l	#-1,screen_low_high_work
	clr.l	screen_low_high_work+4

	move	#SCREEN_WIDTH*2,d7		; offset to next line
	swap	d7
	move	(a1)+,d7				; # of faces
	beq		dp_hl_end

	subq	#1,d7

	move.b	#%11000000,d6			; code for blitter start
	swap	d6

	lea		Dst_Addr.w,a2
	lea		Y_Count.w,a4

	lea		Line_Num.w,a6

	exg		a0,a1					; a1 = screen address
	move.l	a1,d1

dp_hl_loop1
	clr.l	d4						; step offset
	move.l	#$8000,d5				; line width
	move	(a0)+,d6				; count
	

	lea		Halftone.w,a3
	move	(a0)+,d0				; colour

	cmp		(a3),d0
	beq		.skip_color

	move	d0,(a3)+
	move	d0,(a3)+
	move	d0,(a3)+
	move	d0,(a3)+
	move	d0,(a3)+
	move	d0,(a3)+
	move	d0,(a3)+
	move	d0,(a3)+
	move	d0,(a3)+
	move	d0,(a3)+
	move	d0,(a3)+
	move	d0,(a3)+
	move	d0,(a3)+
	move	d0,(a3)+
	move	d0,(a3)+
	move	d0,(a3)+

.skip_color
	add.l	(a0)+,a1				; offset

	cmp.l	screen_low_high_work,a1
	bcc		.skip_low

	move.l	a1,screen_low_high_work

.skip_low
	swap	d7

dp_hl_loop2
	swap	d6

	move	(a0)+,d0				; flags

	btst	#1,d0					; left flag
	beq.s	dp_hl_ok1

	move.l	(a0),d3					; left step

dp_hl_ok1
	btst	#0,d0					; right flag
	beq.s	dp_hl_ok2

	move.l	4(a0),d2				; right step

dp_hl_ok2
	tst		8(a0)					; lenght
	bne.s	dp_hl_draw

	btst	#3,d0					; left flag2
	beq.s	dp_hl_ok3

	lea		(a1,d3.w*2),a1

	swap	d3
	clr		d3
	sub.l	d3,d5

	btst	#2,d0
	bne.s	dp_hl_ok4

	bra.s	dp_hl_next

dp_hl_ok3
	btst	#2,d0					; right flag2
	beq.s	dp_hl_draw

dp_hl_ok4
	swap	d2
	clr		d2
	add.l	d2,d5

	bra.s	dp_hl_next

dp_hl_draw
	move	8(a0),d0				; lenght
	subq	#1,d0

; ----------------------------------
; go blitter go! ;-)
; ----------------------------------

dp_draw_loop
	add.l	d3,d4					; left step
	add.l	d2,d5					; line lenght = line lenght << 16 +
									; right step
	swap	d4
	swap	d5
	lea		(a1,d4.w*2),a1			; screen address += left step >> 16
	sub		d4,d5					; line lenght += left step >> 16
	ble		dp_no_draw

	move.l	a1,(a2)					; line start address
	move	d5,(a4)					; number of pixels
	move.b	d6,(a6)					; start!

dp_no_draw
	clr		d4
	swap	d4
	swap	d5
	add		d7,a1					; screen address += line lenght

	dbra	d0,dp_draw_loop

	cmp.l	screen_low_high_work+4,a1
	bcs		.skip_high

	move.l	a1,screen_low_high_work+4

.skip_high

dp_hl_next
	swap	d6
	lea		10(a0),a0

	dbra	d6,dp_hl_loop2

	swap	d7
	move.l	d1,a1

	dbra	d7,dp_hl_loop1

dp_hl_end
	rts

screen_low_high_work
	dc.l	0, 0

screen_low_high_display
	dc.l	0, 0

; ----------------------------------
;	bss
; ----------------------------------

	end
