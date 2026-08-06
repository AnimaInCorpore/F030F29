; ----------------------------------
; polygon routine (c) 1994 by Sascha Springer
; ----------------------------------

    global draw_poly_hc_l, screen_low_high_work, screen_low_high_display
    global make_test_texture, draw_quad_tex, draw_poly_tex

; ----------------------------------

SCREEN_WIDTH = 320
SCREEN_HEIGHT = 240

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

quad_angle
	dc.w	0

	even

; ----------------------------------
; Texture mapping test harness
;
; Self contained scaffolding: builds a procedural 256x256 truecolour texture
; and draws a rotating textured quad from hand computed screen space
; gradients.  Nothing here talks to the DSP.  It exists to prove out the
; index accumulator, the wrap and the cost per pixel of the inner loop before
; the geometry side grows texture support.
; ----------------------------------

; The row stride is 256 texels so that u.int is exactly one byte wide and
; v.int is exactly the byte above it - see the texel macro.
TEX_STRIDE = 256
TEX_ROWS = 256
TEX_BYTES = TEX_STRIDE*TEX_ROWS*2

; (a0,d3.w*2) sign extends d3.w, so bias the base by half the texture and let
; v >= 128 address the second half through the negative side.
TEX_BIAS = TEX_BYTES/2

; texels spanned by one quad edge; kept below the stride so the gradients stay
; inside the 8.24 v accumulator
TEX_SPAN = 128

QUAD_CX = SCREEN_WIDTH/2
QUAD_CY = SCREEN_HEIGHT/2
QUAD_R = 90						; half edge length in pixels
QUAD_KF = 256*TEX_SPAN/QUAD_R	; texels per screen pixel * 256, at 1.15 scale
QUAD_SPEED = 7					; tenths of a degree per frame

; the quad centre maps to the middle of the spanned texels
QUAD_UCENTRE = (TEX_SPAN/2)<<16
QUAD_VCENTRE = (TEX_SPAN/2)<<24

; ----------------------------------
; One pixel of the inner loop.
;
; u and v are separate accumulators and are floored separately.  A single
; accumulator holding v*STRIDE+u does NOT work: that value is linear in the
; reals, but floor(v*STRIDE+u) != floor(v)*STRIDE+floor(u), and the discarded
; fraction of v contributes up to STRIDE-1 texels of error - the sample slides
; along the row instead of staying on the texel grid.
;
; The two accumulators carry different binary points on purpose: u is 16.16 so
; u.int lands in bits 16-23, v is 8.24 so v.int lands in bits 24-31.  After one
; swap each, u.int is the low byte of d2 and v.int is the high byte of d3, so
; the texel index is a byte splice rather than a shift, an add and a mask.
; Each field wraps inside its own byte, so no masking is needed either.
; ----------------------------------

; u is swapped in place and swapped back rather than copied, so the whole
; macro needs one scratch register instead of two.  Every register it does not
; touch is one the scanline loop can keep state in across the call.

texel	macro
	move.l	d1,d2
	swap	d2						; d2.w high byte = v.int
	swap	d0						; d0.w low byte  = u.int
	move.b	d0,d2					; d2.w = (v.int<<8) | u.int
	move	(a0,d2.w*2),(a1)+
	swap	d0
	add.l	d4,d0
	add.l	d5,d1
	endm

; ----------------------------------
; Textured span - the routine this milestone exists to measure.
;
; a0.l = texture base, biased by TEX_BIAS
; a1.l = screen address of the first pixel
; d0.l = u accumulator, 16.16 texels
; d1.l = v accumulator, 8.24 texels
; d3.w = pixel count, must be > 0
; d4.l = du per pixel, 16.16
; d5.l = dv per pixel, 8.24
;
; Trashes d0-d3/a1 only, so the caller keeps its scanline state in d6, d7 and
; a2-a6 across the call.  The leading partial block is entered through a jump
; table rather than run by a second counter: that frees a register, and it also
; drops the tail loop's per-pixel branch, which matters because the faces here
; are only a handful of pixels wide.
;
; The unrolled body is 148 bytes, well inside the 030's 256 byte instruction
; cache - instruction fetch then costs nothing and the span is limited by the
; texel read and the screen write.
; ----------------------------------

draw_span_tex
	move	d3,d2
	lsr		#3,d3					; whole 8 pixel blocks
	and		#7,d2					; leading partial block
	add		d2,d2
	move	.entry(pc,d2.w),d2
	jmp		.body(pc,d2.w)

.body
	texel
.b7
	texel
.b6
	texel
.b5
	texel
.b4
	texel
.b3
	texel
.b2
	texel
.b1
	texel
.bend
	dbra	d3,.body

	rts

.entry
	dc.w	.bend-.body				; no partial block
	dc.w	.b1-.body
	dc.w	.b2-.body
	dc.w	.b3-.body
	dc.w	.b4-.body
	dc.w	.b5-.body
	dc.w	.b6-.body
	dc.w	.b7-.body

; ----------------------------------
; Textured polygon walker.
;
; Same record walk as draw_poly_hc_l, but every scanline is filled by
; draw_span_tex from the per face gradients the DSP now sends, instead of by a
; halftone blitter run.  A face the DSP could not solve arrives with zero
; gradients and therefore paints texel (0,0) flat, which makes it obvious.
;
; a0.l = screen address
; a1.l = leftright buffer
; ----------------------------------

draw_poly_tex
	movem.l	d0-d7/a0-a6,-(sp)

	move.l	#-1,screen_low_high_work
	clr.l	screen_low_high_work+4

	move	(a1)+,d0				; # of faces
	beq		dpt_end

	subq	#1,d0
	move	d0,dpt_faces

	move.l	a0,dpt_screen
	move.l	a1,a6					; record pointer
	lea		texture+TEX_BIAS,a0

dpt_face
	move	(a6)+,d0				; run count - 1
	move	d0,dpt_runs
	addq.l	#2,a6					; colour, unused while texturing
	move.l	(a6)+,d0				; offset

	move.l	dpt_screen,a2
	add.l	d0,a2

	cmpa.l	screen_low_high_work,a2
	bcc.s	.keep_low

	move.l	a2,screen_low_high_work

.keep_low
	move.l	(a6)+,a3				; u at the first pixel, 16.16
	move.l	(a6)+,d4				; dudx
	move.l	(a6)+,dpt_dudy
	move.l	(a6)+,a4				; v at the first pixel, 8.24
	move.l	(a6)+,d5				; dvdx
	move.l	(a6)+,dpt_dvdy

	moveq	#0,d6					; left edge accumulator
	move.l	#$8000,d7				; span width accumulator

	clr.l	dpt_leftstep
	clr.l	dpt_rightstep

dpt_run
	move	(a6)+,d0				; flags

	btst	#1,d0					; left step present?
	beq.s	.keep_left

	move.l	(a6),dpt_leftstep

.keep_left
	btst	#0,d0					; right step present?
	beq.s	.keep_right

	move.l	4(a6),dpt_rightstep

.keep_right
	tst		8(a6)					; lines
	bne		dpt_draw

;
; A run with no lines carries absolute horizontal jumps rather than slopes.
;
	btst	#3,d0					; left jump?
	beq.s	.no_left_jump

	move.l	dpt_leftstep,d1
	lea		(a2,d1.w*2),a2

	move	d1,d2
	ext.l	d2						; whole pixels jumped
	move.l	d4,d3
	muls.l	d2,d3
	adda.l	d3,a3					; u += dudx * pixels
	move.l	d5,d3
	muls.l	d2,d3
	adda.l	d3,a4					; v += dvdx * pixels

	move.l	dpt_leftstep,d1
	swap	d1
	clr		d1
	sub.l	d1,d7

	btst	#2,d0
	bne.s	.right_jump

	bra		dpt_next_run

.no_left_jump
	btst	#2,d0					; right jump?
	beq		dpt_draw

.right_jump
	move.l	dpt_rightstep,d1
	swap	d1
	clr		d1
	add.l	d1,d7

	bra		dpt_next_run

dpt_draw
	moveq	#0,d0					; the word move alone would leave the
	move	8(a6),d0				; high half of the offset in d0
	subq.l	#1,d0
	move.l	d0,a5					; scanline counter

;
; Fold the left edge slope into the vertical step once per run: walking down a
; line also walks the span start sideways by leftstep pixels.
;
	move.l	d4,d0
	move.l	dpt_leftstep,d1
	bsr		dpt_mulfix
	add.l	dpt_dudy,d0
	move.l	d0,dpt_duline

	move.l	d5,d0
	move.l	dpt_leftstep,d1
	bsr		dpt_mulfix
	add.l	dpt_dvdy,d0
	move.l	d0,dpt_dvline

;
; Scanline loop.  Everything that changes per line lives in a register:
; d6 left edge, d7 width, a2 line start, a3 u, a4 v, a5 lines left.  The four
; per run constants are all this reads from memory.
;
dpt_line
	add.l	dpt_leftstep,d6
	add.l	dpt_rightstep,d7

	swap	d6
	swap	d7

	lea		(a2,d6.w*2),a2			; line start follows the left edge
	sub		d6,d7					; width -= left movement
	move	d7,d3					; pixel count

	clr		d6
	swap	d6						; left edge keeps only its fraction
	swap	d7

	tst		d3
	ble.s	.no_draw

	move.l	a3,d0
	move.l	a4,d1
	move.l	a2,a1
	bsr		draw_span_tex

.no_draw
	adda.l	dpt_duline,a3
	adda.l	dpt_dvline,a4
	lea		SCREEN_WIDTH*2(a2),a2

	lea		-1(a5),a5
	cmpa.w	#-1,a5
	bne		dpt_line

dpt_next_run
	lea		10(a6),a6

	subq	#1,dpt_runs
	bpl		dpt_run

	cmpa.l	screen_low_high_work+4,a2
	bcs.s	.keep_high

	move.l	a2,screen_low_high_work+4

.keep_high
	subq	#1,dpt_faces
	bpl		dpt_face

dpt_end
	movem.l	(sp)+,d0-d7/a0-a6
	rts

; d0.l * d1.l >> 16, both signed
dpt_mulfix
	muls.l	d1,d2:d0
	move.l	d2,d3
	swap	d3
	swap	d0
	move	d0,d3
	move.l	d3,d0
	rts

; ----------------------------------
; Procedural test texture, 256x256 truecolour.
;
; Red ramps along u and green along v so a mirrored or transposed mapping is
; obvious at a glance, a white grid every 16 texels shows warping and
; stepping, and a blue block marks texel (0,0).
; ----------------------------------

make_test_texture
	lea		texture+TEX_BIAS,a0

	moveq	#0,d7					; v

.rows
	moveq	#0,d6					; u

.cols
	move	d6,d0
	lsr		#3,d0					; red = u >> 3
	lsl		#8,d0
	lsl		#3,d0
	move	d7,d1
	lsr		#2,d1					; green = v >> 2
	lsl		#5,d1
	or		d1,d0

	move	d6,d1
	and		#15,d1
	beq.s	.grid
	move	d7,d1
	and		#15,d1
	bne.s	.no_grid

.grid
	move	#-1,d0					; grid line

.no_grid
	cmp		#8,d6
	bcc.s	.no_mark
	cmp		#8,d7
	bcc.s	.no_mark

	move	#%11111,d0				; origin marker

.no_mark
	move	d0,(a0)+

	addq	#1,d6
	cmp		#TEX_STRIDE,d6
	bcs.s	.cols

	addq	#1,d7
	cmp		#TEX_ROWS,d7
	bcs.s	.rows

	rts

; ----------------------------------
; Rotating textured quad.
;
; a0.l = screen address
;
; Extends screen_low_high_work so clear_screen4 repairs the area next frame,
; so this must run after draw_poly_hc_l, which resets that range.
;
; The quad is a square of half edge QUAD_R rotated by quad_angle, so its
; screen space gradients are analytic - no 2x2 solve needed here.  With
;   ex = R*( cos, sin)   ey = R*(-sin, cos)
; the inverse map gives, in texels per screen pixel,
;   du/dx =  (TEX_SPAN/2)*cos/R    du/dy = (TEX_SPAN/2)*sin/R
;   dv/dx = -(TEX_SPAN/2)*sin/R   dv/dy = (TEX_SPAN/2)*cos/R
; These are the same four quantities the DSP will compute per face from three
; projected vertices once the geometry side carries UVs.
; ----------------------------------

draw_quad_tex
	movem.l	d0-d7/a0-a6,-(sp)
	move.l	a0,a6					; screen base

	move	quad_angle,d0
	add		#QUAD_SPEED,d0
	cmp		#3600,d0
	blo.s	.angle_ok
	sub		#3600,d0

.angle_ok
	move	d0,quad_angle

	lea		sincos,a1
	lea		90*10*4(a1),a2
	move	1(a1,d0.w*4),d6			; sin, signed 1.15
	move	1(a2,d0.w*4),d7			; cos, signed 1.15
	move	d6,quad_sin
	move	d7,quad_cos

; --- edge vectors: x stays 16.16, y snaps to whole scanlines ---------------

	move	#QUAD_R,d0
	muls	d7,d0
	add.l	d0,d0
	move.l	d0,quad_ex				; ex.x
	swap	d0
	ext.l	d0
	move.l	d0,quad_ey+4			; ey.y = ex.x >> 16

	move	#QUAD_R,d0
	muls	d6,d0
	add.l	d0,d0
	move.l	d0,d1
	swap	d1
	ext.l	d1
	move.l	d1,quad_ex+4			; ex.y
	neg.l	d0
	move.l	d0,quad_ey				; ey.x

; --- screen space gradients ------------------------------------------------
;
; cos and sin are signed 1.15, so a texels-per-pixel value in 16.16 is just
; TEX_SPAN*cos/R.  QUAD_KF folds TEX_SPAN/R and 256, so a 16x16 muls
; followed by >>8 lands on 16.16 directly.

	move	quad_cos,d0
	muls	#QUAD_KF,d0
	asr.l	#8,d0
	move.l	d0,quad_dudx			; 16.16
	lsl.l	#8,d0
	move.l	d0,quad_dvdy			; 8.24

	move	quad_sin,d0
	muls	#QUAD_KF,d0
	asr.l	#8,d0
	move.l	d0,quad_dudy			; 16.16
	lsl.l	#8,d0
	neg.l	d0
	move.l	d0,quad_dvdx			; 8.24

; --- corners ---------------------------------------------------------------

	lea		quad_pts,a3
	move.l	#QUAD_CX<<16,d0
	move.l	#QUAD_CY,d1
	move.l	quad_ex,d2
	move.l	quad_ex+4,d3
	move.l	quad_ey,d4
	move.l	quad_ey+4,d5

	move.l	d0,d6					; centre - ex - ey
	sub.l	d2,d6
	sub.l	d4,d6
	move.l	d6,(a3)+
	move.l	d1,d6
	sub.l	d3,d6
	sub.l	d5,d6
	move.l	d6,(a3)+

	move.l	d0,d6					; centre + ex - ey
	add.l	d2,d6
	sub.l	d4,d6
	move.l	d6,(a3)+
	move.l	d1,d6
	add.l	d3,d6
	sub.l	d5,d6
	move.l	d6,(a3)+

	move.l	d0,d6					; centre + ex + ey
	add.l	d2,d6
	add.l	d4,d6
	move.l	d6,(a3)+
	move.l	d1,d6
	add.l	d3,d6
	add.l	d5,d6
	move.l	d6,(a3)+

	move.l	d0,d6					; centre - ex + ey
	sub.l	d2,d6
	add.l	d4,d6
	move.l	d6,(a3)+
	move.l	d1,d6
	sub.l	d3,d6
	add.l	d5,d6
	move.l	d6,(a3)+

; --- vertical extent, clamped to the screen --------------------------------

	lea		quad_pts,a3
	move.l	4(a3),d0				; ymin
	move.l	d0,d1					; ymax
	lea		8(a3),a4
	moveq	#3-1,d7

.extent
	move.l	4(a4),d2
	cmp.l	d0,d2
	bge.s	.not_lower
	move.l	d2,d0

.not_lower
	cmp.l	d1,d2
	ble.s	.not_higher
	move.l	d2,d1

.not_higher
	lea		8(a4),a4
	dbra	d7,.extent

	tst.l	d0
	bpl.s	.ymin_ok
	moveq	#0,d0

.ymin_ok
	cmp.l	#SCREEN_HEIGHT,d1
	blt.s	.ymax_ok
	move.l	#SCREEN_HEIGHT-1,d1

.ymax_ok
	cmp.l	d1,d0
	bgt		.quad_done				; entirely off screen

	move.l	d0,quad_ymin
	move.l	d1,quad_ymax

; --- reset the span table over the visible range ---------------------------

	move.l	d1,d2
	sub.l	d0,d2					; scanline count - 1
	move	d0,d3
	add		d3,d3
	lea		qt_xl,a4
	lea		0(a4,d3.w),a4
	lea		qt_xr,a5
	lea		0(a5,d3.w),a5

.clear_spans
	move	#$7fff,(a4)+
	move	#$8000,(a5)+
	dbra	d2,.clear_spans

; --- walk the four edges into the span table -------------------------------
;
; Taking the min and max x per scanline over all four edges gives the span
; directly and needs no vertex ordering, no top vertex search and no chain
; refill - worth the second pass in scaffolding.

	lea		quad_pts,a3
	moveq	#0,d6					; vertex index
	moveq	#4-1,d7

.edges
	move	d6,d0
	lsl		#3,d0
	move	d6,d1
	addq	#1,d1
	and		#3,d1
	lsl		#3,d1

	move.l	0(a3,d0.w),d2			; x0, 16.16
	move.l	4(a3,d0.w),d3			; y0
	move.l	0(a3,d1.w),d4			; x1
	move.l	4(a3,d1.w),d5			; y1

	cmp.l	d3,d5
	beq		.next_edge				; horizontal, contributes nothing
	bgt.s	.downwards

	exg		d2,d4					; make the edge run downwards
	exg		d3,d5

.downwards
	move.l	d5,d0
	sub.l	d3,d0					; dy > 0
	move.l	d4,d1
	sub.l	d2,d1					; dx, 16.16
	divs.l	d0,d1					; step, 16.16

	lea		qt_xl,a4
	lea		qt_xr,a5

.edge_loop
	tst.l	d3
	bmi.s	.edge_next_line
	cmp.l	#SCREEN_HEIGHT,d3
	bge.s	.next_edge				; below the screen, and so is the rest

	move.l	d2,d4
	swap	d4
	ext.l	d4						; x as a whole pixel
	move.l	d3,d5
	add.l	d5,d5

	cmp		0(a4,d5.l),d4
	bge.s	.not_left
	move	d4,0(a4,d5.l)

.not_left
	cmp		0(a5,d5.l),d4
	ble.s	.not_right
	move	d4,0(a5,d5.l)

.not_right
.edge_next_line
	add.l	d1,d2
	addq.l	#1,d3
	subq.l	#1,d0
	bgt.s	.edge_loop

.next_edge
	addq	#1,d6
	dbra	d7,.edges

; --- fill --------------------------------------------------------------

	move.l	quad_ymin,d3
	move.l	quad_ymax,d2
	sub.l	d3,d2					; scanline count - 1

	move.l	d3,d4					; u/v at the centre column of ymin
	sub.l	#QUAD_CY,d4

	move.l	d4,d0
	muls.l	quad_dudy,d0
	add.l	#QUAD_UCENTRE,d0
	move.l	d0,quad_uline

	move.l	d4,d0
	muls.l	quad_dvdy,d0
	add.l	#QUAD_VCENTRE,d0
	move.l	d0,quad_vline

	move.l	d3,d4
	add.l	d4,d4
	lea		qt_xl,a4
	lea		0(a4,d4.l),a4
	lea		qt_xr,a5
	lea		0(a5,d4.l),a5

	move.l	d3,d4
	mulu	#SCREEN_WIDTH*2,d4
	lea		0(a6,d4.l),a2			; start of the scanline

.fill_loop
	move	(a4)+,d5
	move	(a5)+,d6
	ext.l	d5						; left x
	ext.l	d6						; right x
	cmp.l	d5,d6
	blt.s	.fill_next

	tst.l	d5
	bpl.s	.xl_ok
	moveq	#0,d5

.xl_ok
	cmp.l	#SCREEN_WIDTH,d6
	blt.s	.xr_ok
	move.l	#SCREEN_WIDTH-1,d6

.xr_ok
	cmp.l	d5,d6
	blt.s	.fill_next

	move.l	d5,d3					; u/v at the first pixel drawn
	sub.l	#QUAD_CX,d3

	move.l	d3,d0
	muls.l	quad_dudx,d0
	add.l	quad_uline,d0

	move.l	d3,d1
	muls.l	quad_dvdx,d1
	add.l	quad_vline,d1

	move.l	d6,d3
	sub.l	d5,d3
	addq	#1,d3					; inclusive pixel count

	move.l	d5,d4
	add.l	d4,d4
	lea		0(a2,d4.l),a1
	lea		texture+TEX_BIAS,a0

	move.l	quad_dudx,d4
	move.l	quad_dvdx,d5
	move	d3,d6

	movem.l	d2/a2/a4/a5,-(sp)
	bsr		draw_span_tex
	movem.l	(sp)+,d2/a2/a4/a5

.fill_next
	move.l	quad_uline,d0
	add.l	quad_dudy,d0
	move.l	d0,quad_uline

	move.l	quad_vline,d0
	add.l	quad_dvdy,d0
	move.l	d0,quad_vline

	lea		SCREEN_WIDTH*2(a2),a2

	dbra	d2,.fill_loop

; --- hand the touched band to clear_screen4 --------------------------------

	move.l	quad_ymin,d0
	mulu	#SCREEN_WIDTH*2,d0
	add.l	a6,d0
	cmp.l	screen_low_high_work,d0
	bcc.s	.keep_low
	move.l	d0,screen_low_high_work

.keep_low
	move.l	quad_ymax,d0
	addq.l	#1,d0
	mulu	#SCREEN_WIDTH*2,d0
	add.l	a6,d0
	cmp.l	screen_low_high_work+4,d0
	bcs.s	.keep_high
	move.l	d0,screen_low_high_work+4

.keep_high
.quad_done
	movem.l	(sp)+,d0-d7/a0-a6
	rts

; ----------------------------------
	bss
; ----------------------------------

	even

texture
	ds.w	TEX_STRIDE*TEX_ROWS

qt_xl
	ds.w	SCREEN_HEIGHT
qt_xr
	ds.w	SCREEN_HEIGHT

quad_sin
	ds.w	1
quad_cos
	ds.w	1

quad_ex
	ds.l	2						; x 16.16, y whole scanlines
quad_ey
	ds.l	2
quad_pts
	ds.l	4*2

quad_dudx
	ds.l	1
quad_dudy
	ds.l	1
quad_dvdx
	ds.l	1
quad_dvdy
	ds.l	1
quad_uline
	ds.l	1
quad_vline
	ds.l	1
quad_ymin
	ds.l	1
quad_ymax
	ds.l	1

dpt_faces
	ds.w	1
dpt_runs
	ds.w	1
dpt_screen
	ds.l	1
dpt_leftstep
	ds.l	1
dpt_rightstep
	ds.l	1
dpt_dudy
	ds.l	1
dpt_dvdy
	ds.l	1
dpt_duline
	ds.l	1
dpt_dvline
	ds.l	1

	end
