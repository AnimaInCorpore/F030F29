; keyboard interrupt routine (c) 1993/94 by Sascha Springer

	global keyboard, key_value, mouse_x, mouse_y, joystick0, joystick1
	global mouse_key, midi_data
;	global keyboard2, key_value2, mouse_x2, mouse_y2, joystick02, joystick12
;	global mouse_key2, midi_data2

KEY_VALUE = 0
MOUSE_FLAG = 2
MOUSE_KEY = 4
MOUSE_X = 6
MOUSE_Y = 8
JOY_FLAG = 10
JOY_SELECT = 12
JOYSTICK0 = 14
JOYSTICK1 = 15

	text

keyboard
	movem.l	d0-d1/a0,-(sp)

key_loop
	btst	#0,$fffffc04.w
	beq.s	key_not_midi

	lea		key_data2,a0
	move.b	$fffffc06.w,d0
	move.b	d0,midi_data
	bsr.s	key_ikbd

key_not_midi
	btst	#0,$fffffc00.w
	beq.s	key_not_ikbd

	lea		key_data,a0
	move.b	$fffffc02.w,d0
	bsr.s	key_ikbd

key_not_ikbd
	btst	#4,$fffffa01.w
	beq.s	key_loop

	movem.l	(a7)+,d0-d1/a0
	bclr	#6,$fffffa11.w

	rte

key_ikbd
	tst.w	JOY_FLAG(a0)
	bne		key_joy

	cmpi.w	#2,MOUSE_FLAG(a0)
	beq.s	key_mouse2

	tst.w	MOUSE_FLAG(a0)
	bne.s	key_mouse1

	move.b	d0,d1
	and.b	#$fc,d1
	cmp.b	#$f8,d1
	bne.s	key_no_mouse

	and.b	#$03,d0
	move.b	d0,MOUSE_KEY(a0)
	move.w	#2,MOUSE_FLAG(a0)

	rts

key_no_mouse
	move.b	d0,d1
	and.b	#$fe,d1
	cmp.b	#$fe,d1
	bne.s	key_no_joy

	not.b	d0
	move.b	d0,JOY_SELECT(a0)
	not.w	JOY_FLAG(a0)

	rts

key_no_joy
	move.b	d0,KEY_VALUE(a0)

	rts

key_mouse2
	ext.w	d0
	add.w	d0,MOUSE_X(a0)
	subq.w	#1,MOUSE_FLAG(a0)

	rts

key_mouse1
	ext.w	d0
	add.w	d0,MOUSE_Y(a0)
	subq.w	#1,MOUSE_FLAG(a0)

	rts

key_joy
	clr.w	JOY_FLAG(a0)
	tst.b	JOY_SELECT(a0)
	bne.s	key_joy2
	move.b	d0,JOYSTICK0(a0)

	rts

key_joy2
	move.b	d0,JOYSTICK1(a0)

	rts

	bss

key_data
key_value
	ds.w	1						; 0
mouse_flag
	ds.w	1						; 2
mouse_key
	ds.w	1						; 4
mouse_x
	ds.w	1						; 6
mouse_y
	ds.w	1						; 8
joy_flag
	ds.w	1						; 10
joy_select
	ds.w	1						; 12
joystick0
	ds.b	1						; 14
joystick1
	ds.b	1						; 15

key_data2
key_value2
	ds.w	1						; 0
mouse_flag2
	ds.w	1						; 2
mouse_key2
	ds.w	1						; 4
mouse_x2
	ds.w	1						; 6
mouse_y2
	ds.w	1						; 8
joy_flag2
	ds.w	1						; 10
joy_select2
	ds.w	1						; 12
joystick02
	ds.b	1						; 14
joystick12
	ds.b	1						; 15

midi_data
	ds.w	1

	end
