; -----------------------------------------------------------------------------
; main routine (c) 1994 by Sascha Springer
; -----------------------------------------------------------------------------

; -----------------------------------------------------------------------------
; exports
; -----------------------------------------------------------------------------
	global main, cam_view, object

; -----------------------------------------------------------------------------
	include "inc/colours.s"
; -----------------------------------------------------------------------------

SCREEN_WIDTH = 320
SCREEN_HEIGHT = 240
HORIZON_LINE = 120

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

KEY_ESC = 1
KEY_SHIFT_L = 42
KEY_SHIFT_R = 54
KEY_SPACE = 57
KEY_ARROW_U = 72
KEY_ARROW_L = 75
KEY_ARROW_R = 77
KEY_ARROW_D = 80

MOUSE_FLAG_FROM_X = -4
MOUSE_ROT_SHIFT = 1
MOUSE_MOVE_SHIFT = 3

; -----------------------------------------------------------------------------
	text
; -----------------------------------------------------------------------------

main
	move.b	#%01,HOP.w				; source = halftone
	move.b	#%0011,OP.w				; destination = source
	move	#-1,Endmask1.w
	move	#-1,Endmask2.w
	move	#-1,Endmask3.w
	move	#2,Dst_Xinc.w
	move	#2,Dst_Yinc.w
	clr		Src_Xinc.w
	clr		Src_Yinc.w

; -----------------------------------------------------------------------------

; Build the sky and ground backdrop procedurally.  The demo this engine came
; from loaded a TGA here; a flight simulator wants a horizon instead, and
; generating it costs nothing at runtime and no space in the binary.
;
; Pixels are RGB565: red in bits 15..11, green 10..5, blue 4..0.  The sky runs
; from a deep blue at the top to a pale haze at the horizon, the ground from a
; light dusty tone at the horizon down to darker terrain.

	lea		background,a1

	move	#HORIZON_LINE-1,d7			; sky
	moveq	#0,d6						; line counter

.sky_loop
; Darker overhead, hazier towards the horizon.  Red climbs 2..26, green 16..52
; and blue 12..30 as t runs 0..24.
;
; `ror.w #5` is how the five red bits reach 15..11: the shift instructions only
; take an immediate of 1..8, so a literal `lsl #11` will not assemble.  Rotating
; right by five puts bits 4..0 where they belong, and it is exact because the
; rest of the word is zero.
	move	d6,d0
	mulu	#24,d0
	divu	#HORIZON_LINE,d0			; quotient 0..24 in the low word
	move	d0,d1

	move	d1,d2						; red = 2 + t
	add		#2,d2
	ror		#5,d2						; -> bits 15..11

	move	d1,d3						; green = (8 + t*3/4) * 2, six bits
	mulu	#3,d3
	lsr		#2,d3
	add		#8,d3
	add		d3,d3
	lsl		#5,d3						; -> bits 10..5
	or		d3,d2

	move	d1,d3						; blue = 12 + t*3/4
	mulu	#3,d3
	lsr		#2,d3
	add		#12,d3
	or		d3,d2						; -> bits 4..0

	move	#SCREEN_WIDTH-1,d5
.sky_line
	move	d2,(a1)+
	dbf		d5,.sky_line

	addq	#1,d6
	dbf		d7,.sky_loop

	move	#SCREEN_HEIGHT-HORIZON_LINE-1,d7	; ground
	moveq	#0,d6

.ground_loop
	move	d6,d0
	mulu	#18,d0
	divu	#SCREEN_HEIGHT-HORIZON_LINE,d0	; quotient 0..18 down the ground
	move	d0,d1

	move	#20,d2						; red = 20 - t
	sub		d1,d2
	ror		#5,d2						; -> bits 15..11

	move	#17,d3						; green = (17 - t*3/4) * 2, six bits
	move	d1,d4
	mulu	#3,d4
	lsr		#2,d4
	sub		d4,d3
	add		d3,d3
	lsl		#5,d3						; -> bits 10..5
	or		d3,d2

	move	#11,d3						; blue = 11 - t/2
	move	d1,d4
	lsr		#1,d4
	sub		d4,d3
	or		d3,d2						; -> bits 4..0

	move	#SCREEN_WIDTH-1,d5
.ground_line
	move	d2,(a1)+
	dbf		d5,.ground_line

	addq	#1,d6
	dbf		d7,.ground_loop

; -----------------------------------------------------------------------------

	lea		colour_list,a0
	lea		colour_table,a1

	move	#16-1,d7

m_cloop1
	clr.l	d0
	move	(a0)+,d0
	move.l	d0,d1
	and		#%11111,d1				; red
	swap	d1
	lsr.l	#5,d1

	lsr		#6,d0
	move.l	d0,d2
	and		#%11111,d2				; green
	swap	d2
	lsr.l	#5,d2

	lsr		#5,d0
	and		#%11111,d0				; blue
	swap	d0
	lsr.l	#5,d0

	clr.l	d3
	clr.l	d4
	clr.l	d5

	swap	d7

	move	#32-1,d7

m_cloop2
	swap	d3
	swap	d4
	swap	d5
	move	d5,d6
	lsl		#5,d6
	or		d4,d6
	lsl		#6,d6
	or		d3,d6
	move	d6,(a1)+
	swap	d3
	swap	d4
	swap	d5
	add.l	d1,d3
	add.l	d2,d4
	add.l	d0,d5

	dbra	d7,m_cloop2
	swap	d7

	dbra	d7,m_cloop1

	lea		sincos,a0

	move	#3600+900-1,d7

m_convert
	move.l	(a0),d0
	lsr.l	#8,d0
	move.l	d0,(a0)+

	dbra	d7,m_convert

	bsr		make_test_texture

	move.l	work_screen,a0
	move.l	display_screen,a1

	move	#SCREEN_WIDTH*SCREEN_HEIGHT/4-1,d7

m_loop1a
	clr.l	(a0)+
	clr.l	(a1)+
	clr.l	(a0)+
	clr.l	(a1)+

	dbra	d7,m_loop1a

; -----------------------------------------------------------------------------

m_loop1
	clr.l	$466.w

m_loop2
	tst.l	$466.w
	beq.s	m_loop2

	move.l	object,a0
	addq	#6,a0
	lea		mouse_x,a1
	lea		mouse_y,a2
	lea		mouse_key,a3
	bsr		move_object

	bsr		move_camera

	tst		receive_flag
	beq		.skip_receive

	lea		buffer,a1
	lea		colour_table,a2
	bsr		receive_data

.skip_receive
	move	#-1,receive_flag

	lea		object,a1
	lea		sincos,a3
	lea		cam_view,a5
	bsr		send_data

;	move.l	work_screen,a0
;	bsr		clear_screen2

	bsr		clear_screen4

	move.l	work_screen,a0
	lea		buffer,a1
	bsr		draw_poly_tex

;
;
; Milestone 2 scaffolding: a rotating quad with locally computed gradients,
; kept as a known-good reference for draw_span_tex.  Uncomment both lines to
; draw it on top of the model; it must stay after the polygon walker, which
; resets the repair range that clear_screen4 uses.
;
;	move.l	work_screen,a0
;	bsr		draw_quad_tex

; -----------------------------------------------------------------------------

	move.l	work_screen,a3
	move.l	object,a4
	addq	#6,a4

	move.l	a3,a0
	move.w	(a4),d0
	move.w	#4,d1
	bsr		print_value

	lea		5*8(a3),a0
	move.w	2(a4),d0
	move.w	#4,d1
	bsr		print_value

	lea		10*8(a3),a0
	move.w	4(a4),d0
	move.w	#4,d1
	bsr		print_value

	lea		15*8(a3),a0
	move.l	6(a4),d0
	move.w	#8,d1
	bsr		print_value

	lea		24*8(a3),a0
	move.l	10(a4),d0
	move.w	#8,d1
	bsr		print_value

	lea		33*8(a3),a0
	move.l	14(a4),d0
	move.w	#8,d1
	bsr		print_value

; ----

	move.l	work_screen,a0
	lea.l	47*8(a0),a0
	move.b	midi_data,d0
	move.w	#2,d1
	bsr		print_value

;
; VBLs consumed by this frame, straight from the frame clock cleared at the top
; of the loop.  Printing the count rather than 50/count keeps the resolution:
; the ratio truncates, so everything from 17 to 25 VBLs read as 2.
;
	move.l	work_screen,a0
	lea.l	42*8(a0),a0
	move.l	$466.w,d0
	move	#4,d1
	bsr		print_value

	move.l	work_screen,d0
	move.l	display_screen,work_screen
	move.l	d0,display_screen

	move.l	screen_low_high_work,d0
	move.l	screen_low_high_work+4,d1
	move.l	screen_low_high_display,screen_low_high_work
	move.l	screen_low_high_display+4,screen_low_high_work+4
	move.l	d0,screen_low_high_display
	move.l	d1,screen_low_high_display+4

	cmp.b	#KEY_SPACE,key_value
	bne		m_loop1

m_end
	rts

receive_flag
	dc		0

; -----------------------------------------------------------------------------

move_camera
	lea		mc_speed,a0
	clr.l	(a0)
	clr		4(a0)

	cmp.b	#KEY_SHIFT_L,key_value
	bne		mc_not_sh_l
	move	#200,4(a0)

mc_not_sh_l
	cmp.b	#KEY_SHIFT_R,key_value
	bne		mc_not_sh_r
	move	#-200,4(a0)

mc_not_sh_r
	lea		cam_view,a1
	movem	(a1),d0-d2				; x_angle ... z_angle

	lea		sincos,a1
	lea		90*10*4(a1),a2

	move.w	(a0),d3					; x
	move.w	2(a0),d4				; y

	move.w	d3,d5
	muls	1(a2,d2.w*4),d5			; x * cos(z_angle)
	add.l	d5,d5
	swap	d5
	move.w	d5,(a0)

	move.w	d4,d5
	muls	1(a1,d2.w*4),d5			; y * sin(z_angle)
	add.l	d5,d5
	swap	d5
	sub.w	d5,(a0)

	move.w	d3,d5
	muls	1(a1,d2.w*4),d5			; x * sin(z_angle)
	add.l	d5,d5
	swap	d5
	move.w	d5,2(a0)

	move.w	d4,d5
	muls	1(a2,d2.w*4),d5			; y * cos(z_angle)
	add.l	d5,d5
	swap	d5
	add.w	d5,2(a0)

	move.w	2(a0),d3				; y
	move.w	4(a0),d4				; z

	move.w	d3,d5
	muls	1(a2,d0.w*4),d5			; y * cos(x_angle)
	add.l	d5,d5
	swap	d5
	move.w	d5,2(a0)

	move.w	d4,d5
	muls	1(a1,d0.w*4),d5			; z * sin(x_angle)
	add.l	d5,d5
	swap	d5
	sub.w	d5,2(a0)

	move.w	d3,d5
	muls	1(a1,d0.w*4),d5			; y * sin(x_angle)
	add.l	d5,d5
	swap	d5
	move.w	d5,4(a0)

	move.w	d4,d5
	muls	1(a2,d0.w*4),d5			; z * cos(x_angle)
	add.l	d5,d5
	swap	d5
	add.w	d5,4(a0)

	move.w	(a0),d3					; x
	move.w	4(a0),d4				; z

	move.w	d3,d5
	muls	1(a2,d1.w*4),d5			; x * cos(y_angle)
	add.l	d5,d5
	swap	d5
	move.w	d5,(a0)

	move.w	d4,d5
	muls	1(a1,d1.w*4),d5			; z * sin(y_angle)
	add.l	d5,d5
	swap	d5
	add.w	d5,(a0)

	move.w	d4,d5
	muls	1(a2,d1.w*4),d5			; z * cos(y_angle)
	add.l	d5,d5
	swap	d5
	move.w	d5,4(a0)

	move.w	d3,d5
	muls	1(a1,d1.w*4),d5			; x * sin(y_angle)
	add.l	d5,d5
	swap	d5
	sub.w	d5,4(a0)

	movem	mc_speed,d0-d2
	sub.l	d0,cam_pos
	sub.l	d1,cam_pos+4
	add.l	d2,cam_pos+8

	cmp.b	#KEY_ARROW_L,key_value
	bne		mc_not_left

	move	cam_view+2,d0
	subq	#8,d0
	bpl.s	mc_ok1
	add		#3600,d0

mc_ok1
	move	d0,cam_view+2

mc_not_left
	cmp.b	#KEY_ARROW_R,key_value
	bne		mc_not_right

	move	cam_view+2,d0
	addq	#8,d0
	cmp		#3600,d0
	blt.s	mc_ok2
	sub		#3600,d0

mc_ok2
	move	d0,cam_view+2

mc_not_right
	cmp.b	#KEY_ARROW_U,key_value
	bne		mc_not_up

	move	cam_view,d0
	subq	#8,d0
	bpl.s	mc_ok3
	add		#3600,d0

mc_ok3
	move	d0,cam_view

mc_not_up
	cmp.b	#KEY_ARROW_D,key_value
	bne		mc_not_down

	move	cam_view,d0
	addq	#8,d0
	cmp		#3600,d0
	blt.s	mc_ok4
	sub		#3600,d0

mc_ok4
	move	d0,cam_view

mc_not_down
	rts

mc_speed
	ds.w	3

; -----------------------------------------------------------------------------
; a0.l = object parameter
; a1.l = mouse x
; a2.l = mouse y
; a3.l = mouse key

move_object
	move	sr,-(sp)
	move	#$2700,sr

	tst		MOUSE_FLAG_FROM_X(a1)
	bne.s	mo_packet_busy

	move	(a1),d6
	move	(a2),d7
	clr		(a1)
	clr		(a2)
	move	(a3),d5
	bra.s	mo_restore_sr

mo_packet_busy
	move	(sp)+,sr
	bra		mo_done

mo_restore_sr
	move	(sp)+,sr
	tst		d6
	bne.s	mo_have_delta
	tst		d7
	bne.s	mo_have_delta
	bra		mo_done

mo_have_delta
	btst	#1,d5
	beq.s	mo_rotate

	move	d6,d0
	lsl		#MOUSE_MOVE_SHIFT,d0
	ext.l	d0
	add.l	d0,6(a0)

	move	d7,d0
	lsl		#MOUSE_MOVE_SHIFT,d0
	ext.l	d0
	btst	#0,d5
	bne.s	mo_translate_z

	add.l	d0,10(a0)
	bra.s	mo_normalize

mo_translate_z
	sub.l	d0,14(a0)
	bra.s	mo_normalize

mo_rotate
	move	d6,d0
	lsl		#MOUSE_ROT_SHIFT,d0
	add		d0,2(a0)

	move	d7,d0
	lsl		#MOUSE_ROT_SHIFT,d0
	btst	#0,d5
	bne.s	mo_rotate_z

	add		d0,(a0)
	bra.s	mo_normalize

mo_rotate_z
	add		d0,4(a0)

mo_normalize
	lea		(a0),a4
	bsr.s	wrap_angle
	lea		2(a0),a4
	bsr.s	wrap_angle
	lea		4(a0),a4
	bsr.s	wrap_angle

mo_done
	rts

; -----------------------------------------------------------------------------
; a4.l = angle word, range 0 ... 3599

wrap_angle
	move	(a4),d0

wa_low
	tst		d0
	bpl.s	wa_high
	addi	#3600,d0
	bra.s	wa_low

wa_high
	cmpi	#3600,d0
	blt.s	wa_done
	subi	#3600,d0
	bra.s	wa_high

wa_done
	move	d0,(a4)
	rts

; -----------------------------------------------------------------------------
; a1.l = Zeiger auf Struktur object_address, object_address_end
; a3.l = Zeiger auf Sinus-/Cosinus-Tabelle ((360 + 90) * 10 Longs)
; a5.l = Zeiger auf Kamerarotationswinkel

send_data
	clr.l	d0
	clr.l	d1
	move.l	4(a1),d7
	lea		$ffffa204.w,a0

sd_wait1
	btst	#1,-2(a0)
	beq.s	sd_wait1

	move.l	(a1),a1
	lea		90*10*4(a3),a4			; cosinus
	lea		24(a1),a6

	move	(a1)+,d0				; number of points
	move	d0,2(a0)
	subq	#1,d0
	move	(a1)+,d1				; number of normals
	add		d1,d0
	move	d1,2(a0)
	move	(a1)+,2(a0)				; number of polygons

sd_loop1
	move.l	(a6)+,(a0)				; points and normals
	move.l	(a6)+,(a0)
	move.l	(a6)+,(a0)
	dbra	d0,sd_loop1

	addq	#2,a0

sd_loop2
	move	(a6)+,(a0)				; faces
	cmp.l	a6,d7
	bne.s	sd_loop2

	subq	#2,a0

	move.l	#0,(a0)					; camera position
	move.l	#0,(a0)
	move.l	#0,(a0)

	movem	(a1)+,d0-d2

	movem.l	(a1)+,d3-d5				; object position
	move.l	d3,(a0)
	move.l	d4,(a0)
	move.l	d5,(a0)

	move.l	(a3,d0.w*4),(a0)			; object rotation
	move.l	(a3,d1.w*4),(a0)
	move.l	(a3,d2.w*4),(a0)
	move.l	(a4,d0.w*4),(a0)
	move.l	(a4,d1.w*4),(a0)
	move.l	(a4,d2.w*4),(a0)

	movem	(a5),d0-d2

	move.l	(a3,d0.w*4),(a0)			; camera rotation
	move.l	(a3,d1.w*4),(a0)
	move.l	(a3,d2.w*4),(a0)
	move.l	(a4,d0.w*4),(a0)
	move.l	(a4,d1.w*4),(a0)
	move.l	(a4,d2.w*4),(a0)

	rts

; -----------------------------------------------------------------------------
; a0.l = Bildadresse

clear_screen
	cmp.b	#KEY_ESC,key_value
	beq.s	cs_no_clr

	add.l	#SCREEN_WIDTH*(SCREEN_HEIGHT-8)*2,a0
	move	#(SCREEN_WIDTH*(SCREEN_HEIGHT-8)*2/480)-1,d7

;	clr.l	d0
	move	#((31*06/10)<<11)+((63*08/10)<<5)+(31*09/10),d0
	move	d0,d1
	swap	d0
	move	d1,d0
	move.l	d0,d1
	move.l	d0,d2
	move.l	d0,d3
	move.l	d0,d4
	move.l	d0,d5
	move.l	d0,d6
	move.l	d0,a1
	move.l	d0,a2
	move.l	d0,a3
	move.l	d0,a4
	move.l	d0,a5

cs_loop1
	movem.l	d0-d6/a1-a5,-(a0)
	movem.l	d0-d6/a1-a5,-(a0)
	movem.l	d0-d6/a1-a5,-(a0)
	movem.l	d0-d6/a1-a5,-(a0)
	movem.l	d0-d6/a1-a5,-(a0)
	movem.l	d0-d6/a1-a5,-(a0)
	movem.l	d0-d6/a1-a5,-(a0)
	movem.l	d0-d6/a1-a5,-(a0)
	movem.l	d0-d6/a1-a5,-(a0)
	movem.l	d0-d6/a1-a5,-(a0)

	dbra	d7,cs_loop1

cs_no_clr
	rts

; -----------------------------------------------------------------------------
; a0.l = Bildadresse

clear_screen2
	cmp.b	#KEY_ESC,key_value
	beq.s	cs2_no_clr

	lea		background,a6

	move	#SCREEN_HEIGHT-1,d7

.lines_loop
	move	#SCREEN_WIDTH/20-1,d6

.pixels_loop
	rept 10
	move.l	(a6)+,(a0)+
	endr

	dbra	d6,.pixels_loop

	dbra	d7,.lines_loop

cs2_no_clr
	rts

; -----------------------------------------------------------------------------
; a0.l = Bildadresse

clear_screen3
	cmp.b	#KEY_ESC,key_value
	beq.s	cs3_no_clr

	move.l	#background,Src_Addr.w
	move.l	a0,Dst_Addr.w

	move	#2,Src_Xinc.w
	move	#2,Src_Yinc.w

	move	#2,Dst_Xinc.w
	move	#2,Dst_Yinc.w

	move	#SCREEN_WIDTH,X_Count.w
	move	#SCREEN_HEIGHT-8,Y_Count.w

	move	#$ffff,Endmask1.w
	move	#$ffff,Endmask2.w
	move	#$ffff,Endmask3.w

	move.b	#%10,HOP
	move.b	#%0011,OP.w
	clr.b	Skew.w

	move.b	#%11000000,Line_Num.w

cs3_no_clr
	rts

; -----------------------------------------------------------------------------

clear_screen4
	cmp.b	#KEY_ESC,key_value
	beq		.skip

	move.l	screen_low_high_work,d0
	sub.l	#SCREEN_WIDTH*2,d0

	move.l	screen_low_high_work+4,d1
	bne		.clear

	move.l	work_screen,a0

	bra		clear_screen2

.clear
	lea		background,a0
	
	move.l	d0,d2
	sub.l	work_screen,d2

	lea		(a0,d2.l),a0
	move.l	d0,a1

.lines_loop
	move	#SCREEN_WIDTH/20-1,d7

.pixels_loop
	rept 10
	move.l	(a0)+,(a1)+
	endr

	dbra	d7,.pixels_loop

	cmp.l	d1,a1
	bcs		.lines_loop

.skip
	rts

; -----------------------------------------------------------------------------
; a1.l = buffer
; a2.l = Farbtabellenanfang

receive_data
	move.l	#$ff000000,d6
	move.l	#$007fffff,d7
	lea		$ffffa204.w,a0
	move.l	a1,a3						; face-count destination
	addq	#2,a1						; filled when terminator arrives
	clr.l	d0							; received face count

rd_loop1
	btst	#0,-2(a0)
	beq.s	rd_loop1

	move.l	(a0),d1						; count
	tst.l	d1							; zero terminates the stream
	beq		rd_end

	addq.l	#1,d0
	lsr		#2,d1
	subq	#1,d1
	move	d1,(a1)+

rd_wait_colour
	btst	#0,-2(a0)
	beq.s	rd_wait_colour

	move.l	(a0),d2						; colour
	move	(a2,d2.w*2),(a1)+

rd_wait_offset
	btst	#0,-2(a0)
	beq.s	rd_wait_offset

	move.l	(a0),d2						; offset
	move.l	d2,(a1)+

;
; The DSP appends the six texture words after the runs, but the rasteriser
; wants them up front, so reserve the slots here and fill them below.
;
	move.l	a1,a4
	lea		24(a1),a1

rd_loop2

rd_wait_left
	btst	#0,-2(a0)
	beq.s	rd_wait_left

	move.l	(a0),d2						; left step

rd_wait_right
	btst	#0,-2(a0)
	beq.s	rd_wait_right

	move.l	(a0),d3						; right step

rd_wait_flags
	btst	#0,-2(a0)
	beq.s	rd_wait_flags

	move.l	(a0),d4						; flags

rd_wait_lines
	btst	#0,-2(a0)
	beq.s	rd_wait_lines

	move.l	(a0),d5						; lines

	btst	#3,d4
	bne.s	rd_skip1b

	cmp.l	d7,d2
	ble.s	rd_skip1

	or.l	d6,d2

rd_skip1
	lsl.l	#2,d2

rd_skip1b
	btst	#2,d4
	bne.s	rd_skip2b

	cmp.l	d7,d3
	ble.s	rd_skip2

	or.l	d6,d3

rd_skip2
	lsl.l	#2,d3

rd_skip2b
	move	d4,(a1)+
	move.l	d2,(a1)+
	move.l	d3,(a1)+
	move	d5,(a1)+

	dbra	d1,rd_loop2

;
; u0, dudx, dudy as 16.16 and v0, dvdx, dvdy as 8.24 - the two accumulators in
; draw_span_tex carry different binary points so that the texel index is a byte
; splice.  All six arrive scaled by 2^14, like the edge steps.
;
	moveq	#3-1,d3

rd_tex_u
	btst	#0,-2(a0)
	beq.s	rd_tex_u

	move.l	(a0),d2
	cmp.l	d7,d2
	ble.s	.positive
	or.l	d6,d2

.positive
	lsl.l	#2,d2
	move.l	d2,(a4)+

	dbra	d3,rd_tex_u

	moveq	#3-1,d3

rd_tex_v
	btst	#0,-2(a0)
	beq.s	rd_tex_v

	move.l	(a0),d2
	cmp.l	d7,d2
	ble.s	.positive
	or.l	d6,d2

.positive
	lsl.l	#2,d2
	lsl.l	#8,d2
	move.l	d2,(a4)+

	dbra	d3,rd_tex_v

	bra		rd_loop1

rd_end
	move	d0,(a3)
	rts

; -----------------------------------------------------------------------------
; a0.l = screen address
; d0.l = value
; d1.w = lenght of string

print_value
	lea		chars,a1

	subq	#1,d1
	lea		(a0,d1.w*8),a0

pv_loop
	move.w	d0,d2
	and		#$f,d2
	move.l	(a1,d2.w*4),a2
	move.l	(a2)+,(a0)
	move.l	(a2)+,4(a0)
	move.l	(a2)+,1*SCREEN_WIDTH*2(a0)
	move.l	(a2)+,1*SCREEN_WIDTH*2+4(a0)
	move.l	(a2)+,2*SCREEN_WIDTH*2(a0)
	move.l	(a2)+,2*SCREEN_WIDTH*2+4(a0)
	move.l	(a2)+,3*SCREEN_WIDTH*2(a0)
	move.l	(a2)+,3*SCREEN_WIDTH*2+4(a0)
	move.l	(a2)+,4*SCREEN_WIDTH*2(a0)
	move.l	(a2)+,4*SCREEN_WIDTH*2+4(a0)

	lsr.l	#4,d0
	subq	#8,a0

	dbra	d1,pv_loop

	rts

; -----------------------------------------------------------------------------
	data
; -----------------------------------------------------------------------------


colour_list
	dc		((31*02/10)<<11)+((63*02/10)<<5)+(31*02/10)
	dc		((31*05/10)<<11)+((63*05/10)<<5)+(31*05/10)
	dc		((31*09/10)<<11)+((63*09/10)<<5)+(31*08/10)
	dc		((31*09/10)<<11)+((63*09/10)<<5)+(31*08/10)
	dc		((31*08/10)<<11)+((63*08/10)<<5)+(31*08/10)
	dc		((31*08/10)<<11)+((63*08/10)<<5)+(31*08/10)
	dc		((31*05/10)<<11)+((63*08/10)<<5)+(31*10/10)
	dc		((31*02/10)<<11)+((63*08/10)<<5)+(31*10/10)
	dc		((31*09/10)<<11)+((63*07/10)<<5)+(31*04/10)
	dc		((31*05/10)<<11)+((63*04/10)<<5)+(31*02/10)
	dc		((31*06/10)<<11)+((63*06/10)<<5)+(31*06/10)
	dc		((31*10/10)<<11)+((63*10/10)<<5)+(31*00/10)
	dc		((31*10/10)<<11)+((63*10/10)<<5)+(31*10/10)
	dc		((31*02/10)<<11)+((63*02/10)<<5)+(31*02/10)

	dc.w	%0000000000000000
	dc.w	%1111100000000000
	dc.w	%0000011111000000
	dc.w	%0000000000011111
	dc.w	%1111111111000000
	dc.w	%1111100000011111
	dc.w	%0000011111011111
	dc.w	%1111111111011111

	dc.w	%0000000000000000
	dc.w	%0111100000000000
	dc.w	%0000001111000000
	dc.w	%0000000000001111
	dc.w	%0111101111000000
	dc.w	%0111100000001111
	dc.w	%0000001111001111
	dc.w	%0111101111001111

object
	dc.l	cube,cube_end
	dc.l	cube,cube_end

cam_view
	dc.w	0,0,0
cam_pos
	dc.l	0,0,-5000

cube
	dc.w	8						; number of points
	dc.w	6						; number of normals
	dc.w	6						; number of polygons

	dc.w	0*10,0*10,0*10			; rotation
	dc.l	0,0,4000				; position

	dc.l	-1000,-1000,-1000
	dc.l	1000,-1000,-1000
	dc.l	1000,1000,-1000
	dc.l	-1000,1000,-1000
	dc.l	-1000,-1000,1000
	dc.l	1000,-1000,1000
	dc.l	1000,1000,1000
	dc.l	-1000,1000,1000

	dc.l	0,0,$800001
	dc.l	0,0,$7fffff
	dc.l	0,$800001,0
	dc.l	$7fffff,0,0
	dc.l	0,$7fffff,0
	dc.l	$800001,0,0

	dc.w	4,1*32,8*3,9*1+3,0,0*3,1*3,2*3,3*3
	dc.w	4,2*32,10*3,9*2+3,0,0*3,4*3,5*3,1*3
	dc.w	4,3*32,11*3,9*3+3,0,1*3,5*3,6*3,2*3
	dc.w	4,2*32,12*3,9*4+3,0,2*3,6*3,7*3,3*3
	dc.w	4,3*32,13*3,9*5+3,0,3*3,7*3,4*3,0*3
	dc.w	4,1*32,9*3,0,0,7*3,6*3,5*3,4*3
cube_end

chars
	dc.l	char_0, char_1, char_2, char_3
	dc.l	char_4, char_5, char_6, char_7
	dc.l	char_8, char_9, char_a, char_b
	dc.l	char_c, char_d, char_e, char_f

char_0
	dc.w	 0,-1, 0, 0
	dc.w	-1, 0,-1, 0
	dc.w	-1, 0,-1, 0
	dc.w	-1, 0,-1, 0
	dc.w	 0,-1, 0, 0
char_1
	dc.w	 0,-1, 0, 0
	dc.w	-1,-1, 0, 0
	dc.w	 0,-1, 0, 0
	dc.w	 0,-1, 0, 0
	dc.w	-1,-1,-1, 0
char_2
	dc.w	-1,-1, 0, 0
	dc.w	 0, 0,-1, 0
	dc.w	 0,-1, 0, 0
	dc.w	-1, 0, 0, 0
	dc.w	-1,-1,-1, 0
char_3
	dc.w	-1,-1, 0, 0
	dc.w	 0, 0,-1, 0
	dc.w	 0,-1, 0, 0
	dc.w	 0, 0,-1, 0
	dc.w	-1,-1, 0, 0
char_4
	dc.w	-1, 0,-1, 0
	dc.w	-1, 0,-1, 0
	dc.w	-1,-1,-1, 0
	dc.w	 0, 0,-1, 0
	dc.w	 0, 0,-1, 0
char_5
	dc.w	-1,-1,-1, 0
	dc.w	-1, 0, 0, 0
	dc.w	-1,-1, 0, 0
	dc.w	 0, 0,-1, 0
	dc.w	-1,-1, 0, 0
char_6
	dc.w	 0,-1,-1, 0
	dc.w	-1, 0, 0, 0
	dc.w	-1,-1, 0, 0
	dc.w	-1, 0,-1, 0
	dc.w	 0,-1, 0, 0
char_7
	dc.w	-1,-1,-1, 0
	dc.w	 0, 0,-1, 0
	dc.w	 0, 0,-1, 0
	dc.w	 0,-1, 0, 0
	dc.w	 0,-1, 0, 0
char_8
	dc.w	 0,-1, 0, 0
	dc.w	-1, 0,-1, 0
	dc.w	 0,-1, 0, 0
	dc.w	-1, 0,-1, 0
	dc.w	 0,-1, 0, 0
char_9
	dc.w	 0,-1, 0, 0
	dc.w	-1, 0,-1, 0
	dc.w	 0,-1,-1, 0
	dc.w	 0, 0,-1, 0
	dc.w	-1,-1, 0, 0
char_a
	dc.w	 0,-1, 0, 0
	dc.w	-1, 0,-1, 0
	dc.w	-1,-1,-1, 0
	dc.w	-1, 0,-1, 0
	dc.w	-1, 0,-1, 0
char_b
	dc.w	-1,-1, 0, 0
	dc.w	-1, 0,-1, 0
	dc.w	-1,-1, 0, 0
	dc.w	-1, 0,-1, 0
	dc.w	-1,-1, 0, 0
char_c
	dc.w	 0,-1,-1, 0
	dc.w	-1, 0, 0, 0
	dc.w	-1, 0, 0, 0
	dc.w	-1, 0, 0, 0
	dc.w	 0,-1,-1, 0
char_d
	dc.w	-1,-1, 0, 0
	dc.w	-1, 0,-1, 0
	dc.w	-1, 0,-1, 0
	dc.w	-1, 0,-1, 0
	dc.w	-1,-1, 0, 0
char_e
	dc.w	-1,-1,-1, 0
	dc.w	-1, 0, 0, 0
	dc.w	-1,-1, 0, 0
	dc.w	-1, 0, 0, 0
	dc.w	-1,-1,-1, 0
char_f
	dc.w	-1,-1,-1, 0
	dc.w	-1, 0, 0, 0
	dc.w	-1,-1, 0, 0
	dc.w	-1, 0, 0, 0
	dc.w	-1, 0, 0, 0

	bss

background
	ds		SCREEN_WIDTH*SCREEN_HEIGHT

colour_table
	ds.w	32*32

buffer
	ds.l	20000

	end
