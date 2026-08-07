; -----------------------------------------------------------------------------
; Scene rendering
;
; The engine this port inherited draws one object: send its geometry to the DSP,
; get span lists back, fill them. A flight simulator needs a scene instead - a
; library of models and a few hundred instances placed across the world.
;
; The DSP side is unchanged, and deliberately so. It already transforms, clips,
; projects and BSP-sorts one object per call, and its memory is nowhere near
; large enough to hold a library of 299 models. So the scene work sits here:
; pick the instances in view, order them back to front, hand them to the DSP one
; at a time. The per-object BSP orders faces within an object, the distance sort
; orders the objects among themselves.
;
; File layout is documented in tools/re/scene2f29.py.
; -----------------------------------------------------------------------------

	global	scene_init, scene_render, scene_camera, scene_visible_count

	global	receive_data, draw_poly_hc_l, sincos, cam_view, colour_table, buffer
	global	work_screen

; -----------------------------------------------------------------------------

VIEW_RANGE		= 12000				; instances beyond this are skipped
MAX_VISIBLE		= 16				; how many we are willing to draw per frame

HDR_MODELS		= 4
HDR_INSTANCES	= 6
HDR_DIRECTORY	= 8
HDR_INSTANCES_AT = 12
HDR_CAMERA		= 16

DIR_OFFSET		= 0					; long
DIR_LENGTH		= 4					; long
DIR_POINTS		= 8					; word
DIR_NORMALS		= 10				; word
DIR_POLYGONS	= 12				; word
DIR_RADIUS		= 14				; word
DIR_SIZE		= 16

INST_MODEL		= 0					; word
INST_X			= 4					; long
INST_Y			= 8					; long
INST_Z			= 12				; long
INST_SIZE		= 16

; -----------------------------------------------------------------------------
	text
; -----------------------------------------------------------------------------

; a0.l = the loaded scene file
;
; Resolves the two file offsets into pointers once, so the per-frame path never
; looks at the header again.

scene_init
	move.l	a0,scene_data

	move	HDR_MODELS(a0),model_count
	move	HDR_INSTANCES(a0),instance_count

	move.l	HDR_DIRECTORY(a0),d0
	lea		(a0,d0.l),a1
	move.l	a1,directory

	move.l	HDR_INSTANCES_AT(a0),d0
	lea		(a0,d0.l),a1
	move.l	a1,instances

; Start the viewer where the scene is.  A theatre's scenery sits tens of
; thousands of units from the origin, so without this the first frame is an
; empty horizon.
	lea		HDR_CAMERA(a0),a1
	lea		scene_camera,a2
	move.l	(a1)+,(a2)+
	move.l	(a1)+,(a2)+
	move.l	(a1),(a2)

	rts

; -----------------------------------------------------------------------------
; Pick the instances in view and order them back to front.
;
; Reads scene_camera. Fills visible_list with distance and instance pointer
; pairs, and leaves the count in scene_visible_count.
;
; The distance is the squared horizontal separation. Comparing squares avoids a
; square root and orders identically; both terms are bounded by VIEW_RANGE, so
; the squares stay far inside 32 bits.

scene_cull
	movem.l	d0-d7/a0-a3,-(sp)

	lea		scene_camera,a0
	move.l	(a0),d5						; camera x
	move.l	8(a0),d7					; camera z

	move.l	instances,a1
	lea		visible_list,a2
	moveq	#0,d4						; kept so far

	move	instance_count,d6
	subq	#1,d6
	bmi		.sorted

.next
	move.l	INST_X(a1),d1
	sub.l	d5,d1						; dx
	move.l	d1,d2
	bpl.s	.dx_ok
	neg.l	d2
.dx_ok
	cmp.l	#VIEW_RANGE,d2
	bhi.s	.skip

	move.l	INST_Z(a1),d3
	sub.l	d7,d3						; dz
	move.l	d3,d2
	bpl.s	.dz_ok
	neg.l	d2
.dz_ok
	cmp.l	#VIEW_RANGE,d2
	bhi.s	.skip

	cmp		#MAX_VISIBLE,d4
	bge.s	.skip

	muls.l	d1,d1						; dx*dx
	muls.l	d3,d3						; dz*dz
	add.l	d3,d1

	move.l	d1,(a2)+
	move.l	a1,(a2)+
	addq	#1,d4

.skip
	lea		INST_SIZE(a1),a1
	dbra	d6,.next

; Insertion sort, farthest first. At most MAX_VISIBLE entries and nearly
; ordered from one frame to the next, so this is cheap and far simpler than
; anything cleverer.
	move	d4,d0
	subq	#2,d0
	bmi.s	.sorted

	lea		visible_list,a2
	moveq	#1,d1

.outer
	move	d1,d2
	lsl		#3,d2
	move.l	(a2,d2.w),d3				; key distance
	move.l	4(a2,d2.w),a3				; key instance
	move	d1,d5
	subq	#1,d5

.inner
	tst		d5
	bmi.s	.place
	move	d5,d2
	lsl		#3,d2
	move.l	(a2,d2.w),d6
	cmp.l	d3,d6
	bge.s	.place						; already farther, stop here
	move.l	d6,8(a2,d2.w)
	move.l	4(a2,d2.w),12(a2,d2.w)
	subq	#1,d5
	bra.s	.inner

.place
	addq	#1,d5
	move	d5,d2
	lsl		#3,d2
	move.l	d3,(a2,d2.w)
	move.l	a3,4(a2,d2.w)

	addq	#1,d1
	dbra	d0,.outer

.sorted
	move	d4,scene_visible_count
	movem.l	(sp)+,d0-d7/a0-a3
	rts

; -----------------------------------------------------------------------------
; Send one instance to the DSP.
;
; a6.l = model data, a4.l = one past its end
; d0/d1/d2 = point, normal and polygon counts
; d3/d4/d5 = position relative to the camera
;
; Mirrors send_data in f29.s, but takes geometry and transform as arguments
; rather than reading them from a single-object header. The camera position goes
; over as zero because the offset is already folded into the object position, so
; the DSP only has to rotate.

send_instance
	movem.l	d0-d7/a0-a6,-(sp)

	lea		$ffffa204.w,a0

.wait
	btst	#1,-2(a0)
	beq.s	.wait

	lea		sincos,a3
	lea		90*10*4(a3),a2				; the cosine quarter of the table

	move	d0,2(a0)
	move	d1,2(a0)
	move	d2,2(a0)

	add		d1,d0						; points and normals go over together
	subq	#1,d0

.geometry
	move.l	(a6)+,(a0)
	move.l	(a6)+,(a0)
	move.l	(a6)+,(a0)
	dbra	d0,.geometry

	addq	#2,a0

.faces
	move	(a6)+,(a0)
	cmp.l	a6,a4
	bne.s	.faces

	subq	#2,a0

	moveq	#0,d0						; camera position, folded in already
	move.l	d0,(a0)
	move.l	d0,(a0)
	move.l	d0,(a0)

	move.l	d3,(a0)						; object position
	move.l	d4,(a0)
	move.l	d5,(a0)

	moveq	#0,d0						; object rotation: none yet
	move.l	(a3,d0.w*4),(a0)
	move.l	(a3,d0.w*4),(a0)
	move.l	(a3,d0.w*4),(a0)
	move.l	(a2,d0.w*4),(a0)
	move.l	(a2,d0.w*4),(a0)
	move.l	(a2,d0.w*4),(a0)

	lea		cam_view,a5
	movem	(a5),d0-d2					; camera rotation

	move.l	(a3,d0.w*4),(a0)
	move.l	(a3,d1.w*4),(a0)
	move.l	(a3,d2.w*4),(a0)
	move.l	(a2,d0.w*4),(a0)
	move.l	(a2,d1.w*4),(a0)
	move.l	(a2,d2.w*4),(a0)

	movem.l	(sp)+,d0-d7/a0-a6
	rts

; -----------------------------------------------------------------------------
; Draw the scene into work_screen.
;
; One DSP round trip per visible instance: send the geometry and transform, take
; the span lists back, fill them, move on.

scene_render
	movem.l	d0-d7/a0-a6,-(sp)

	bsr		scene_cull

	move	scene_visible_count,d7
	subq	#1,d7
	bmi		.done

	lea		visible_list,a3

.instance
	move.l	4(a3),a1					; the instance
	addq.l	#8,a3

	moveq	#0,d0
	move	INST_MODEL(a1),d0
	mulu	#DIR_SIZE,d0
	move.l	directory,a2
	lea		(a2,d0.l),a2

	move.l	scene_data,a6
	move.l	DIR_OFFSET(a2),d0
	lea		(a6,d0.l),a6				; model data
	move.l	a6,a4
	move.l	DIR_LENGTH(a2),d0
	lea		(a4,d0.l),a4				; one past its end

	moveq	#0,d0
	move	DIR_POINTS(a2),d0
	moveq	#0,d1
	move	DIR_NORMALS(a2),d1
	moveq	#0,d2
	move	DIR_POLYGONS(a2),d2

	lea		scene_camera,a5
	move.l	INST_X(a1),d3
	sub.l	(a5),d3
	move.l	INST_Y(a1),d4
	sub.l	4(a5),d4
	move.l	INST_Z(a1),d5
	sub.l	8(a5),d5

	movem.l	d7/a3,-(sp)
	bsr		send_instance

	lea		buffer,a1
	lea		colour_table,a2
	bsr		receive_data

	move.l	work_screen,a0
	lea		buffer,a1
	bsr		draw_poly_hc_l
	movem.l	(sp)+,d7/a3

	dbra	d7,.instance

.done
	movem.l	(sp)+,d0-d7/a0-a6
	rts

; -----------------------------------------------------------------------------
	data
; -----------------------------------------------------------------------------

scene_visible_count
	dc		0

; Where the camera stands, in world units. The demo's own camera angles in
; cam_view supply the orientation.
scene_camera
	dc.l	0, -400, 0

; -----------------------------------------------------------------------------
	bss
; -----------------------------------------------------------------------------

scene_data
	ds.l	1
directory
	ds.l	1
instances
	ds.l	1
model_count
	ds.w	1
instance_count
	ds.w	1

visible_list
	ds.l	2*MAX_VISIBLE

	end
