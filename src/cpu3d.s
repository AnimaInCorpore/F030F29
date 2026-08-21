; -----------------------------------------------------------------------------
; 68030-only 3D pipeline (transform, clip, project, depth-sort)
; -----------------------------------------------------------------------------
;
; Phase 1 of the port: replaces the DSP56001 round trip (src/dsp/3d.asm,
; parked untouched for phase 2) with the equivalent geometry work done
; directly on the 68030. Feeds draw_poly_hc_l (src/dp_hc.s) exactly the
; buffer format it already reads from the DSP today - that routine does not
; change at all, and its wire format was proven correct against a
; hand-written buffer before any of this was written. See docs/CPU3D.md
; once it exists; docs/ARCHITECTURE.md for the phase 1/phase 2 split.
;
; Built up one pipeline stage at a time, each verified numerically before
; the next is written on top of it - see the build order in the approved
; plan. This file currently has the rotation matrix and per-vertex
; transform stages.
;
; Fixed point: Q1.23 throughout (same convention as sincos.s and the DSP
; source being ported from - full scale +-1.0 = 0x7FFFFF/0x800001). One
; shared multiply, cpu3d_qmul, serves both "Q1.23 x Q1.23 -> Q1.23" (the
; rotation matrix build, every input a trig value) and "plain integer x
; Q1.23 -> plain integer" (the per-vertex transform, x/y/z are world-unit
; integers, the matrix entries are Q1.23) without needing two versions:
; shifting a 64-bit product right by 23 only removes the scale factor a
; caller actually applied - if just one of the two operands was pre-scaled
; by 2^23 (the trig value, or the matrix entry), the shift correctly
; recovers a result in the OTHER operand's scale, whatever that was.
; -----------------------------------------------------------------------------
	global	cpu3d_rotation_matrix, cpu3d_matrix_multiply, cpu3d_transform
	global	cpu3d_bsp_emit, cpu3d_polygon_sorted
	global	cpu3d_clip3d, cpu3d_project
	global	cpu3d_clip2d

; -----------------------------------------------------------------------------
	text
; -----------------------------------------------------------------------------

; d0.l * d1.l -> d0.l (Q1.23 x Q1.23 -> Q1.23, or plain-int x Q1.23 ->
; plain-int - see the file header). trashes d1,d2

cpu3d_qmul
	muls.l	d1,d2:d0
	moveq	#23,d1
	lsr.l	d1,d0
	moveq	#9,d1
	lsl.l	d1,d2
	or.l	d2,d0
	rts

; -----------------------------------------------------------------------------
; Builds one 3x3 rotation matrix from an angle triple, the 9-term closed
; form src/dsp/3d.asm's make_rotation_matrix uses (verified directly against
; that source): row-major A..I,
;
;   A=cy*cz        B=cy*sz        C=-sy
;   D=sx*sy*cz-cx*sz   E=sx*sy*sz+cx*cz   F=sx*cy
;   G=cx*sy*cz+sx*sz   H=cx*sy*sz-sx*cz   I=cx*cy
;
; a0.l = angle triple (3 words: x,y,z angle, 0..3599 tenths of a degree,
;        sincos.s convention)
; a1.l = output: 9 longs Q1.23, row-major A..I
; trashes d0-d7/a2-a4
; -----------------------------------------------------------------------------

CX = 0
CY = 4
CZ = 8
SX = 12
SY = 16
SZ = 20

cpu3d_rotation_matrix
	lea		sincos,a2
	lea		900*4(a2),a3
	lea		cpu3d_scratch_trig,a4

	move.w	(a0),d0				; x angle
	move.l	(a3,d0.w*4),CX(a4)
	move.l	(a2,d0.w*4),SX(a4)

	move.w	2(a0),d0			; y angle
	move.l	(a3,d0.w*4),CY(a4)
	move.l	(a2,d0.w*4),SY(a4)

	move.w	4(a0),d0			; z angle
	move.l	(a3,d0.w*4),CZ(a4)
	move.l	(a2,d0.w*4),SZ(a4)

; A = cy*cz
	move.l	CY(a4),d0
	move.l	CZ(a4),d1
	bsr		cpu3d_qmul
	move.l	d0,(a1)+

; B = cy*sz
	move.l	CY(a4),d0
	move.l	SZ(a4),d1
	bsr		cpu3d_qmul
	move.l	d0,(a1)+

; C = -sy
	move.l	SY(a4),d0
	neg.l	d0
	move.l	d0,(a1)+

; D = sx*sy*cz - cx*sz
	move.l	SX(a4),d0
	move.l	SY(a4),d1
	bsr		cpu3d_qmul
	move.l	CZ(a4),d1
	bsr		cpu3d_qmul
	move.l	d0,d3
	move.l	CX(a4),d0
	move.l	SZ(a4),d1
	bsr		cpu3d_qmul
	move.l	d3,d1
	sub.l	d0,d1
	move.l	d1,(a1)+

; E = sx*sy*sz + cx*cz
	move.l	SX(a4),d0
	move.l	SY(a4),d1
	bsr		cpu3d_qmul
	move.l	SZ(a4),d1
	bsr		cpu3d_qmul
	move.l	d0,d3
	move.l	CX(a4),d0
	move.l	CZ(a4),d1
	bsr		cpu3d_qmul
	add.l	d3,d0
	move.l	d0,(a1)+

; F = sx*cy
	move.l	SX(a4),d0
	move.l	CY(a4),d1
	bsr		cpu3d_qmul
	move.l	d0,(a1)+

; G = cx*sy*cz + sx*sz
	move.l	CX(a4),d0
	move.l	SY(a4),d1
	bsr		cpu3d_qmul
	move.l	CZ(a4),d1
	bsr		cpu3d_qmul
	move.l	d0,d3
	move.l	SX(a4),d0
	move.l	SZ(a4),d1
	bsr		cpu3d_qmul
	add.l	d3,d0
	move.l	d0,(a1)+

; H = cx*sy*sz - sx*cz
	move.l	CX(a4),d0
	move.l	SY(a4),d1
	bsr		cpu3d_qmul
	move.l	SZ(a4),d1
	bsr		cpu3d_qmul
	move.l	d0,d3
	move.l	SX(a4),d0
	move.l	CZ(a4),d1
	bsr		cpu3d_qmul
	move.l	d3,d1
	sub.l	d0,d1
	move.l	d1,(a1)+

; I = cx*cy
	move.l	CX(a4),d0
	move.l	CY(a4),d1
	bsr		cpu3d_qmul
	move.l	d0,(a1)+

	rts

; -----------------------------------------------------------------------------
; Combines two rotation matrices: combined = object x camera (row x column,
; object matrix left-multiplied), matching src/dsp/3d.asm's
; make_rotation_matrix - object's own orientation is applied first, then the
; camera's, when the combined matrix is later used by cpu3d_transform.
;
; a0.l = object matrix (9 longs Q1.23, row-major A..I, preserved)
; a1.l = camera matrix (9 longs Q1.23, row-major A..I, preserved)
; a2.l = output: combined matrix (9 longs Q1.23, row-major A..I)
; trashes d0-d7
; -----------------------------------------------------------------------------

cpu3d_matrix_multiply
	moveq	#0,d7				; i = 0..2 (row)
.row_loop
	moveq	#0,d6				; j = 0..2 (col)
.col_loop
	moveq	#0,d5				; accumulator
	moveq	#0,d4				; k = 0..2

.k_loop
	move.l	d7,d0
	mulu	#3,d0
	add.l	d4,d0
	move.l	(a0,d0.l*4),d0		; object[i][k]

	move.l	d4,d1
	mulu	#3,d1
	add.l	d6,d1
	move.l	(a1,d1.l*4),d1		; camera[k][j]

	bsr		cpu3d_qmul
	add.l	d0,d5

	addq	#1,d4
	cmp.b	#3,d4
	blt		.k_loop

	move.l	d5,(a2)+

	addq	#1,d6
	cmp.b	#3,d6
	blt		.col_loop

	addq	#1,d7
	cmp.b	#3,d7
	blt		.row_loop

	rts

; -----------------------------------------------------------------------------
; Transforms N points (or normals): out = in * matrix + offset. Called once
; for points (offset = object position) and once for normals (offset =
; zero vector) - normals rotate but never translate, matching
; src/dsp/3d.asm's rotate_translate.
;
; a0.l = source array (3 longs/entry: x,y,z), consumed
; a1.l = dest array (3 longs/entry), consumed - may equal a0
; a2.l = offset vector (3 longs: xoff,yoff,zoff), preserved
; a3.l = 3x3 matrix (9 longs Q1.23, row-major A..I), preserved
; d0.w = entry count (> 0)
; trashes d0-d7/a0-a1
; -----------------------------------------------------------------------------

cpu3d_transform
	subq	#1,d0
	move	d0,d7

.entry_loop
	move.l	(a0)+,d4			; x
	move.l	(a0)+,d5			; y
	move.l	(a0)+,d6			; z

; x' = x*A + y*B + z*C + xoff
	move.l	d4,d0
	move.l	(a3),d1
	bsr		cpu3d_qmul
	move.l	d0,d3
	move.l	d5,d0
	move.l	4(a3),d1
	bsr		cpu3d_qmul
	add.l	d0,d3
	move.l	d6,d0
	move.l	8(a3),d1
	bsr		cpu3d_qmul
	add.l	d0,d3
	add.l	(a2),d3
	move.l	d3,(a1)+

; y' = x*D + y*E + z*F + yoff
	move.l	d4,d0
	move.l	12(a3),d1
	bsr		cpu3d_qmul
	move.l	d0,d3
	move.l	d5,d0
	move.l	16(a3),d1
	bsr		cpu3d_qmul
	add.l	d0,d3
	move.l	d6,d0
	move.l	20(a3),d1
	bsr		cpu3d_qmul
	add.l	d0,d3
	add.l	4(a2),d3
	move.l	d3,(a1)+

; z' = x*G + y*H + z*I + zoff
	move.l	d4,d0
	move.l	24(a3),d1
	bsr		cpu3d_qmul
	move.l	d0,d3
	move.l	d5,d0
	move.l	28(a3),d1
	bsr		cpu3d_qmul
	add.l	d0,d3
	move.l	d6,d0
	move.l	32(a3),d1
	bsr		cpu3d_qmul
	add.l	d0,d3
	add.l	8(a2),d3
	move.l	d3,(a1)+

	dbra	d7,.entry_loop

	rts

; -----------------------------------------------------------------------------
; Walks the BSP tree already baked into the polygon records at asset-convert
; time (tools/re/model2o3d.py) - this routine only decides traversal order
; and culls, it never builds a tree. Plain recursive bsr/rts: the DSP hand-
; rolls its own software stack only because DSP56001's hardware call stack
; is a few words deep; 68030 has a real one.
;
; Record layout (byte offsets, verified against src/dsp/3d.asm's
; sort_polygon_bsp by tracing its address arithmetic instruction by
; instruction against tools/re/model2o3d.py's Face.word_size()/convert()):
;
;   +0  word  corner count
;   +2  word  colour*32
;   +4  word  normal-ref     (point/normal array byte offset = value*4)
;   +6  word  back-link      (0 = none; else record's own byte offset,
;   +8  word  front-link      biased +3 in the stored value - see below)
;  +10  word[count]  point indices (byte offset = value*4, same array)
;
; The stored back/front-link value, when nonzero, equals the target
; record's own byte-offset-within-the-array, word-divided then +3 - i.e.
; target_byte_offset = (stored_value - 3) * 2. The +3 bias and the root
; always sitting at byte offset 0 are both properties of the stored file
; format (tools/re/model2o3d.py), not a convention this routine is free to
; change - only the zero-sentinel check has to happen on the raw stored
; value, before that conversion, since 0 is also the root's own (converted)
; offset.
;
; a0.l = polygon array base (root at byte offset 0), preserved
; a1.l = point/normal array base (transformed, points then normals -
;        cpu3d_transform's output layout), preserved
; a2.l = output cursor (cpu3d_polygon_sorted-shaped buffer), advances
; a3.l = current node's address (a0 + byte offset), preserved
; trashes d0-d7/a4-a6
; -----------------------------------------------------------------------------

cpu3d_bsp_emit
	moveq	#0,d1
	move.w	4(a3),d1			; normal-ref
	lsl.l	#2,d1
	lea		(a1,d1.l),a5		; a5 = normal address

	moveq	#0,d1
	move.w	10(a3),d1			; point0-ref (first corner)
	lsl.l	#2,d1
	lea		(a1,d1.l),a4		; a4 = point0 address

; visibility: dot = (viewer_position - point0) . normal
	move.l	cpu3d_viewer_position,d0
	sub.l	(a4),d0
	move.l	(a5),d1
	bsr		cpu3d_qmul
	move.l	d0,d6

	move.l	cpu3d_viewer_position+4,d0
	sub.l	4(a4),d0
	move.l	4(a5),d1
	bsr		cpu3d_qmul
	add.l	d0,d6

	move.l	cpu3d_viewer_position+8,d0
	sub.l	8(a4),d0
	move.l	8(a5),d1
	bsr		cpu3d_qmul
	add.l	d0,d6

	tst.l	d6
	bmi		.backfacing

; front-facing: back child, emit this polygon, front child - the order that
; produces back-to-front painter's order.
	move.l	a3,-(sp)
	moveq	#0,d0
	move.w	6(a3),d0			; back-link, raw stored value
	beq		.no_back1
	subq	#3,d0
	add.w	d0,d0
	lea		(a0,d0.l),a3
	bsr		cpu3d_bsp_emit
.no_back1
	move.l	(sp)+,a3

	bsr		cpu3d_bsp_emit_one

	moveq	#0,d0
	move.w	8(a3),d0			; front-link, raw stored value
	beq		.no_front1
	subq	#3,d0
	add.w	d0,d0
	lea		(a0,d0.l),a3
	bsr		cpu3d_bsp_emit
.no_front1
	rts

.backfacing
; the tree partitions all faces, not just visible ones - both children are
; still visited, nothing is emitted either way.
	move.l	a3,-(sp)
	moveq	#0,d0
	move.w	8(a3),d0			; front-link, raw stored value
	beq		.no_front2
	subq	#3,d0
	add.w	d0,d0
	lea		(a0,d0.l),a3
	bsr		cpu3d_bsp_emit
.no_front2
	move.l	(sp)+,a3
	moveq	#0,d0
	move.w	6(a3),d0			; back-link, raw stored value
	beq		.no_back2
	subq	#3,d0
	add.w	d0,d0
	lea		(a0,d0.l),a3
	bsr		cpu3d_bsp_emit
.no_back2
	rts

; -----------------------------------------------------------------------------
; Emits one polygon: corner count, lit colour, then corner_count+1 corner
; coordinates (the first corner repeated at the end, so the 2D clip/edge
; stages can walk consecutive pairs as edges with no special-cased wrap).
;
; Lighting: palette_index = colour_field + (-(N.L)*16 + 16), matching
; src/dsp/3d.asm's sort_polygon_bsp - L is a fixed constant, used as-is,
; never rotated; only the (already-rotated) normal moves.
;
; a0.l = polygon array base, preserved (unused here but kept for symmetry
;        with cpu3d_bsp_emit's convention)
; a1.l = point/normal array base, preserved
; a2.l = output cursor, advances
; a3.l = node to emit, preserved
; trashes d0-d7/a4-a6
; -----------------------------------------------------------------------------

cpu3d_bsp_emit_one
	moveq	#0,d7
	move.w	(a3),d7				; corner count
	move.w	d7,(a2)+

	moveq	#0,d1
	move.w	4(a3),d1			; normal-ref
	lsl.l	#2,d1
	lea		(a1,d1.l),a5		; a5 = normal address

	move.l	cpu3d_light_vector,d0
	move.l	(a5),d1
	bsr		cpu3d_qmul
	move.l	d0,d6
	move.l	cpu3d_light_vector+4,d0
	move.l	4(a5),d1
	bsr		cpu3d_qmul
	add.l	d0,d6
	move.l	cpu3d_light_vector+8,d0
	move.l	8(a5),d1
	bsr		cpu3d_qmul
	add.l	d0,d6

; shade = -(N.L)*16 + 16. The DSP source computes this with mac, which is
; natively Q1.23-fractional - "*16" there is not a plain integer shift, it
; still needs the same >>23 descaling qmul does, or the result is off by a
; factor of 2^23 (caught numerically: the naive asl.l version gave a
; palette index in the tens of millions instead of a handful).
	move.l	d6,d0
	moveq	#16,d1
	bsr		cpu3d_qmul
	neg.l	d0
	add.l	#16,d0
	move.l	d0,d6

	moveq	#0,d0
	move.w	2(a3),d0			; colour*32
	add.l	d6,d0
	move.w	d0,(a2)+

	lea		10(a3),a4			; walks the point-index list
	move.w	d7,d5

.copy_loop
	moveq	#0,d1
	move.w	(a4)+,d1
	lsl.l	#2,d1
	lea		(a1,d1.l),a5
	move.l	(a5)+,(a2)+
	move.l	(a5)+,(a2)+
	move.l	(a5),(a2)+
	subq	#1,d5
	bne		.copy_loop

	moveq	#0,d1				; repeat corner 0 to close the loop
	move.w	10(a3),d1
	lsl.l	#2,d1
	lea		(a1,d1.l),a5
	move.l	(a5)+,(a2)+
	move.l	(a5)+,(a2)+
	move.l	(a5),(a2)+

	rts

; -----------------------------------------------------------------------------
; Clips each polygon against the camera-space z=0 plane (single plane only -
; matching src/dsp/3d.asm's clip_polygon_3d, the only 3D clip this pipeline
; does; the screen rectangle is handled later, in 2D). Walks the n edges of
; each n-corner input polygon using the n+1 stored corners (already
; wrap-closed by cpu3d_bsp_emit), exactly the Sutherland-Hodgman single-
; plane rule: a point in front (z>=0) is kept, a point behind is dropped,
; and an edge that crosses the plane contributes one linearly-interpolated
; point at the crossing - verified against the DSP source instruction by
; instruction, register mechanics aside (that version threads point
; *indices* through a separate array since it inherited the file's
; index-based polygon format; this one already carries full coordinates
; inline per cpu3d_bsp_emit's own output format, so there is no index
; scheme to mirror).
;
; A convex polygon can only cross a single plane at exactly two edges, so
; clipping can grow the corner count by at most 1 - never shrinks the
; *buffer* below what cpu3d_bsp_emit already needed.
;
; a0.l = input polygon list (cpu3d_bsp_emit's output format: per polygon,
;        word count, word colour, then (count+1) sets of {long x,y,z}),
;        consumed
; a1.l = output polygon list (same format, z=0-plane-clipped), advances
; d0.w = number of input polygons (> 0)
; trashes d0-d7/a0-a6
; -----------------------------------------------------------------------------

; d3/d7 deliberately unused for anything that needs to survive a call to
; cpu3d_clip3d_interp: that routine needs d0-d3 and d7 itself (a 64-bit
; multiply/divide plus a qmul chain), so any loop counter living in those
; registers gets silently overwritten mid-polygon - a first version of this
; routine had exactly that bug (edge and polygon counters both in d3/d7),
; caught numerically: the emitted corner count came out as an unrelated
; large number instead of 3. Both counters live in memory instead now, so
; there is no register left for a callee to clobber by accident.

cpu3d_clip3d
	move.w	d0,cpu3d_clip3d_poly_count

.poly_loop
	move.w	(a0)+,d6			; input corner count (n)
	move.w	(a0)+,d5			; colour

	move.l	a1,a2				; a2 -> this output record's count field
	clr.w	(a1)+
	move.w	d5,(a1)+
	moveq	#0,d4				; output corner count so far

	move.w	d6,cpu3d_clip3d_edge_count
.edge_loop
	move.l	a0,a3				; a3 -> P0 (this edge's near-side candidate)
	lea		12(a0),a4			; a4 -> P1

	tst.l	8(a3)				; P0z
	bmi		.p0_behind

	move.l	(a3),(a1)+			; P0 is in front - keep it as-is
	move.l	4(a3),(a1)+
	move.l	8(a3),(a1)+
	addq	#1,d4

	tst.l	8(a4)				; P1z
	bpl		.no_cross1			; both in front - no crossing on this edge
	bsr		cpu3d_clip3d_interp	; near=P0(a3), far=P1(a4)
	addq	#1,d4
.no_cross1
	bra		.next_edge

.p0_behind
	tst.l	8(a4)				; P1z
	bmi		.next_edge			; both behind - discard, emit nothing

	exg		a3,a4				; near=P1, far=P0 - same interp helper
	bsr		cpu3d_clip3d_interp
	addq	#1,d4

.next_edge
	lea		12(a0),a0
	subq.w	#1,cpu3d_clip3d_edge_count
	bne		.edge_loop

	lea		12(a0),a0			; skip the (n+1)'th stored corner - already
								; consumed as "far" on the last edge, never
								; re-read as a "near" candidate of its own

	move.w	d4,(a2)				; patch in the real output corner count

	tst.w	d4
	beq		.no_repeat			; nothing survived - nothing to close
	lea		4(a2),a5			; a5 -> first emitted corner
	move.l	(a5)+,(a1)+
	move.l	(a5)+,(a1)+
	move.l	(a5),(a1)+			; repeat it, closing the loop for cpu3d_project
.no_repeat

	subq.w	#1,cpu3d_clip3d_poly_count
	bne		.poly_loop

	rts

; -----------------------------------------------------------------------------
; Linearly interpolates the z=0 crossing point between a "near" (in front,
; z>=0) and a "far" (behind, z<0) point, and appends it to the output.
; F = nearz/(nearz-farz); result = F*(far-near)+near per axis - verified to
; match both edge directions cpu3d_clip3d needs just by which point is
; passed as near vs far (see src/dsp/3d.asm's cp3d_clip and its P0-front
; counterpart, which are the same formula with P0/P1 swapped).
;
; a3.l = near point address (x,y,z consecutive longs), preserved
; a4.l = far point address (same layout), preserved
; a1.l = output cursor, advances by 12 (writes x,y,z)
; trashes d0-d3,d7
; -----------------------------------------------------------------------------

cpu3d_clip3d_interp
	move.l	8(a3),d0			; nearz
	move.l	#$800000,d1
	muls.l	d1,d3:d0			; d3:d0 = nearz * 2^23 (64-bit)
	move.l	8(a3),d1
	sub.l	8(a4),d1			; nearz - farz
	divs.l	d1,d3:d0			; d0 = F, Q1.23 - divs.l, NOT divsl.l: the
								; extra "l" is a genuinely different
								; instruction (32-bit dividend in Dq alone,
								; Dr for the remainder only) that happens to
								; give the same answer when the dividend
								; fits in 32 bits and a silently wrong one
								; when it doesn't - caught numerically, see
								; cpu3d_project_axis's identical fix
								; (see cpu3d_qmul's header for why the 2^23
								; pre-scale, undone by qmul below, is what
								; makes F a Q1.23 fraction at all)
	move.l	d0,d7				; d7 = F, held across the three qmul calls

	move.l	(a4),d2
	sub.l	(a3),d2				; farx - nearx
	move.l	d7,d0
	move.l	d2,d1
	bsr		cpu3d_qmul
	add.l	(a3),d0
	move.l	d0,(a1)+

	move.l	4(a4),d2
	sub.l	4(a3),d2
	move.l	d7,d0
	move.l	d2,d1
	bsr		cpu3d_qmul
	add.l	4(a3),d0
	move.l	d0,(a1)+

	move.l	8(a4),d2
	sub.l	8(a3),d2
	move.l	d7,d0
	move.l	d2,d1
	bsr		cpu3d_qmul
	add.l	8(a3),d0
	move.l	d0,(a1)+

	rts

; -----------------------------------------------------------------------------
; Perspective projection: Px = (Zx*Qz-Qx*Zz)/(Qz-Zz), Py = (Zy*Qz-Qy*Zz)/
; (Qz-Zz), where Q is a camera-space point and Z is cpu3d_viewer_position -
; a combined screen-centre/focal-distance dummy, not a separate value per
; axis (matches src/dsp/3d.asm's convert_3d_to_2d, sign-juggling around its
; div instruction aside - that dance is specific to the DSP's division
; requirements; 68030's divs.l handles signed division natively). No
; zero-divisor guard: cpu3d_clip3d already guarantees Qz>=0 for every
; surviving point, and the viewer's z (-300) keeps Qz-Zz comfortably
; positive - the same implicit assumption the DSP version makes, not a new
; one.
;
; Walks the same per-polygon structure cpu3d_clip3d outputs (count, colour,
; corners) rather than a flat point list, so each stage's interface stays
; polygon-shaped end to end. Drops z - only x,y (now plain screen-pixel
; integers, not Q1.23) survive into the output.
;
; a0.l = input polygon list (cpu3d_clip3d's output format), consumed
; a1.l = output polygon list (word count, word colour, then (count+1) sets
;        of {long x, long y} screen coordinates), advances
; d0.w = number of input polygons (> 0)
; trashes d0-d7/a0-a6
;
; cpu3d_project_axis trashes d1-d7, so - same lesson as cpu3d_clip3d just
; above, caught the same way, by the corner count coming out wrong - neither
; loop counter here can live in a data register across a call to it. Both
; live in memory instead.
; -----------------------------------------------------------------------------

cpu3d_project
	move.w	d0,cpu3d_project_poly_count

.poly_loop
	move.w	(a0)+,d6			; corner count (n)
	move.w	d6,(a1)+
	move.w	(a0)+,(a1)+			; colour, passed through unchanged

	addq.w	#1,d6				; n+1 stored corners
	move.w	d6,cpu3d_project_corner_count

.corner_loop
	move.l	cpu3d_viewer_position,d0
	move.l	(a0),d1				; Qx
	move.l	8(a0),d2			; Qz
	move.l	cpu3d_viewer_position+8,d3
	bsr		cpu3d_project_axis
	move.l	d0,(a1)+

	move.l	cpu3d_viewer_position+4,d0
	move.l	4(a0),d1			; Qy
	move.l	8(a0),d2			; Qz
	move.l	cpu3d_viewer_position+8,d3
	bsr		cpu3d_project_axis
	move.l	d0,(a1)+

	lea		12(a0),a0
	subq.w	#1,cpu3d_project_corner_count
	bne		.corner_loop

	subq.w	#1,cpu3d_project_poly_count
	bne		.poly_loop

	rts

; -----------------------------------------------------------------------------
; result = (za*qz - qa*zz) / (qz-zz), the shared shape of both the Px and Py
; formulas - one axis (Zx/Qx or Zy/Qy) per call.
;
; d0.l = za, d1.l = qa, d2.l = qz, d3.l = zz
; returns d0.l = projected integer coordinate
; trashes d1-d7
; -----------------------------------------------------------------------------

cpu3d_project_axis
	move.l	d2,d6
	sub.l	d3,d6				; d6 = denom = qz - zz

	muls.l	d3,d7:d1			; d7:d1 = qa * zz (d1 already held qa)

	move.l	d2,d5				; d5 = qz
	muls.l	d0,d4:d5			; d4:d5 = za * qz (d5 already held qz)

	sub.l	d1,d5
	subx.l	d7,d4				; d4:d5 -= d7:d1 (64-bit subtract)

	move.l	d6,d1
	divs.l	d1,d4:d5			; divs.l, not divsl.l - see cpu3d_clip3d_interp
	move.l	d5,d0

	rts

; -----------------------------------------------------------------------------
; Clips against the screen rectangle. Deliberately simpler than
; src/dsp/3d.asm's clip_2d, which fuses all four edges into one pass with
; explicit corner-insertion for polygons that wrap a viewport corner - that
; machinery exists for the DSP's own reasons, not because the underlying
; problem needs it: clipping a convex polygon against a rectangle is the
; textbook case of running a single-plane clip four times in sequence (left,
; right, top, bottom), each pass's output feeding the next. That handles
; corners correctly for free - a polygon that needs a corner point surviving
; is exactly the polygon whose two adjacent surviving edges both produced an
; interpolated point on the two boundaries meeting at that corner, on two
; separate passes.
;
; The single-plane pass this chains is cpu3d_clip2d_plane, the 2D twin of
; cpu3d_clip3d: same "keep near, interpolate at the crossing, drop far"
; shape, just against a configurable axis/threshold instead of a hardcoded
; z=0. A polygon can gain at most one corner per plane, so at most +4
; corners over the whole rectangle - within the same per-record buffer
; budget cpu3d_bsp_emit already sized (2D corners are 8 bytes against 3D's
; 12, so there is headroom even after the growth).
;
; a0.l = input polygon list (cpu3d_project's output format: word count,
;        word colour, then (count+1) sets of {long x, long y}), consumed
; a1.l = output polygon list (same format, screen-rectangle clipped)
; d0.w = number of input polygons (> 0)
; trashes d0-d7/a0-a6
; -----------------------------------------------------------------------------

SCREEN_WIDTH = 320
SCREEN_HEIGHT = 240

cpu3d_clip2d
	move.l	a1,cpu3d_clip2d_final_output
	move.w	d0,cpu3d_clip2d_saved_count

; pass 1: x >= 0 (left)
	clr.w	cpu3d_clip2d_axis_offset
	clr.l	cpu3d_clip2d_threshold
	move.b	#-1,cpu3d_clip2d_keep_greater
	move.w	cpu3d_clip2d_saved_count,d0
	lea		cpu3d_clip2d_scratch1,a1
	bsr		cpu3d_clip2d_plane

; pass 2: x <= SCREEN_WIDTH (right)
	clr.w	cpu3d_clip2d_axis_offset
	move.l	#SCREEN_WIDTH,cpu3d_clip2d_threshold
	clr.b	cpu3d_clip2d_keep_greater
	move.w	cpu3d_clip2d_saved_count,d0
	lea		cpu3d_clip2d_scratch1,a0
	lea		cpu3d_clip2d_scratch2,a1
	bsr		cpu3d_clip2d_plane

; pass 3: y >= 0 (top)
	move.w	#4,cpu3d_clip2d_axis_offset
	clr.l	cpu3d_clip2d_threshold
	move.b	#-1,cpu3d_clip2d_keep_greater
	move.w	cpu3d_clip2d_saved_count,d0
	lea		cpu3d_clip2d_scratch2,a0
	lea		cpu3d_clip2d_scratch1,a1
	bsr		cpu3d_clip2d_plane

; pass 4: y <= SCREEN_HEIGHT (bottom) - into the caller's real output
	move.w	#4,cpu3d_clip2d_axis_offset
	move.l	#SCREEN_HEIGHT,cpu3d_clip2d_threshold
	clr.b	cpu3d_clip2d_keep_greater
	move.w	cpu3d_clip2d_saved_count,d0
	lea		cpu3d_clip2d_scratch1,a0
	move.l	cpu3d_clip2d_final_output,a1
	bsr		cpu3d_clip2d_plane

	rts

; -----------------------------------------------------------------------------
; One single-plane pass: keep_greater<>0 keeps corners where
; *(point+axis_offset) >= threshold (left/top edges), keep_greater=0 keeps
; where <= threshold (right/bottom edges) - configured by cpu3d_clip2d
; before each call via cpu3d_clip2d_axis_offset/threshold/keep_greater.
; Every input polygon produces an output record regardless of how many
; corners survive (down to 0) - the polygon count never shrinks across a
; pass, only individual corner counts do, so cpu3d_clip2d can reuse the same
; count for all four passes and a later stage just skips count=0 records.
;
; Same "loop counters must not live in a register a callee trashes" lesson
; as cpu3d_clip3d (see its header) - both counters live in memory here too.
;
; a0.l = input polygon list, consumed
; a1.l = output polygon list, advances
; d0.w = number of input polygons (> 0)
; trashes d0-d7/a0-a6
; -----------------------------------------------------------------------------

cpu3d_clip2d_plane
	move.w	d0,cpu3d_clip2d_poly_count

.poly_loop
	move.w	(a0)+,d6			; input corner count (n) - temporary use
	move.w	(a0)+,d5			; colour - temporary use

	move.l	a1,a2				; a2 -> this output record's count field
	clr.w	(a1)+
	move.w	d5,(a1)+
	moveq	#0,d4				; output corner count so far

	move.w	d6,cpu3d_clip2d_edge_count
.edge_loop
	move.l	a0,a3				; a3 -> near candidate
	lea		8(a0),a4			; a4 -> far candidate

	move.l	a3,a2
	bsr		cpu3d_clip2d_distance
	move.l	d0,d5				; d5 = near distance
	tst.l	d5
	bmi		.near_behind

	move.l	(a3),(a1)+			; near is inside - keep it as-is
	move.l	4(a3),(a1)+
	addq	#1,d4

	move.l	a4,a2
	bsr		cpu3d_clip2d_distance
	move.l	d0,d6				; d6 = far distance
	tst.l	d6
	bpl		.no_cross1			; both inside - no crossing on this edge
	bsr		cpu3d_clip2d_interp	; near=a3(d5), far=a4(d6)
	addq	#1,d4
.no_cross1
	bra		.next_edge

.near_behind
	move.l	a4,a2
	bsr		cpu3d_clip2d_distance
	move.l	d0,d6				; d6 = far distance
	tst.l	d6
	bmi		.next_edge			; both outside - discard, emit nothing

	exg		a3,a4				; near=far-candidate, far=orig near
	exg		d5,d6				; distances swap the same way
	bsr		cpu3d_clip2d_interp
	addq	#1,d4

.next_edge
	lea		8(a0),a0
	subq.w	#1,cpu3d_clip2d_edge_count
	bne		.edge_loop

	lea		8(a0),a0			; skip the (n+1)'th stored corner

	move.w	d4,(a2)				; patch in the real output corner count

	tst.w	d4
	beq		.no_repeat
	lea		4(a2),a5			; a5 -> first emitted corner
	move.l	(a5)+,(a1)+
	move.l	(a5),(a1)+			; repeat it, closing the loop
.no_repeat

	subq.w	#1,cpu3d_clip2d_poly_count
	bne		.poly_loop

	rts

; -----------------------------------------------------------------------------
; Signed distance from the configured boundary - positive means inside.
;
; a2.l = point address (x,y), preserved
; returns d0.l = signed distance
; trashes d1
; -----------------------------------------------------------------------------

cpu3d_clip2d_distance
	moveq	#0,d1
	move.w	cpu3d_clip2d_axis_offset,d1
	move.l	(a2,d1.l),d0
	sub.l	cpu3d_clip2d_threshold,d0
	tst.b	cpu3d_clip2d_keep_greater
	bne		.done
	neg.l	d0
.done
	rts

; -----------------------------------------------------------------------------
; Linearly interpolates the boundary-crossing point between a "near" (inside,
; distance>=0) and "far" (outside, distance<0) point - the 2D twin of
; cpu3d_clip3d_interp, same F = neardist/(neardist-fardist) shape, just
; taking the already-computed distances as parameters instead of re-deriving
; them (cpu3d_clip2d_distance depends on which of the four passes is
; running, unlike z which was always a fixed offset).
;
; a3.l = near point address (x,y), preserved
; a4.l = far point address (same layout), preserved
; a1.l = output cursor, advances by 8 (writes x,y)
; d5.l = near distance, d6.l = far distance
; trashes d0-d3,d7
; -----------------------------------------------------------------------------

cpu3d_clip2d_interp
	move.l	d5,d0
	move.l	#$800000,d1
	muls.l	d1,d3:d0
	move.l	d5,d1
	sub.l	d6,d1
	divs.l	d1,d3:d0			; divs.l, not divsl.l - see cpu3d_clip3d_interp
	move.l	d0,d7

	move.l	(a4),d2
	sub.l	(a3),d2
	move.l	d7,d0
	move.l	d2,d1
	bsr		cpu3d_qmul
	add.l	(a3),d0
	move.l	d0,(a1)+

	move.l	4(a4),d2
	sub.l	4(a3),d2
	move.l	d7,d0
	move.l	d2,d1
	bsr		cpu3d_qmul
	add.l	4(a3),d0
	move.l	d0,(a1)+

	rts

; -----------------------------------------------------------------------------
	data
; -----------------------------------------------------------------------------

; Fixed dummies shared with cpu3d_project (viewer_position) once written -
; declared once here rather than duplicated, since both stages' correctness
; depends on using the identical value. Values copied verbatim from
; src/dsp/3d.asm (vector_viewer_position, vector_light_ray) so results match
; the DSP version bit-for-bit rather than being re-derived from decimals.

cpu3d_viewer_position
	dc.l	160,100,-300

cpu3d_light_vector
	dc.l	$ffb61963,$0049e69d,$0049e69d

; -----------------------------------------------------------------------------
	bss
; -----------------------------------------------------------------------------

cpu3d_scratch_trig
	ds.l	6					; cx,cy,cz,sx,sy,sz - see the CX../SZ offsets above

; Memory-resident loop counters - see cpu3d_clip3d's header comment for why
; these live here instead of in a data register.
cpu3d_clip3d_poly_count
	ds.w	1
cpu3d_clip3d_edge_count
	ds.w	1
cpu3d_project_poly_count
	ds.w	1
cpu3d_project_corner_count
	ds.w	1
	even

; One live object's BSP output at a time: up to 512 emitted polygons, sized
; for corner counts up to 8 (docs/MODEL-FORMAT.md: highest observed) plus
; the repeated first corner - (2+2+9*12) = 112 bytes/record worst case.
; Revisit if a real (non-test) model overflows this - see docs/CPU3D.md.
cpu3d_polygon_sorted
	ds.b	512*112

; cpu3d_clip2d's own loop counters and per-pass configuration (see
; cpu3d_clip2d_plane's header for why the counters live in memory) plus its
; ping-pong scratch buffers and the caller's real output pointer, saved
; across the three intermediate passes.
cpu3d_clip2d_poly_count
	ds.w	1
cpu3d_clip2d_edge_count
	ds.w	1
cpu3d_clip2d_saved_count
	ds.w	1
cpu3d_clip2d_axis_offset
	ds.w	1
cpu3d_clip2d_keep_greater
	ds.b	1
	even
cpu3d_clip2d_threshold
	ds.l	1
cpu3d_clip2d_final_output
	ds.l	1

cpu3d_clip2d_scratch1
	ds.b	512*112
cpu3d_clip2d_scratch2
	ds.b	512*112

	end
