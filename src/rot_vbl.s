; standard vbl interrupt routine (c) 1994 by Sascha Springer

	global vbl, vbl_tick

	text

vbl
	move.b	display_screen+1,$ffff8201.w
	move.b	display_screen+2,$ffff8203.w
	move.b	display_screen+3,$ffff820d.w

	movem.l	d0-a6,-(a7)

	move.l	object,a0
	addq	#6,a0

;	add		#2,(a0)
	add		#5,2(a0)
;	add		#7,4(a0)
	bsr		v_check

	move.l	object+8,a0
	addq	#6,a0

	add		#1,(a0)
	add		#-3,2(a0)
	add		#-2,4(a0)
	bsr		v_check

	lea		cam_view,a0
	add		#0,(a0)
	add		#0,2(a0)
	add		#0,4(a0)

	addq.l	#1,$466.w
	addq.l	#1,vbl_tick

	movem.l	(a7)+,d0-a6
	
	rte

v_check
	tst		(a0)
	bpl.s	v_ok1a

	addi	#3600,(a0)

v_ok1a
	cmpi	#3600,(a0)
	blt.s	v_ok1

	subi	#3600,(a0)

v_ok1
	tst		2(a0)
	bpl.s	v_ok2a

	addi	#3600,2(a0)

v_ok2a
	cmpi	#3600,2(a0)
	blt.s	v_ok2

	subi	#3600,2(a0)

v_ok2
	tst		4(a0)
	bpl.s	v_ok3a

	addi	#3600,4(a0)

v_ok3a
	cmpi	#3600,4(a0)
	blt.s	v_ok3

	subi	#3600,4(a0)

v_ok3
	rts

	bss

; Monotonic VBL clock for the simulation. Unlike $466.w, this is never
; cleared by the main-loop handshake.
vbl_tick
	ds.l	1

	end
