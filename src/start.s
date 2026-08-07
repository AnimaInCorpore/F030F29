; start code (c) 1994 by Sascha Springer

	include "inc/bios.s"
	include "inc/xbios.s"
	include "inc/gemdos.s"

	global _main
	global	work_screen, display_screen, screen, scene_loaded

SCREEN_WIDTH = 320
SCREEN_HEIGHT = 240

MAX_MODEL_DATA_SIZE = $20000
MAX_SCENE_SIZE = $60000

	text

_main
	Dsp_Reserve #16000,#16000
	tst		d0
	bmi		exit

	Dsp_LoadProgram lod_filename,#3,dsp_buffer
	tst		d0
	beq		start

	Cconws	error_text
	Cconin

	bra		exit

start
    Fopen   model_filename,#0
    move    d0,d7
    bmi     .no_object

    Fread   d7,#MAX_MODEL_DATA_SIZE,model_data
	move.l	#model_data,object
	move.l	#model_data,object+4
	add.l	d0,object+4

    Fclose  d7

.no_object
; The scene is what the game actually draws: a model library plus the instances
; placed across the world.  Without it the loop falls back to the single object
; above, which is how a model can still be checked in isolation.
	Fopen   scene_filename,#0
	move    d0,d7
	bmi     .no_scene

	Fread   d7,#MAX_SCENE_SIZE,scene_buffer
	Fclose  d7

	lea		scene_buffer,a0
	bsr		scene_init
	st		scene_loaded

.no_scene
	bsr		init

	bsr		main

	bsr		deinit

exit
	Pterm0

init
	move.l	#screen,d0
	add.l	#$ff,d0
	clr.b	d0
	move.l	d0,work_screen
	move.l	d0,d1
	add.l	#SCREEN_WIDTH*SCREEN_HEIGHT*2,d1
	move.l	d1,display_screen

	Super 0
	move.l	d0,savssp

	move	#$2700,sr

	lea		$ffff9800.w,a0
	lea		old_palette,a1

	move	#256-1,d7

i_copy_pal
	move.l	(a0)+,(a1)+
	dbra	d7,i_copy_pal

	clr.l	$ffff9800.w

	move.b	$ffff8201.w,old_screen+1
	move.b	$ffff8203.w,old_screen+2
	move.b	$ffff820d.w,old_screen+3

	move.l	$ffff820e.w,d0
	move.l	$ffff8264.w,d1
	movem.l	$ffff8282.w,d2-d5
	movem.l	$ffff82a2.w,d6-a0
	move.l	$ffff82c0.w,a1
	move	$ffff820a.w,a2
	movem.l	d0-a2,old_videl

	move.b	$fffffa07.w,old_fa07
	move.b	$fffffa09.w,old_fa09
	move.b	$fffffa13.w,old_fa13
	move.b	$fffffa15.w,old_fa15

	move.l	$118.w,old_keyboard
	move.l	$70.w,old_vbl

	bclr	#3,$fffffa17.w

	clr.b	$fffffa07.w
	clr.b	$fffffa09.w
	clr.b	$fffffa13.w
	clr.b	$fffffa15.w

	move.l	#vbl,$70.w

	move.l	#keyboard,$118.w
	bset	#6,$fffffa09.w
	bset	#6,$fffffa15.w

; 320x240 true colour, two bytes per pixel.  Bit 6 of $ffff8006 is the monitor
; type: clear means a VGA monitor, which needs doubled scan lines to reach 240
; visible lines, set means RGB/TV at roughly 15 kHz.  Register values taken
; from the F030Arcade ports, which run this mode on real hardware.
	btst	#6,$ffff8006.w
	beq		.set_vga_mode

	move.l	#$10800b1,$ffff8282.w
	move.l	#$3b001a,$ffff8286.w
	move.l	#$b100e3,$ffff828a.w
	move.l	#$1f601ec,$ffff82a2.w
	move.l	#$c000c,$ffff82a6.w
	move.l	#$1ec01f0,$ffff82aa.w
	move.w	#$200,$ffff820a.w
	move.w	#$181,$ffff82c0.w
	clr.w	$ffff8266.w
	move.w	#$100,$ffff8266.w
	move.w	#$0,$ffff82c2.w
	bra		.video_ready

.set_vga_mode
	move.l	#$fc00a9,$ffff8282.w
	move.l	#$2502f3,$ffff8286.w
	move.l	#$a800c0,$ffff828a.w
	move.l	#$41a0406,$ffff82a2.w
	move.l	#$460046,$ffff82a6.w
	move.l	#$4060416,$ffff82aa.w
	move.w	#$200,$ffff820a.w
	move.w	#$182,$ffff82c0.w
	clr.w	$ffff8266.w
	move.w	#$100,$ffff8266.w
	move.w	#$5,$ffff82c2.w

.video_ready
; Line width in words, and no virtual stride - the buffers are exactly the
; visible area, so the line offset is zero.
	move.w	#SCREEN_WIDTH,$ffff8210.w
	clr.w	$ffff820e.w

	move	#$2300,sr

	rts

deinit
	move	#$2700,sr

	clr		$ffff820e.w
	clr.b	$ffff8265.w

	lea		old_palette,a0
	lea		$ffff9800.w,a1

	move	#256-1,d7

di_copy_pal
	move.l	(a0)+,(a1)+
	dbra	d7,di_copy_pal

	move.b	old_fa07,$fffffa07.w
	move.b	old_fa09,$fffffa09.w
	move.b	old_fa13,$fffffa13.w
	move.b	old_fa15,$fffffa15.w

	move.l	old_keyboard,$118.w
	move.l	old_vbl,$70.w

	Vsync
	move.b	old_screen+1,$ffff8201.w
	move.b	old_screen+2,$ffff8203.w
	move.b	old_screen+3,$ffff820d.w

	movem.l	old_videl,d0-a2
	move.l	d0,$ffff820e.w
	move.l	d1,$ffff8264.w
	movem.l	d2-d5,$ffff8282.w
	movem.l	d6-a0,$ffff82a2.w
	move.l	a1,$ffff82c0.w
	move	a2,$ffff820a.w

	move	#$2300,sr

	move.l	savssp,a0
	Super (a0)

	rts

	data

error_text
	dc.b	27,'E',10,13
	dc.b	'Error: LOD file not found or ',10,13
	dc.b	'DSP access failed!',10,13
	dc.b	10,13
	dc.b	10,13
	dc.b	10,13
	dc.b	' Press SPACE to return to desktop...',10,13
	dc.b	0

lod_filename
	dc.b    '3d.lod',0

model_filename
	dc.b    'model.o3d',0

scene_filename
	dc.b    'scene.f29',0

	even

	bss

scene_loaded
	ds.b	1
	even

savssp
	ds.l	1

old_screen
	ds.l	1
old_palette
	ds.l	256
old_videl
	ds.l	11

old_fa07
	ds.b	1
old_fa09
	ds.b	1
old_fa13
	ds.b	1
old_fa15
	ds.b	1

old_vbl
	ds.l	1
old_keyboard
	ds.l	1

dsp_buffer
	ds.l	10000

work_screen
	ds.l	1
display_screen
	ds.l	1

; Two buffers of SCREEN_WIDTH*SCREEN_HEIGHT*2 bytes, plus slack either side so
; the 256-byte alignment in init has room and an overrunning span cannot walk
; into anything that matters.
	ds.b	4096
screen
	ds.b	SCREEN_WIDTH*SCREEN_HEIGHT*2*2
	ds.b	4096

model_data
	ds.b	MAX_MODEL_DATA_SIZE

scene_buffer
	ds.b	MAX_SCENE_SIZE

	end
