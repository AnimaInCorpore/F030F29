; -----------------------------------------------------------------------------
; DOS-compatible flight state seam
; -----------------------------------------------------------------------------
;
; This is the scalar/attitude/position core of the 0x4EB6 aircraft model. The
; sound/device flags and the final stall-departure branch remain separate, but
; the state now advances from the DOS-sized fields and copied lookup tables.
;
; DOS contracts (see docs/FLIGHT-MODEL.md):
;   airspeed  : 8 units per knot, starts at 3200 (400 kt)
;   altitude  : 4 ft per unit, starts at 3000; display subtracts ground 20
;   heading   : 2048 units per circle, starts at 1024
;   throttle  : 0..500, idle at 135
;   delta     : VBL ticks, clamped to 25; 8.8 copy is delta << 8
;
; The port activates dynamics after the first flight control input. This keeps
; the renderer's startup/demo frame at the documented reset values while making
; controlled-input runs exercise the actual state integration.
; -----------------------------------------------------------------------------

	global	flight_init, flight_step
	global	flight_delta, flight_delta_88
	global	flight_airspeed, flight_altitude, flight_heading
	global	flight_pitch, flight_bank, flight_pitch_command
	global	flight_throttle, flight_load_factor, flight_input, flight_active
	global	flight_world_x, flight_world_y, flight_world_z
	global	flight_sync_view

	global	vbl_tick, key_value
	global	scene_camera, cam_view

KEY_SHIFT_L = 42
KEY_SHIFT_R = 54
KEY_ARROW_U = 72
KEY_ARROW_L = 75
KEY_ARROW_R = 77
KEY_ARROW_D = 80

INPUT_THROTTLE_UP = 0
INPUT_THROTTLE_DOWN = 1
INPUT_PITCH_UP = 2
INPUT_BANK_LEFT = 3
INPUT_BANK_RIGHT = 4
INPUT_PITCH_DOWN = 5

	text

; Establish the same scalar start values as the DOS reset path and anchor the
; first delta to the VBL counter. The HUD reads the flight fields directly.
flight_init
	move.l	vbl_tick,flight_last_vbl
	move.w	#1,flight_delta
	move.w	#$100,flight_delta_88
	move.w	#3200,flight_airspeed
	move.w	#3000,flight_altitude
	move.w	#1024,flight_heading
	clr.w	flight_pitch
	clr.w	flight_bank
	clr.w	flight_pitch_command
	move.w	#135,flight_throttle
	move.b	#10,flight_load_factor
	clr.b	flight_input
	clr.b	flight_active
	move.l	scene_camera,flight_world_x
	move.l	scene_camera+4,flight_world_y
	move.l	scene_camera+8,flight_world_z
	move.l	scene_camera+4,flight_world_origin_y
	move.l	scene_camera,d0
	lsl.l	#8,d0
	lsl.l	#8,d0
	move.l	d0,flight_world_x_accum
	move.l	scene_camera+8,d0
	lsl.l	#8,d0
	lsl.l	#8,d0
	move.l	d0,flight_world_z_accum
	move.l	#(3000<<16),flight_altitude_accum
	move.l	#(3200<<8),flight_speed_accum
	rts

; Sample the monotonic VBL clock once per simulation frame and capture the
; current command input. VBL handshaking still uses $466; vbl_tick is the
; independent timing source so clearing the handshake cannot erase elapsed
; time. This is the Falcon equivalent of DOS [0x347C]/[0x347B].
flight_step
	movem.l	d0-d7/a0-a2,-(sp)

	move.l	vbl_tick,d0
	move.l	d0,d1
	sub.l	flight_last_vbl,d0
	move.l	d1,flight_last_vbl

	tst.l	d0
	bgt.s	.delta_nonzero
	moveq	#1,d0

.delta_nonzero
	cmpi.l	#25,d0
	ble.s	.delta_ready
	moveq	#25,d0

.delta_ready
	move.w	d0,flight_delta
	lsl.l	#8,d0
	move.w	d0,flight_delta_88

; The original stores commands separately from the integrated state. Preserve
; that distinction here: flight_input is the one-frame command latch and the
; pitch/throttle/bank fields are the persistent controls.
	clr.b	flight_input
	moveq	#0,d1
	move.b	key_value,d1

	cmpi.b	#KEY_SHIFT_L,d1
	bne.s	.not_throttle_up
	bset	#INPUT_THROTTLE_UP,flight_input

.not_throttle_up
	cmpi.b	#KEY_SHIFT_R,d1
	bne.s	.not_throttle_down
	bset	#INPUT_THROTTLE_DOWN,flight_input

.not_throttle_down
	cmpi.b	#KEY_ARROW_U,d1
	bne.s	.not_pitch_up
	bset	#INPUT_PITCH_UP,flight_input

.not_pitch_up
	cmpi.b	#KEY_ARROW_D,d1
	bne.s	.not_pitch_down
	bset	#INPUT_PITCH_DOWN,flight_input

.not_pitch_down
	cmpi.b	#KEY_ARROW_L,d1
	bne.s	.not_bank_left
	bset	#INPUT_BANK_LEFT,flight_input

.not_bank_left
	cmpi.b	#KEY_ARROW_R,d1
	bne.s	.input_done
	bset	#INPUT_BANK_RIGHT,flight_input


.input_done
	tst.b	flight_input
	beq.s	.no_new_input
	st	flight_active

.no_new_input
	tst.b	flight_active
	beq.s	.step_return
	bsr	flight_apply_input
	bsr	flight_integrate

.step_return
	movem.l	(sp)+,d0-d7/a0-a2
	rts

; Apply one-frame controls. The keyboard path supplies make codes rather than
; held axes, so commands have a small DOS-like integrator and return toward
; neutral when the key is released.
flight_apply_input
	move.w	flight_delta,d0
	lsl	#2,d0

	btst	#INPUT_THROTTLE_UP,flight_input
	beq.s	.no_throttle_up
	add.w	d0,flight_throttle

.no_throttle_up
	btst	#INPUT_THROTTLE_DOWN,flight_input
	beq.s	.no_throttle_down
	sub.w	d0,flight_throttle

.no_throttle_down
	cmpi.w	#500,flight_throttle
	bls.s	.throttle_high_ok
	move.w	#500,flight_throttle

.throttle_high_ok
	tst.w	flight_throttle
	bpl.s	.throttle_low_ok
	clr.w	flight_throttle

.throttle_low_ok

	move.w	flight_delta,d0
	lsl	#4,d0
	btst	#INPUT_PITCH_UP,flight_input
	beq.s	.no_pitch_up
	add.w	d0,flight_pitch_command

.no_pitch_up
	btst	#INPUT_PITCH_DOWN,flight_input
	beq.s	.no_pitch_down
	sub.w	d0,flight_pitch_command

.no_pitch_down
	btst	#INPUT_PITCH_UP,flight_input
	bne.s	.pitch_command_clamp
	btst	#INPUT_PITCH_DOWN,flight_input
	bne.s	.pitch_command_clamp

	; Release returns the command toward level.
	move.w	flight_delta,d0
	lsl	#3,d0
	tst.w	flight_pitch_command
	beq.s	.pitch_command_clamp
	bmi.s	.pitch_neutral_positive
	sub.w	d0,flight_pitch_command
	bpl.s	.pitch_command_clamp
	clr.w	flight_pitch_command
	bra.s	.pitch_command_clamp

.pitch_neutral_positive
	add.w	d0,flight_pitch_command
	bmi.s	.pitch_command_clamp
	clr.w	flight_pitch_command

.pitch_command_clamp
	cmpi.w	#11519,flight_pitch_command
	ble.s	.pitch_command_high_ok
	move.w	#11519,flight_pitch_command

.pitch_command_high_ok
	cmpi.w	#-11519,flight_pitch_command
	bge.s	.pitch_command_low_ok
	move.w	#-11519,flight_pitch_command

.pitch_command_low_ok

	move.w	flight_delta,d0
	lsl	#3,d0
	btst	#INPUT_BANK_LEFT,flight_input
	beq.s	.no_bank_left
	sub.w	d0,flight_bank

.no_bank_left
	btst	#INPUT_BANK_RIGHT,flight_input
	beq.s	.no_bank_right
	add.w	d0,flight_bank

.no_bank_right
	btst	#INPUT_BANK_LEFT,flight_input
	bne.s	.bank_clamp
	btst	#INPUT_BANK_RIGHT,flight_input
	bne.s	.bank_clamp

	; Release returns bank toward level.
	tst.w	flight_bank
	beq.s	.bank_clamp
	bmi.s	.bank_neutral_positive
	sub.w	d0,flight_bank
	bpl.s	.bank_clamp
	clr.w	flight_bank
	bra.s	.bank_clamp

.bank_neutral_positive
	add.w	d0,flight_bank
	bmi.s	.bank_clamp
	clr.w	flight_bank

.bank_clamp
	cmpi.w	#512,flight_bank
	ble.s	.bank_high_ok
	move.w	#512,flight_bank

.bank_high_ok
	cmpi.w	#-512,flight_bank
	bge.s	.bank_low_ok
	move.w	#-512,flight_bank

.bank_low_ok
	rts

; Integrate load factor, attitude, airspeed and the 16.16-style world motion.
; The arithmetic follows the documented DOS order, with the two unresolved
; device/stall flags omitted until their source inputs are reconstructed.
flight_integrate
	; Pitch attitude approaches the commanded pull at 32 angle units per
	; frame-delta tick.
	move.w	flight_pitch_command,d0
	sub.w	flight_pitch,d0
	move.w	flight_delta,d1
	lsl	#5,d1
	tst.w	d0
	bpl.s	.pitch_diff_positive
	neg.w	d0
	cmp.w	d1,d0
	bhi.s	.pitch_step_negative
	move.w	flight_pitch_command,flight_pitch
	bra.s	.pitch_done

.pitch_step_negative
	neg.w	d1
	add.w	d1,flight_pitch
	bra.s	.pitch_done

.pitch_diff_positive
	cmp.w	d1,d0
	bhi.s	.pitch_step_positive
	move.w	flight_pitch_command,flight_pitch
	bra.s	.pitch_done

.pitch_step_positive
	add.w	d1,flight_pitch

.pitch_done
	; Load factor: 10 at level, rising with bank and commanded pull, then
	; capped by the DOS manoeuvre envelope table.
	moveq	#10,d0
	move.w	flight_bank,d1
	bpl.s	.bank_abs_ok
	neg.w	d1
.bank_abs_ok
	lsr	#7,d1
	add.w	d1,d0

	move.w	flight_pitch_command,d1
	bpl.s	.command_abs_ok
	neg.w	d1
.command_abs_ok
	lsr	#8,d1
	lsr	#2,d1
	add.w	d1,d0

	moveq	#0,d2
	move.w	flight_altitude,d2
	lsr	#8,d2
	and	#$38,d2
	move.w	d2,d3
	lsr	#2,d3
	add.w	d2,d3

	moveq	#0,d4
	move.w	flight_airspeed,d4
	lsr	#8,d4
	lsr	#1,d4
	cmpi.w	#9,d4
	bhi.s	.load_cap_floor
	add.w	d4,d3
	lea	flight_manoeuvre_envelope,a0
	moveq	#0,d4
	move.b	(a0,d3.w),d4
	cmp.w	d4,d0
	bls.s	.load_store
	move.w	d4,d0
	bra.s	.load_store

.load_cap_floor
	cmpi.w	#15,d0
	bls.s	.load_store
	moveq	#15,d0

.load_store
	move.b	d0,flight_load_factor

	; DOS airspeed target: thrust/load minus pitch gravity and 1.25x drag.
	moveq	#0,d0
	move.w	flight_throttle,d0
	sub.w	#135,d0
	bpl.s	.thrust_nonnegative
	clr.l	d0
.thrust_nonnegative
	lsl	#3,d0
	moveq	#0,d1
	move.b	flight_load_factor,d1
	cmpi.w	#10,d1
	bge.s	.load_divisor_ready
	moveq	#10,d1
.load_divisor_ready
	divu	d1,d0
	move.w	d0,d4

	moveq	#0,d0
	move.w	flight_airspeed,d0
	move.l	d0,d5
	cmpi.w	#4640,d0
	bls.s	.no_drag_rise
	addi.l	#80,d5
.no_drag_rise
	moveq	#3,d1
	mulu	d1,d5
	lsr.l	#8,d5
	moveq	#63,d1
	move.w	flight_altitude,d2
	lsr	#8,d2
	sub.w	d2,d1
	add.l	d1,d5

	move.w	flight_pitch,d0
	bsr	flight_sin
	ext.l	d0
	asr.l	#8,d0
	add.l	d0,d0
	sub.l	d0,d4

	move.l	d5,d0
	lsr.l	#2,d0
	add.l	d5,d0
	sub.l	d0,d4
	cmpi.w	#20,flight_altitude
	bhi.s	.not_on_ground
	subi.l	#50,d4
.not_on_ground

	move.w	flight_delta,d0
	muls	d0,d4
	lsl.l	#8,d4
	add.l	d4,flight_speed_accum
	move.l	flight_speed_accum,d0
	asr.l	#8,d0
	bpl.s	.speed_floor_ok
	moveq	#0,d0
	move.l	d0,flight_speed_accum
.speed_floor_ok
	cmpi.l	#8191,d0
	bls.s	.speed_store
	move.l	#8191,d0
	move.l	d0,d1
	lsl.l	#8,d1
	move.l	d1,flight_speed_accum
.speed_store
	move.w	d0,flight_airspeed

	; Distance is the high word of speed * integer frame delta, matching the
	; original's 8.8 position step at the scale visible to the scene.
	moveq	#0,d6
	move.w	flight_airspeed,d6
	move.w	flight_delta,d7
	mulu	d7,d6
	lsr.l	#8,d6

	; Vertical motion uses the full sine word and a 16.16 accumulator, matching
	; the DOS Y pair while exposing the integer high word to the HUD and scene.
	move.w	flight_pitch,d0
	bsr	flight_sin
	move.l	d6,d1
	muls	d0,d1
	add.l	d1,flight_altitude_accum
	move.l	flight_altitude_accum,d0
	swap	d0
	ext.l	d0
	move.w	d0,flight_altitude
	cmpi.w	#20,flight_altitude
	bge.s	.altitude_floor_ok
	move.w	#20,flight_altitude
	move.l	#(20<<16),flight_altitude_accum
.altitude_floor_ok
	cmpi.w	#16383,flight_altitude
	ble.s	.altitude_ceiling_ok
	move.w	#16383,flight_altitude
	move.l	#(16383<<16),flight_altitude_accum
.altitude_ceiling_ok

	; The vertical product above consumes d6. Rebuild the horizontal distance
	; from the same speed/delta high word before resolving heading.
	moveq	#0,d6
	move.w	flight_airspeed,d6
	move.w	flight_delta,d7
	mulu	d7,d6
	lsr.l	#8,d6

	; Heading accumulates the bank, scaled by the frame delta.
	move.w	flight_bank,d0
	muls	flight_delta,d0
	asr.l	#6,d0
	add.w	d0,flight_heading
	andi.w	#$7ff,flight_heading

	; Horizontal motion resolves distance through heading sine/cosine.
	move.w	flight_heading,d0
	bsr	flight_heading_sin
	ext.l	d0
	move.l	d0,d7
	move.w	flight_heading,d0
	bsr	flight_heading_cos
	ext.l	d0
	move.l	d0,d5

	move.l	d6,d0
	muls	d7,d0
	neg.l	d0
	add.l	d0,flight_world_x_accum

	move.l	d6,d0
	muls	d5,d0
	add.l	d0,flight_world_z_accum

	move.l	flight_world_x_accum,d0
	swap	d0
	ext.l	d0
	move.l	d0,flight_world_x
	move.l	flight_world_z_accum,d0
	swap	d0
	ext.l	d0
	move.l	d0,flight_world_z

	; Keep the scene's initial camera altitude as the origin and apply the
	; aircraft's relative climb. The renderer remains free to choose its view
	; angles, but its world position now follows the flight state.
	move.w	flight_altitude,d0
	sub.w	#3000,d0
	ext.l	d0
	add.l	flight_world_origin_y,d0
	move.l	d0,flight_world_y
	move.l	flight_world_x,scene_camera
	move.l	flight_world_y,scene_camera+4
	move.l	flight_world_z,scene_camera+8
	rts

; Convert flight angles into the renderer's tenths-of-a-degree camera
; convention. Heading 1024 is the DOS reset direction (due south), which is
; the renderer's zero view, so subtract 1800 from the yaw. This runs after
; move_camera in the main loop, making the arrow keys flight controls once the
; aircraft is active.
flight_sync_view
	tst.b	flight_active
	beq.s	.sync_view_return

	move.w	flight_pitch,d0
	ext.l	d0
	bpl.s	.pitch_angle_positive
	addi.l	#65536,d0
.pitch_angle_positive
	mulu	#225,d0
	lsr.l	#8,d0
	lsr.l	#4,d0
	move.w	d0,cam_view

	moveq	#0,d0
	move.w	flight_heading,d0
	mulu	#225,d0
	lsr.l	#7,d0
	subi.w	#1800,d0
	bpl.s	.heading_angle_positive
	addi.w	#3600,d0
.heading_angle_positive
	move.w	d0,cam_view+2

.sync_view_return
	rts

; d0.w = DOS 16-bit pitch/bank angle; d0.w = signed sine. The DOS helper at
; 0x5565 converts this form to an even byte offset into the 1024-entry table.
flight_sin
	lsr	#6,d0
	andi.w	#$3fe,d0
	lea	flight_sine,a0
	move.w	(a0,d0.w),d0
	rts

; d0.w = DOS 2048-step heading; d0.w = signed sine.
flight_heading_sin
	andi.w	#$7ff,d0
	lsr	#1,d0
	add.w	d0,d0
	lea	flight_sine,a0
	move.w	(a0,d0.w),d0
	rts

; d0.w = DOS 2048-step heading; d0.w = signed cosine. The original cosine is
; the sine table a quarter-circle (256 words) further on.
flight_heading_cos
	andi.w	#$7ff,d0
	lsr	#1,d0
	add.w	d0,d0
	lea	flight_sine+512,a0
	move.w	(a0,d0.w),d0
	rts

	bss

; DOS [0x347C] and [0x347B] equivalents.
flight_delta
	ds.w	1
flight_delta_88
	ds.w	1

flight_last_vbl
	ds.l	1

flight_speed_accum
	ds.l	1

; DOS aircraft state equivalents. The integer fields are the values consumed
; by the HUD and scene; position updates retain the original 16.16 precision
; in the accumulators below.
flight_airspeed
	ds.w	1
flight_altitude
	ds.w	1
flight_heading
	ds.w	1
flight_pitch
	ds.w	1
flight_bank
	ds.w	1
flight_pitch_command
	ds.w	1
flight_throttle
	ds.w	1
flight_load_factor
	ds.b	1
flight_input
	ds.b	1
flight_active
	ds.b	1
	even

flight_world_x
	ds.l	1
flight_world_y
	ds.l	1
flight_world_z
	ds.l	1
flight_world_origin_y
	ds.l	1
flight_world_x_accum
	ds.l	1
flight_altitude_accum
	ds.l	1
flight_world_z_accum
	ds.l	1

	end
