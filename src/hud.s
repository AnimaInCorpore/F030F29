; -----------------------------------------------------------------------------
; flight HUD: airspeed, altitude and heading readout
; -----------------------------------------------------------------------------
;
; Three plain numeric fields, positioned the way a real HUD does it so no text
; labels are needed: airspeed bottom left, altitude bottom right, heading top
; centre as a compass bearing. No cockpit artwork or icon set from the
; original is reproduced here - see docs/GAME-LOOP.md for that reverse-
; engineering work and why it stays out of this repository.
;
; The values come from the DOS-width flight state seam in flight.s. The full
; aircraft dynamics are still a separate, larger port (see
; docs/FLIGHT-MODEL.md), but the HUD no longer invents motion from frame_count.
; What is faithful to the original already:
;
;  - the units (airspeed 8 per knot, altitude 4 ft per unit, heading 2048
;    units to the circle);
;  - the starting values (3200 = 400 kt, 3000, 1024 = due south);
;  - the heading-to-bearing conversion, the same 16.16 multiply and
;    "negate and add 360, but zero stays zero" the original's instrument
;    routine uses (see [0xAE4C] in GAME-LOOP.md).
;
; -----------------------------------------------------------------------------
	global	hud_init, hud_draw
	global	hud_airspeed, hud_altitude, hud_heading

SCREEN_WIDTH = 320

; X is the field's leftmost pixel (the most significant digit's position -
; print_value_dec fills in from the right, ending up back at this anchor).
HUD_AIRSPEED_X = 8*2					; 3 digits, 8px in from the left edge
HUD_AIRSPEED_Y = 225
HUD_ALTITUDE_X = (320-8-5*4)*2			; 5 digits, 8px in from the right edge
HUD_ALTITUDE_Y = 225
HUD_HEADING_X = (320-3*4)/2*2			; 3 digits, centred
HUD_HEADING_Y = 8

; -----------------------------------------------------------------------------
	text
; -----------------------------------------------------------------------------

hud_init
	move	#3200,hud_airspeed
	move	#3000,hud_altitude
	move	#1024,hud_heading
	rts

; Call once per frame, after everything else has drawn into work_screen.
hud_draw
	move	flight_airspeed,hud_airspeed
	move	flight_altitude,hud_altitude
	move	flight_heading,d0
	and		#$7ff,d0				; wrap at 2048, the circle
	move	d0,hud_heading

; airspeed, in knots - internal unit is 8 per knot
	move.l	work_screen,a0
	lea		HUD_AIRSPEED_X+HUD_AIRSPEED_Y*SCREEN_WIDTH*2(a0),a0
	move	hud_airspeed,d0
	lsr		#3,d0
	ext.l	d0
	move	#3,d1
	bsr		print_value_dec

; altitude, in feet - internal unit is 4 ft
	move.l	work_screen,a0
	lea		HUD_ALTITUDE_X+HUD_ALTITUDE_Y*SCREEN_WIDTH*2(a0),a0
	move	hud_altitude,d0
	sub		#20,d0				; DOS ground reference: -20 -> 0 ft
	ext.l	d0
	lsl.l	#2,d0
	move	#5,d1
	bsr		print_value_dec

; heading, as a compass bearing in degrees.  0x2D00 * 2048 / 65536 = 360, so
; a 16-bit multiply and taking the high word gives degrees directly; negating
; and adding 360 turns the mathematical angle into a bearing, except zero
; stays zero.  Same conversion as the original's instrument routine.
	move.l	work_screen,a0
	lea		HUD_HEADING_X+HUD_HEADING_Y*SCREEN_WIDTH*2(a0),a0
	move	hud_heading,d0
	mulu.w	#$2d00,d0			; word*word->long, not the 68020 long form
	swap	d0
	tst.w	d0					; explicit .w - these must stay on the low
	beq.s	.hud_north			; word only, the degrees swap left there
	neg.w	d0
	add.w	#360,d0
.hud_north
	ext.l	d0
	move	#3,d1
	bsr		print_value_dec

	rts

; -----------------------------------------------------------------------------
; Decimal readout, same shape as f29.s's print_value but base 10 instead of
; base 16. Digits are computed least-significant first and drawn right to
; left, so the caller's a0 is the field's leftmost pixel - the position the
; most significant digit ends up at once the loop walks back to it.
;
; a0.l = screen address, leftmost digit
; d0.l = value, unsigned, 0..65535
; d1.w = number of digits
; -----------------------------------------------------------------------------

print_value_dec
	lea		chars,a1

	subq	#1,d1
	lea		(a0,d1.w*8),a0

pvd_loop
	clr.l	d2
	move	d0,d2
	divu	#10,d2
	move	d2,d0				; quotient -> next iteration
	swap	d2
	and		#$f,d2				; remainder, 0..9 -> this digit

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

	subq	#8,a0

	dbra	d1,pvd_loop

	rts

; -----------------------------------------------------------------------------
	bss
; -----------------------------------------------------------------------------

hud_airspeed
	ds.w	1
hud_altitude
	ds.w	1
hud_heading
	ds.w	1

	end
