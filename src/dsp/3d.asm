; -----------------------------------------------------------------------------
; 3d routines
; (c) 1994 by Sascha Springer
; -----------------------------------------------------------------------------

; Provenance: TARGET ARTEFACT / N/A - platform replacement. This is adapted
; from sibling f030dsp3d/src/3d.asm, SHA-256
; 3caaca03b21171667b2cda33c65cdc813b9d8c4d6d1df049ce620d4a372e2ec0. It is
; not a translation of DOS X.EXE; the DOS behavioural authority is documented
; in docs/ARCHITECTURE.md. Observable contract: produce the logical span list
; consumed by the Falcon 68030 filler.

	include	'ioequ.inc'

SCREEN_WIDTH 	= 320
SCREEN_HEIGHT 	= 240

MAX_POINTS		= 2000
MAX_POLYGONS	= 1000

;
; 2D Clipping Begrenzungen
;
LEFT		= 0
TOP			= 0
RIGHT		= SCREEN_WIDTH
BOTTOM		= SCREEN_HEIGHT

; -----------------------------------------------------------------------------
	org	p:$0
; -----------------------------------------------------------------------------

	jmp	main

; -----------------------------------------------------------------------------
	org	x:$0
; -----------------------------------------------------------------------------

;
; Variabler Ring-Buffer für 2D-Clipping (natürlich an x:$0)
;
ring
	ds	30*2

; -----------------------------------------------------------------------------
	org	x:$200				; x-memory
; -----------------------------------------------------------------------------

;
; 2D-Clipping Begrenzungen (Reihenfolge ist wichtig)
;
clip_borders
	dc	LEFT,RIGHT,TOP,BOTTOM

;
; Rotationsmatrix des Objekts
;
matrix_object_rotation
	ds	9

;
; Damit mit der Routine rotate_translate auch nur rotiert werden kann, braucht
; man einen Positions-Vektor, der den Wert Null hat.
;
vector_null_position
	dc	0,0,0

;
; Position des Objekts
;
vector_object_position
	dc	1500,0,900			; dummy
	ds	3

;
; Punkte-Array 2D Koordinaten
;
; Bem.: sollte vor array_vector_point_rotated liegen!
;
array_2d_point

;
; Punkte-Array 3D Koordinaten
;
; Punktkoordinaten und Normalenvektoren des Objekts
; davor Platz für schon rotierte Punkte
; (damit noch benötigte Daten nicht überschrieben werden)
;
array_vector_point_rotated
	ds	3
array_vector_point
	dc	-1000,-1000,-1000		; dummy
	dc	1000,-1000,-1000		; dummy
	dc	1000,1000,-1000			; dummy
	dc	-1000,1000,-1000		; dummy
	dc	-1000,-1000,1000		; dummy
	dc	1000,-1000,1000			; dummy
	dc	1000,1000,1000			; dummy
	dc	-1000,1000,1000			; dummy
	dc	0,0,$800001			; dummy
	dc	0,$800001,0			; dummy
	dc	$7fffff,0,0			; dummy
	dc	0,$7fffff,0			; dummy
	dc	$800001,0,0			; dummy
	dc	0,0,$7fffff			; dummy
	ds	MAX_POINTS*3


;
; Polygonarray 2D-geclippt
;
; Bem.: !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
;
array_polygon_2d_clipped

; Polygonarray sortiert, 3D-geclippt
;
; Aufbau der Polygonstruktur:
;
; [0] Anzahl der Punkte (n)
; [1] Farbindex * 32
; [2] Punkt #0 Index (relativ zum Anfang des Punktearrays)
; [3] Punkt #1 Index
;            :
; [n-1+2] Punkt #n-1 Index
;
; Bem.: sollte vor array_polygon_sorted liegen (s.u.)!
;
array_polygon_sorted_3d_clipped
	ds	MAX_POLYGONS*3

;
; Polygonarray sortiert
;
; Aufbau der Polygonstruktur:
;
; [0] Anzahl der Punkte (n)
; [1] Farbindex * 32
; [2] Punkt #0 Index (relativ zum Anfang des Punktearrays)
; [3] Punkt #1 Index
;            :
; [n-1+2] Punkt #n-1 Index
; [n-1+3] Punkt #0 Index
;
; Bem.: Punkt #0 wird angehangen, damit das 3D-Clipping schneller abläuft!
;
array_polygon_sorted
	ds	MAX_POLYGONS*7

; -----------------------------------------------------------------------------
	org	y:$800				; y-memory
; -----------------------------------------------------------------------------

;
; Ecken für 2D-Clipping
;
clip_edges
	dc	LEFT,TOP,RIGHT,TOP		; insert edges
	dc	RIGHT,BOTTOM,LEFT,BOTTOM

;
; Offsets für Punktberechnung x und y (Werte / 2)
;
offsets
	dc	1,SCREEN_WIDTH			; screen offsets

;
; Lichtstrahl (Annahme: parallele Einstrahlung)
;
vector_light_ray
	dc	-0.5773502,0.5773502,0.5773502	; dummy
;	dc	-1.0,0.0,0.0
	ds	3

;
; Kamera Position
;
vector_camera_position
	dc	0,0,0				; dummy
	ds	3

;
; Betrachter Position (vor dem Bildschirm)
;
vector_viewer_position
	dc	160,100,-300			; dummy
	ds	3

;
; Aufbau des Objekt-Kopfes:
;
; [0] Anzahl der Punkte
; [1] Anzahl der Normalen Vektoren der Polygone
; [2] Anzahl der Polygone
;
; Bem.: Anzahl der Polygon-Normalen ist nicht unbedingt mit der Anzahl
;       der Polygone identisch!
;
struct_object_header
	dc	8,6,6				; dummy
	ds	3

;
; Vorberechneter Sinus und Cosinus der Winkel zur Rotation des Objekts
;
; Aufbau der sincos-Tabelle:
;
; [0] sin(x-Winkel)
; [1] sin(y-Winkel)
; [2] sin(z-Winkel)
; [3] cos(x-Winkel)
; [4] cos(y-Winkel)
; [5] cos(z-Winkel)
;
array_object_sincos
	dc	0,0,0				; dummy
	dc	$7fffff,$7fffff,$7fffff		; dummy
	ds	6

;
; Vorberechneter Sinus und Cosinus der Winkel zur Rotation der Kamera
;
; Aufbau s.o.
;
array_camera_sincos
	dc	0,0,0				; dummy
	dc	$7fffff,$7fffff,$7fffff		; dummy
	ds	6

;
; Rotationsmatrix der Kamera
;
matrix_camera_rotation
	ds	9

;
; Gesamt-Rotationsmatrix
;
; Ergebnis der Operation: matrix_object_rotation * matrix_camera_rotation
;
matrix_objcam_rotation
	ds	9

;
; Eigener Stack für BSP-Baum
;
; Bem.: nach hinten wachsend!
;
	ds	MAX_POLYGONS*2
array_stack

;
; LeftRight Tabelle
;
leftright_table

;
; Polygonarray sortiert, 3D-geclippt, konvertiert
;
; Aufbau:
;
; [0] Anzahl der Punkte (n)
; [1] Farbindex * 32
; [2] Punkt #0 x-Koordinate
; [3] Punkt #0 y-Koordinate
; [4] Punkt #1 x-Koordinate
; [5] Punkt #1 y-Koordinate
;            :
; [2*(n-1)+2] Punkt #n x-Koordinate
; [2*(n-1)+3] Punkt #n y-Koordinate
;
; Bem.: sollte vor array_polygon liegen!
;
array_polygon_converted

;
; Polygonarray
;
; Aufbau der Polygonstruktur:
;
; [0] Anzahl der Punkte (n)
; [1] Farbindex * 32
; [2] Normalen-Vektor Index (relativ zum Anfang des Punktearrays)
; [3] "hinteres" Polygon Index (relativ zum Anfang des Polygonarrays)
; [4] "vorderes" Polygon Index (Endekennzeichen: 0)!
; [5] Punkt #0 Index (relativ zum Anfang des Punktearrays)
; [6] Punkt #1 Index
;            :
; [n-1+5] Punkt #n-1 Index
;
array_polygon
	dc	4,0*32,8*3,9*1+3,0,0*3,1*3,2*3,3*3	; dummy
	dc	4,0*32,9*3,9*2+3,0,0*3,4*3,5*3,1*3	; dummy
	dc	4,0*32,10*3,9*3+3,0,1*3,5*3,6*3,2*3	; dummy
	dc	4,0*32,11*3,9*4+3,0,2*3,6*3,7*3,3*3	; dummy
	dc	4,0*32,12*3,9*5+3,0,3*3,7*3,4*3,0*3	; dummy
	dc	4,0*32,13*3,0,0,7*3,6*3,5*3,4*3		; dummy
	ds	MAX_POLYGONS*10
;
; Da die Polygonstruktur sehr variabel ist, kann man nicht davon ausgehen, daß
; hinter dem Polygon-Array nichts überschrieben wird!
;

; -----------------------------------------------------------------------------
	org	p:$40				; main program
; -----------------------------------------------------------------------------

main
	movep	#1,x:m_pbc			; configure host-port

m_loop
;	jmp	debug				; dummy

	jsr		do_object

	jmp		m_loop

; -----------------------------------------------------------------------------

do_object

;
; Objektdaten empfangen
;
	jsr		receive_data
debug						; DEBUG start!!

;
; Rotationsmatrizen berechnen
;
	move	#matrix_object_rotation,r0
	move	#array_object_sincos+2,r4
	move	#array_camera_sincos+2,r5
	move	#matrix_camera_rotation,r6
	move	#matrix_objcam_rotation,r7
	jsr		make_rotation_matrix

;
; Punkte rotieren
;
	move	#array_vector_point,r0
	move	#vector_object_position,r1
	move	#array_vector_point_rotated,r2
	move	#matrix_objcam_rotation,r4
	move	y:struct_object_header,x0
	jsr		rotate_translate

;
; Normalenvektoren rotieren
;
; Bem.: dieser Aufruf muß nach dem Punkte rotieren aufgerufen werden.
;       Die Register r0, r2 und r4 brauchen dann nicht neu gesetzt werden.
;       Wichtig zur Sichtbarkeitsbestimmung der Polygone!
;
	move	(r0)-				; Korrektur (s. Bem.)!
	move	#vector_null_position,r1	; Nur rotieren!
	move	(r4)-				; Korrektur!
	move	y:struct_object_header+1,x0
	jsr		rotate_translate

; Polygone mit Hilfe eines BSP-Baums sortieren
;
	move	#array_polygon,r0
	move	#array_polygon_sorted,r1
	move	#array_vector_point_rotated,r2
	move	#vector_viewer_position,r4
	move	#array_stack,r7
	jsr		sort_polygon_bsp
	move	x0,y:struct_object_header+2

;
; Polygone an der z-Ebene clippen (3D-Clipping)
;
	move	#array_vector_point_rotated,r0
	move	#array_polygon_sorted,r2
	move	#array_polygon_sorted_3d_clipped,r3
	move	y:struct_object_header+2,x0
	move	y:struct_object_header,x1
	jsr		clip_polygon_3d
	move	x0,y:struct_object_header
	move	x1,y:struct_object_header+2

;
; 3D-Koordinaten in 2D-Koordinaten umrechnen (Zentralprojektion)
;
	move	#array_vector_point_rotated,r0
	move	#array_2d_point,r1
	move	#vector_viewer_position,r4
	move	y:struct_object_header,x0
	jsr		convert_3d_to_2d


;
; Polygonstruktur umwandeln
;
	move	#array_2d_point,r0
	move	#array_polygon_sorted_3d_clipped,r1
	move	#array_polygon_converted,r5
	move	y:struct_object_header+2,x0
	jsr		convert_polygon
	move	x0,y:struct_object_header+2

;
; 2D-Clipping!
;
	move	#array_polygon_2d_clipped,r0
	move	#clip_borders,r3
	move	#array_polygon_converted,r4
	move	y:struct_object_header+2,x0
	jsr		clip_2d

;
; Leftright Tabelle erstellen
;
	move	#array_polygon_2d_clipped,r0
	move	#leftright_table,r4
	move	y:struct_object_header+2,x0
	jsr		make_leftright

;
; Berechnete Daten senden
;
	jsr		send_data

	rts

; -----------------------------------------------------------------------------

receive_data

	move	#array_vector_point,r0
	move	#array_polygon,r1
	move	#vector_object_position,r4			; at x:ram!!!
	move	#array_object_sincos,r5
	move	#array_camera_sincos,r6
	move	#vector_camera_position,r7

	jclr	#0,x:m_hsr,*
	movep	x:m_hrx,x0			; number of points
	move	x0,y:struct_object_header

	jclr	#0,x:m_hsr,*
	movep	x:m_hrx,x1			; number of normals
	move	x1,y:struct_object_header+1

	jclr	#0,x:m_hsr,*
	movep	x:m_hrx,y0			; number of faces
	move	y0,y:struct_object_header+2

	do		x0,rd_loop1			; points

	jclr	#0,x:m_hsr,*
	movep	x:m_hrx,x:(r0)+		; x-coordinate

	jclr	#0,x:m_hsr,*
	movep	x:m_hrx,x:(r0)+		; y-coordinate

	jclr	#0,x:m_hsr,*
	movep	x:m_hrx,x:(r0)+		; z-coordinate
rd_loop1

	do		x1,rd_loop1b		; normals

	jclr	#0,x:m_hsr,*
	movep	x:m_hrx,x:(r0)+		; x-coordinate

	jclr	#0,x:m_hsr,*
	movep	x:m_hrx,x:(r0)+		; y-coordinate

	jclr	#0,x:m_hsr,*
	movep	x:m_hrx,x:(r0)+		; z-coordinate
rd_loop1b

	do		y0,rd_loop2			; polygons

	jclr	#0,x:m_hsr,*
	movep	x:m_hrx,x1			; # of points/face
	move	x1,y:(r1)+

	jclr	#0,x:m_hsr,*
	movep	x:m_hrx,y:(r1)+		; colour

	jclr	#0,x:m_hsr,*
	movep	x:m_hrx,y:(r1)+		; normal vector

	jclr	#0,x:m_hsr,*
	movep	x:m_hrx,y:(r1)+		; "back" polygon

	jclr	#0,x:m_hsr,*
	movep	x:m_hrx,y:(r1)+		; "front" polygon

	do		x1,rd_loop3

	jclr	#0,x:m_hsr,*
	movep	x:m_hrx,y:(r1)+		; point #0 ... point #n
rd_loop3

	nop
rd_loop2

	do		#3,rd_loop4

	jclr	#0,x:m_hsr,*
	movep	x:m_hrx,y:(r7)+		; camera position (x, y, z)
rd_loop4

	do		#3,rd_loop5

	jclr	#0,x:m_hsr,*
	movep	x:m_hrx,x:(r4)+		; object position (x, y, z)
rd_loop5

	do		#6,rd_loop6

	jclr	#0,x:m_hsr,*
	movep	x:m_hrx,y:(r5)+		; object rotation
								; (sin(x, y, z), cos(x, y, z))
rd_loop6

	do		#6,rd_loop7

	jclr	#0,x:m_hsr,*
	movep	x:m_hrx,y:(r6)+		; camera rotation
								; (sin(x, y, z), cos(x, y, z))
rd_loop7

	rts

; -----------------------------------------------------------------------------

send_data

	move	#struct_object_header+2,r4
	move	#leftright_table,r5

	move	y:(r4),a			; # of faces

	jclr	#1,x:m_hsr,*
	movep	a1,x:m_htx

	tst		a
	jeq		sd_end

	do		a1,sd_loop1

	move	y:(r5)+,a			; count
	jclr	#1,x:m_hsr,*
	movep	a1,x:m_htx

	jclr	#1,x:m_hsr,*
	movep	y:(r5)+,x:m_htx		; colour

	jclr	#1,x:m_hsr,*
	movep	y:(r5)+,x:m_htx		; offset

	do		a1,sd_loop2

	jclr	#1,x:m_hsr,*
	movep	y:(r5)+,x:m_htx		; left, right, flag ,lines
sd_loop2

	nop
sd_loop1
sd_end

	rts

; -----------------------------------------------------------------------------
;
; LeftRight Tabelle erstellen
;
make_leftright
; r0 = x:Polygonarray 2D-geclippt
; r4 = y:LeftRight Tabelle
; x0 = Anzahl der Polygone

; leftright table:
; count, colour, offset
; {,left, right, flag, lines}[];

	move	x0,a
	tst		a
	jeq		mlr_loop1

	move	#2,n1
	move	n1,n2
	move	#3,n5
	move	#4,n6
	move	n6,n4
	move	#offsets,r7

	do		x0,mlr_loop1

	move	#ring,r1
	move	r4,r5

	move	x:(r0)+,x0			; # of coords | -
	tfr		x0,a y:(r7),y0

	tst		a x:(r0)+,x1		; no face? | colour
	jne		mlr_go_on

	move	y:struct_object_header+2,a			; # of faces --
	sub		y0,a
	move	a1,y:struct_object_header+2

	jmp		mlr_next_face

mlr_go_on
	add		x0,a (r4)+
	sub		y0,a
	move	a1,m1
	move	m1,m2

	move	x1,y:(r4)+			; store colour

	move	r4,r6
	clr		b y:(r4)+,y0
	move	b1,y:(r5)			; clear count

	move	#>-1,x1				; compare value

	do		x0,mlr_loop2

	move	x:(r0)+,x0			; x
	move	x0,x:(r1)+
	move	x:(r0)+,a			; y
	move	a,x:(r1)+
	cmp		x1,a
	jhs		mlr_ok1

	move	a1,x1
	lua		(r1)-n1,r2

mlr_ok1
	nop
mlr_loop2

	move	r2,r1

	move	x:(r2)+,x0 y:(r7)+,y0
	move	x:(r2)-,x1 y:(r7)-,y1
	mpy		y0,x0,a
	mac		y1,x1,a
	move	a0,y:(r6)+n6			; store offset
	move	(r6)-

; ----

; r2 = x:start coordinate
; r1 = x:end coordinate
; r4 = y:leftright table
; r5 = y:count
; r6 = y:flag

mlr_main_loop
	clr		b (r2)+
	move	b1,y:(r6)+			; clear flag
	move	#<$7f,x0
	move	x0,y:(r6)-			; preset lines

	move	(r1)+
	move	x:(r2)-,a			; right
	move	x:(r1)-,x1			; left
	sub		x1,a
	jmi		mlr_right

mlr_left
	lua		(r1)-n1,r3
	bset	#1,y:(r6)			; flag 1

	move	x:(r3)+,a			; x1
	move	x:(r3)-,b			; y1
	move	x:(r1)+,x0
	sub		x0,a				; x1 - x0
	move	x:(r1)-,y1
	sub		y1,b				; y1 - y0
	jmi		mlr_not_convex			; if non convex!

	jne		mlr_l_div

	move	a1,y:(r4)			; left step
	clr		a
	bset	#3,y:(r6)+			; flag 2
	move	a1,y:(r6)-			; lines

	jmp		mlr_l_no_div

mlr_l_div
	move	#$4000,x0 a,y0
	mpy		x0,y0,a b,x0
	jpl		*+2

	neg		a
	andi	#$fe,ccr
	rep		#24
	div		x0,a
	jclr	#23,y0,*+3

	neg		a
	move	a0,y:(r4)			; left step

	move	(r2)+
	move	x:(r2)-,a
	sub		y1,a (r6)+
	jeq		mlr_l_skip1

	cmp		b,a
	jle		mlr_l_skip2

mlr_l_skip1
	move	b,a

mlr_l_skip2
	move	a,y:(r6)-			; lines

mlr_l_no_div
	move	(r2)+
	move	(r1)+
	move	x:(r2)-,a			; right
	move	x:(r1)-,x1			; left
	sub		x1,a
	jne		mlr_not_right

; ----

mlr_right
	lua		(r2)+n2,r3
	bset	#0,y:(r6)			; flag 1

	move	x:(r3)+,a			; x1
	move	x:(r3)-,b			; y1
	move	x:(r2)+,x0
	sub		x0,a				; x1 - x0
	move	x:(r2)-,y1
	sub		y1,b				; y1 - y0
	jmi		mlr_not_convex			; if non convex!

	jne		mlr_r_div

	move	(r4)+
	move	a1,y:(r4)-			; right step
	clr		a
	bset	#2,y:(r6)+			; flag 2
	move	a1,y:(r6)-			; lines

	jmp		mlr_r_no_div

mlr_r_div
	move	#$4000,x0 a,y0
	mpy		x0,y0,a b,x0
	jpl		*+2

	neg		a
	andi	#$fe,ccr
	rep		#24
	div		x0,a
	jclr	#23,y0,*+3

	neg		a
	move	(r4)+
	move	a0,y:(r4)-			; right step

	move	(r1)+
	move	x:(r1)-,a
	sub		y1,a (r6)+
	jeq		mlr_r_skip1

	cmp		b,a
	jle		mlr_r_skip2

mlr_r_skip1
	move	b,a

mlr_r_skip2
	move	y:(r6),b
	cmp		b,a
	jle		mlr_r_skip2b

	move	b,a

mlr_r_skip2b
	move	a,y:(r6)-			; lines

mlr_r_no_div
mlr_not_right
	move	y:(r6)+n6,x1
	jclr	#1,x1,*+3

	lua		(r1)-n1,r1
	move	r2,x0
	jclr	#0,x1,*+3

	lua		(r2)+n2,r2
	move	r1,a
	cmp		x0,a (r4)+n4
	jeq		mlr_next_face

	move	r2,x0
	cmp		x0,a
	jeq		mlr_next_face

	jmp		mlr_main_loop

mlr_not_convex
	move	y:(r7),y0			; # of faces --
	move	y:struct_object_header+2,a
	sub		y0,a
	move	a1,y:struct_object_header+2
	move	r5,r4

mlr_next_face
	lua		(r5)+n5,r1
	move	r4,a
	move	r1,x0
	sub		x0,a
	move	a1,y:(r5)			; store count
mlr_loop1

	move	#$ffff,m1
	move	m1,m2

	rts

; -----------------------------------------------------------------------------
;
; 2D-Clipping!
;

LEFT_BIT	= 0
RIGHT_BIT	= 1
TOP_BIT		= 3
BOTTOM_BIT	= 2

clip_2d
; r0 = x:Polygonarray 2D-geclippt
; r3 = x:Clippingstruktur (left, right, top, bottom)
; r4 = y:Polygonarray ungeclippt
; x0 = Anzahl der Polygone

	move	x0,a
	tst		a
	jne		c2d_start

	rts

c2d_start
	move	#c2d_status,r2
	move	#c2d_temp,r6
	move	#clip_edges,r7
	move	#>3,n3
	move	n3,n4
	move	#>8-1,m7

	do		x0,c2d_loop1

	move	#>-1,x0
	move	x0,p:(r2)+			; status 1 = -1
	move	x0,p:(r2)-			; status 2 = -1
	clr		a
	move	a1,p:-(r2)			; flag = 0
	move	p:(r2)+,x0

	move	a1,x:(r0)
	lua		(r0)+,r1
	move	y:(r4)+,x0			; # of points/face
	move	y:(r4)+,x1			; colour
	move	r4,a
	add		x0,a
	add		x0,a
	move	a,r5
	move	x1,x:(r1)+			; store colour

	move	y:(r5)+,x1
	move	x1,p:(r6)+
	move	y:(r5)-,x1
	move	x1,p:(r6)-

	move	y:(r4)+,x1
	move	x1,y:(r5)+
	move	y:(r4)-,x1
	move	x1,y:(r5)-

	do		x0,c2d_loop2

; set bits for clipping

;    1001|1000|1010
;    ----+----+----
;    0001|0000|0010
;    ----+----+----
;    0101|0100|0110

	clr		a
	move	a1,y0				; clear bit field

	move	x:(r3)+,x0 y:(r4)+,b
	cmp		x0,b x:(r3)+,x0
	jge		c2d_not_left1

	bset	#LEFT_BIT,y0

c2d_not_left1
	cmp		x0,b x:(r3)+,x0 y:(r4)+,b
	jle		c2d_not_right1

	bset	#RIGHT_BIT,y0

c2d_not_right1
	cmp		x0,b x:(r3),x0
	jge		c2d_not_top1

	bset	#TOP_BIT,y0

c2d_not_top1
	move	x:(r3)-n3,x0
	cmp		x0,b x:(r3)+,x0 y:(r4)+,b
	jle		c2d_not_bottom1

	bset	#BOTTOM_BIT,y0

c2d_not_bottom1
	cmp		x0,b x:(r3)+,x0
	jge		c2d_not_left2

	bset	#LEFT_BIT,a1

c2d_not_left2
	cmp		x0,b x:(r3)+,x0 y:(r4),b
	jle		c2d_not_right2

	bset	#RIGHT_BIT,a1

c2d_not_right2
	cmp		x0,b x:(r3),x0
	jge		c2d_not_top2

	bset	#TOP_BIT,a1

c2d_not_top2
	move	x:(r3)-n3,x0
	cmp		x0,b y:(r4)-n4,b
	jle		c2d_not_bottom2

	bset	#BOTTOM_BIT,a1

c2d_not_bottom2
	move	a1,y1
	and		y0,a1
	jne		c2d_no_clip1

; ----

	move	y0,a
	tst		a
	jne		c2d_clip1

	move	y:(r4)+,x0			; store x0
	move	x0,x:(r1)+
	move	y:(r4)-,x0			; store y0
	move	x0,x:(r1)+

	move	#>1,x0				; # of clipped points/face ++
	move	x:(r0),a
	add		x0,a
	move	a1,x:(r0)

	jmp		c2d_clip_other

;-----------------------------------
; clip point 0 left
;-----------------------------------

c2d_clip1
	jclr	#LEFT_BIT,y0,c2d_n0l

	move	y:(r4)+n4,x0
	move	y:-(r4),a			; x1
	move	x:(r3)+n3,x0			; left
	sub		x0,a a,b			; x1 - left
	move	y:-(r4),x0
	move	y:-(r4),x0			; x0
	sub		x0,b y:(r4)+,x0			; x1 - x0
	move	b1,x0

	andi	#$fe,ccr			; (x1 - left) / (x1 - x0)
	rep		#24
	div		x0,a

	move	a0,x0
	move	y:(r4)+n4,b			; y0
	move	y:-(r4),x1			; y1
	sub		x1,b x1,a			; y0 - y1
	move	b1,x1
	mac		x0,x1,a y:(r4)-n4,x0		; (y0-y1)*(x1-left)/(x1-x0)+y1

	move	x:(r3)-,x1			; bottom
	move	x:(r3)+,x0			; top
	lua		(r3)-n3,r3
	cmp		x0,a
	jlt		c2d_n0l

	cmp		x1,a
	jgt		c2d_n0l

	move	p:(r2),b			; status 1
	tst		b
	jmi		c2d_0l_ok1

	move	#>clip_edges+0,x0

c2d_0l_loop
	cmp		x0,b
	jeq		c2d_0l_ok2

	move	b1,r7
	move	x:(r0),b			; # of points/face ++
	move	#>1,x1
	add		x1,b
	move	b1,x:(r0)
	move	y:(r7)+,x1			; store edge x
	move	x1,x:(r1)+
	move	y:(r7)+,x1			; store edge y
	move	x1,x:(r1)+

	move	r7,b
	jmp		c2d_0l_loop

c2d_0l_ok1
	move	#>clip_edges+0,x0		; set status 2
	move	p:(r2)+,x1
	move	x0,p:(r2)-

c2d_0l_ok2
	move	#>1,x0				; # of clipped points/face ++
	move	x:(r0),b
	add		x0,b
	move	b1,x:(r0)
	move	x:(r3),x0			; store left
	move	x0,x:(r1)+
	move	a1,x:(r1)+			; store clipped y

	jmp		c2d_clip_other

;-----------------------------------
; clip point 0 right
;-----------------------------------

c2d_n0l
	jclr	#RIGHT_BIT,y0,c2d_n0r

	move	y:(r4)+n4,x0
	move	y:-(r4),x0			; x1
	move	x:(r3)+,a
	move	x:(r3)+,a			; right
	sub		x0,a				; right - x1
	move	y:-(r4),b
	move	y:-(r4),b			; x0
	sub		x0,b y:(r4)+,x0			; x0 - x1
	move	b1,x0

	andi	#$fe,ccr			; (right - x1) / (x0 - x1)
	rep		#24
	div		x0,a

	move	a0,x0
	move	y:(r4)+n4,b			; y0
	move	y:-(r4),x1			; y1
	sub		x1,b x1,a			; y0 - y1
	move	b1,x1
	mac		x0,x1,a	y:(r4)-n4,x0		; (y0-y1)*(right-x1)/(x0-x1)+y1

	move	x:(r3)+,x0			; top
	move	x:(r3),x1			; bottom
	lua		(r3)-n3,r3
	cmp		x0,a
	jlt		c2d_n0r

	cmp		x1,a
	jgt		c2d_n0r

	move	p:(r2),b			; status 1
	tst		b
	jmi		c2d_0r_ok1

	move	#>clip_edges+4,x0

c2d_0r_loop
	cmp		x0,b
	jeq		c2d_0r_ok2

	move	b1,r7
	move	x:(r0),b			; # of points/face ++
	move	#>1,x1
	add		x1,b
	move	b1,x:(r0)
	move	y:(r7)+,x1			; store edge x
	move	x1,x:(r1)+
	move	y:(r7)+,x1			; store edge y
	move	x1,x:(r1)+

	move	r7,b

	jmp		c2d_0r_loop

c2d_0r_ok1
	move	#>clip_edges+4,x0		; set status 2
	move	p:(r2)+,x1
	move	x0,p:(r2)-

c2d_0r_ok2
	move	#>1,x0				; # of clipped points/face ++
	move	x:(r0),b
	add		x0,b
	move	b1,x:(r0)
	move	x:(r3)+,x0
	move	x:(r3)-,x0			; store right
	move	x0,x:(r1)+
	move	a1,x:(r1)+			; store clipped y

	jmp		c2d_clip_other

;-----------------------------------
; clip point 0 bottom
;-----------------------------------

c2d_n0r
	jclr	#BOTTOM_BIT,y0,c2d_n0b

	move	y:(r4)+n4,x0
	move	y:(r4)-,x0			; y1
	move	x:(r3)+n3,a
	move	x:(r3)-,a			; bottom
	sub		x0,a				; bottom - y1
	move	y:-(r4),b			; y0
	sub		x0,b y:(r4)-,x0			; y0 - y1
	move	b1,x0

	andi	#$fe,ccr			; (bottom - y1) / (y0 - y1)
	rep		#24
	div		x0,a

	move	a0,x0
	move	y:(r4)+n4,b			; x0
	move	y:-(r4),x1			; x1
	sub		x1,b x1,a			; x0 - x1
	move	b1,x1
	mac		x0,x1,a y:(r4)-,x0		; (x0-x1)*(botm-y1)/(y0-y1)+x1

	move	y:(r4)-,x0

	move	x:-(r3),x1			; right
	move	x:-(r3),x0			; left
	cmp		x0,a
	jlt		c2d_n0b

	cmp		x1,a
	jgt		c2d_n0b

	move	p:(r2),b			; status 1
	tst		b
	jmi		c2d_0b_ok1

	move	#>clip_edges+6,x0

c2d_0b_loop
	cmp		x0,b
	jeq		c2d_0b_ok2

	move	b1,r7
	move	x:(r0),b			; # of points/face ++
	move	#>1,x1
	add		x1,b
	move	b1,x:(r0)
	move	y:(r7)+,x1			; store edge x
	move	x1,x:(r1)+
	move	y:(r7)+,x1			; store edge y
	move	x1,x:(r1)+

	move	r7,b

	jmp		c2d_0b_loop

c2d_0b_ok1
	move	#>clip_edges+6,x0		; set status 2
	move	p:(r2)+,x1
	move	x0,p:(r2)-

c2d_0b_ok2
	move	#>1,x0				; # of clipped points/face ++
	move	x:(r0),b
	add		x0,b
	move	b1,x:(r0)
	move	a1,x:(r1)+			; store clipped x
	move	x:(r3)+n3,x0
	move	x:(r3)-n3,x0			; store bottom
	move	x0,x:(r1)+

	jmp		c2d_clip_other

;-----------------------------------
; clip point 0 top
;-----------------------------------

c2d_n0b
	jclr	#TOP_BIT,y0,c2d_n0t

	move	y:(r4)+n4,x0
	move	y:(r4)-,a			; y1
	move	x:(r3)+n3,x0
	move	x:-(r3),x0			; top
	sub		x0,a a,b			; y1 - top
	move	y:-(r4),x0			; y0
	sub		x0,b y:(r4)-,x0			; y1 - y0
	move	b1,x0

	andi	#$fe,ccr			; (y1 - top) / (y1 - y0)
	rep		#24
	div		x0,a

	move	a0,x0
	move	y:(r4)+n4,b			; x0
	move	y:-(r4),x1			; x1
	sub		x1,b x1,a			; x0 - x1
	move	b1,x1
	mac		x0,x1,a	y:(r4)-,x0		; (x0-x1)*(y1-top)/(y1-y0)+x1

	move	y:(r4)-,x0

	move	x:-(r3),x1			; right
	move	x:-(r3),x0			; left
	cmp		x0,a
	jlt		c2d_n0t

	cmp		x1,a
	jgt		c2d_n0t

	move	p:(r2),b			; status 1
	tst		b
	jmi		c2d_0t_ok1

	move	#>clip_edges+2,x0

c2d_0t_loop
	cmp		x0,b
	jeq		c2d_0t_ok2

	move	b1,r7
	move	x:(r0),b			; # of points/face ++
	move	#>1,x1
	add		x1,b
	move	b1,x:(r0)
	move	y:(r7)+,x1			; store edge x
	move	x1,x:(r1)+
	move	y:(r7)+,x1			; store edge y
	move	x1,x:(r1)+

	move	r7,b

	jmp		c2d_0t_loop

c2d_0t_ok1
	move	#>clip_edges+2,x0		; set status 2
	move	p:(r2)+,x1
	move	x0,p:(r2)-

c2d_0t_ok2
	move	#>1,x0				; # of clipped points/face ++
	move	x:(r0),b
	add		x0,b
	move	b1,x:(r0)
	move	a1,x:(r1)+			; store clipped x
	move	x:(r3)+n3,x0
	move	x:-(r3),x0			; store top
	move	x0,x:(r1)+
	move	x:(r3)-,x0
	move	x:(r3)-,x0

;-----------------------------------
; clip point 1
;-----------------------------------

c2d_n0t
c2d_clip_other
	move	y1,a
	tst		a
	jeq		c2d_no_clip1

	move	y:(r4)+,x0			; xchange points!
	move	y:(r4)+,x1
	move	y:(r4)+,a
	move	y:(r4),b
	move	x1,y:(r4)-
	move	x0,y:(r4)-
	move	b1,y:(r4)-
	move	a1,y:(r4)

;-----------------------------------
; clip point 1 left
;-----------------------------------

	jclr	#LEFT_BIT,y1,c2d_n1l

	move	y:(r4)+n4,x0
	move	y:-(r4),a			; x1
	move	x:(r3)+n3,x0			; left
	sub		x0,a a,b			; x1 - left
	move	y:-(r4),x0
	move	y:-(r4),x0			; x0
	sub		x0,b y:(r4)+,x0			; x1 - x0
	move	b1,x0

	andi	#$fe,ccr			; (x1 - left) / (x1 - x0)
	rep		#24
	div		x0,a

	move	a0,x0
	move	y:(r4)+n4,b			; y0
	move	y:-(r4),x1			; y1
	sub		x1,b x1,a			; y0 - y1
	move	b1,x1
	mac		x0,x1,a y:(r4)-n4,x0		; (y0-y1)*(x1-left)/(x1-x0)+y1

	move	x:(r3)-,x1			; bottom
	move	x:(r3)+,x0			; top
	lua		(r3)-n3,r3
	cmp		x0,a
	jlt		c2d_n1l

	cmp		x1,a
	jgt		c2d_n1l

	move	#>clip_edges+0,x0
	move	x0,p:(r2)			; status 1

	move	#>1,x0				; # of clipped points/face ++
	move	x:(r0),b
	add		x0,b
	move	b1,x:(r0)
	move	x:(r3),x0			; store left
	move	x0,x:(r1)+
	move	a1,x:(r1)+			; store clipped y

	jmp		c2d_no_clip2

;-----------------------------------
; clip point 1 right
;-----------------------------------

c2d_n1l
	jclr	#RIGHT_BIT,y1,c2d_n1r

	move	y:(r4)+n4,x0
	move	y:-(r4),x0			; x1
	move	x:(r3)+,a
	move	x:(r3)+,a			; right
	sub		x0,a				; right - x1
	move	y:-(r4),b
	move	y:-(r4),b			; x0
	sub		x0,b y:(r4)+,x0			; x0 - x1
	move	b1,x0

	andi	#$fe,ccr			; (right - x1) / (x0 - x1)
	rep		#24
	div		x0,a

	move	a0,x0
	move	y:(r4)+n4,b			; y0
	move	y:-(r4),x1			; y1
	sub		x1,b x1,a			; y0 - y1
	move	b1,x1
	mac		x0,x1,a	y:(r4)-n4,x0		; (y0-y1)*(right-x1)/(x0-x1)+y1

	move	x:(r3)+,x0			; top
	move	x:(r3),x1			; bottom
	lua		(r3)-n3,r3
	cmp		x0,a
	jlt		c2d_n1r

	cmp		x1,a
	jgt		c2d_n1r

	move	#>clip_edges+4,x0
	move	x0,p:(r2)			; status 1

	move	#>1,x0				; # of clipped points/face ++
	move	x:(r0),b
	add		x0,b
	move	b1,x:(r0)
	move	x:(r3)+,x0
	move	x:(r3)-,x0			; store right
	move	x0,x:(r1)+
	move	a1,x:(r1)+			; store clipped y

	jmp		c2d_no_clip2

;-----------------------------------
; clip point 1 bottom
;-----------------------------------

c2d_n1r
	jclr	#BOTTOM_BIT,y1,c2d_n1b

	move	y:(r4)+n4,x0
	move	y:(r4)-,x0			; y1
	move	x:(r3)+n3,a
	move	x:(r3)-,a			; bottom
	sub		x0,a				; bottom - y1
	move	y:-(r4),b			; y0
	sub		x0,b y:(r4)-,x0		; y0 - y1
	move	b1,x0

	andi	#$fe,ccr			; (bottom - y1) / (y0 - y1)
	rep		#24
	div		x0,a

	move	a0,x0
	move	y:(r4)+n4,b			; x0
	move	y:-(r4),x1			; x1
	sub		x1,b x1,a			; x0 - x1
	move	b1,x1
	mac		x0,x1,a	y:(r4)-,x0		; (x0-x1)*(botm-y1)/(y0-y1)+x1

	move	y:(r4)-,x0

	move	x:-(r3),x1			; right
	move	x:-(r3),x0			; left
	cmp		x0,a
	jlt		c2d_n1b

	cmp		x1,a
	jgt		c2d_n1b

	move	#>clip_edges+6,x0
	move	x0,p:(r2)

	move	#>1,x0				; # of clipped points/face ++
	move	x:(r0),b
	add		x0,b
	move	b1,x:(r0)
	move	a1,x:(r1)+			; store clipped x
	move	x:(r3)+n3,x0
	move	x:(r3)-n3,x0		; store bottom
	move	x0,x:(r1)+

	jmp		c2d_no_clip2

;-----------------------------------
; clip point 1 top
;-----------------------------------

c2d_n1b
	jclr	#TOP_BIT,y1,c2d_n1t

	move	y:(r4)+n4,x0
	move	y:(r4)-,a			; y1
	move	x:(r3)+n3,x0
	move	x:-(r3),x0			; top
	sub		x0,a a,b			; y1 - top
	move	y:-(r4),x0			; y0
	sub		x0,b y:(r4)-,x0			; y1 - y0
	move	b1,x0

	andi	#$fe,ccr			; (y1 - top) / (y1 - y0)
	rep		#24
	div		x0,a

	move	a0,x0
	move	y:(r4)+n4,b			; x0
	move	y:-(r4),x1			; x1
	sub		x1,b x1,a			; x0 - x1
	move	b1,x1
	mac		x0,x1,a y:(r4)-,x0	; (x0-x1)*(y1-top)/(y1-y0)+x1

	move	y:(r4)-,x0

	move	x:-(r3),x1			; right
	move	x:-(r3),x0			; left
	cmp		x0,a
	jlt		c2d_n1t

	cmp		x1,a
	jgt		c2d_n1t

	move	#>clip_edges+2,x0
	move	x0,p:(r2)

	move	#>1,x0				; # of clipped points/face ++
	move	x:(r0),b
	add		x0,b
	move	b1,x:(r0)
	move	a1,x:(r1)+			; store clipped x
	move	x:(r3)+n3,x0
	move	x:-(r3),x0			; store top
	move	x0,x:(r1)+
	move	x:(r3)-,x0
	move	x:(r3)-,x0

c2d_n1t
c2d_no_clip2
	move	y:(r4)+,x0			; xchange points!
	move	y:(r4)+,x1
	move	y:(r4)+,a
	move	y:(r4),b
	move	x1,y:(r4)-
	move	x0,y:(r4)-
	move	b1,y:(r4)-
	move	a1,y:(r4)

c2d_no_clip1
	move	y:(r4)+,x0
	move	y:(r4)+,x0

	move	p:-(r2),a			; c2d_flag
	or		y0,a
	or		y1,a
	move	a1,p:(r2)+
c2d_loop2

	move	p:(r6)+,x0
	move	x0,y:(r4)+
	move	p:(r6)-,x0
	move	x0,y:(r4)-

	move	x:(r0),a
	tst		a
	jne		c2d_ok1

	move	#>%1111,a
	move	p:-(r2),x0
	move	p:(r2)+,x0
	cmp		x0,a
	jne		c2d_ok1

	move	#clip_edges,r7
	move	#>4,x0				; # of clipped points/face += 4
	move	x:(r0),b
	add		x0,b
	move	b1,x:(r0)
	move	y:(r7)+,x0
	move	x0,x:(r1)+
	move	y:(r7)+,x0
	move	x0,x:(r1)+
	move	y:(r7)+,x0
	move	x0,x:(r1)+
	move	y:(r7)+,x0
	move	x0,x:(r1)+
	move	y:(r7)+,x0
	move	x0,x:(r1)+
	move	y:(r7)+,x0
	move	x0,x:(r1)+
	move	y:(r7)+,x0
	move	x0,x:(r1)+
	move	y:(r7)+,x0
	move	x0,x:(r1)+

	jmp		c2d_next_face

c2d_ok1
	move	p:(r2)+,a			; status 1
	move	p:(r2)-,b			; status 2
	tst		a
	jmi		c2d_next_face

	tst		b b,x0
	jmi		c2d_next_face

c2d_set_loop
	cmp		x0,a
	jeq		c2d_next_face

	move	a1,r7
	move	#>1,x1
	move	x:(r0),b
	add		x1,b
	move	b1,x:(r0)
	move	y:(r7)+,x1
	move	x1,x:(r1)+
	move	y:(r7)+,x1
	move	x1,x:(r1)+
	move	r7,a

	jmp		c2d_set_loop

c2d_next_face
	move	r1,r0

c2d_loop1
	move	#$ffff,m7

	rts

	ds	1				; flag
c2d_status
	ds	2				; status1, status2
c2d_temp
	ds	2				; temporary

; -----------------------------------------------------------------------------
;
; Polygonstruktur umwandeln
;
convert_polygon
; r0 = x:Punktearray 2D
; r1 = x:Polygonarray
; r5 = y:Polygonarray umgewandelt
; x0 = Anzahl der Polygone
; ----
; x0 = Neue Anzahl Polygone

	move	#2,n5
	clr		b
	move	b1,r7				; Zähler

	move	x0,a
	tst		a
	jeq		cp_loop1

	do		x0,cp_loop1

	move	x:(r1)+,a			; Anzahl P/P
	move	a1,y:(r5)+
	move	x:(r1)+,x0			; Farbe
	tst		a x0,y:(r5)+
	jne		cp_copy

	lua		(r5)-n5,r5
	jmp		cp_loop2

cp_copy
	move	(r7)+

	do		a1,cp_loop2

	move	r0,b
	move	x:(r1)+,x0			; Nummer von Punkt n
	add		x0,b
	move	b1,r2				; Adresse von Punkt n
	nop
	move	x:(r2)+,x0			; Pnx
	move	x0,y:(r5)+
	move	x:(r2),x0			; Pny
	move	x0,y:(r5)+
cp_loop2

	nop
cp_loop1

	move	r7,x0

	rts

; -----------------------------------------------------------------------------
;
; 3D-Koordinaten in 2D-Koordinaten umrechnen (Zentralprojektion)
;
; Bem.: berechnete Werte werden an die alten Stellen geschrieben!
;
convert_3d_to_2d
; r0 = x:Punktearray 3D
; r1 = x:Punktearray 2D
; r4 = y:Betrachter Position
; x0 = Anzahl der 3D Punkte

	move	x0,a
	tst		a								; Punkte vorhanden?
	jeq		c3dto2d_end						; Nein -> Ende

	lua		(r4)+,r5						; Zy Adresse
	move	#2,n0
	lua		(r5)+,r6						; Zz Adresse

	do		x0,c3dto2d_loop					; Schleife über alle Punkte

	move	x:(r0+n0),a						; Qz
	move	y:(r6),y1						; Zz
	sub		y1,a x:(r0)+n0,x0 y:(r6),y0		; Qz-Zz | Qx | Zz
	move	a1,x1

;
; Px = (Zx * Qz - Qx * Zz) / (Qz - Zz)
;
	mpy		-x0,y0,a x:(r0)-,x0 y:(r4),y0	; -Qx*Zz | Qz | Zx
	mac		x0,y0,a x:(r0)+,x0 y:(r6),y0	; Qz*Zx-Qx*Zz | Qy | Zz

	move	a1,y1
	jpl		*+2
	neg		a
	andi	#$fe,ccr
	rep		#24
	div		x1,a
	jclr	#23,y1,*+3
	neg		a

;
; Py = (Zy * Qz - Qy * Zz) / (Qz - Zz)
;
	mpy		-x0,y0,b x:(r0)+,x0 y:(r5),y0	; -Qy*Zz | Qz | Zy
	mac		x0,y0,b							; Qz*Zy-Qy*Zz

	move	b1,y1
	jpl		*+2
	neg		b
	andi	#$fe,ccr
	rep		#24
	div		x1,b
	jclr	#23,y1,*+3
	neg		b

	move	a0,x:(r1)+
	move	b0,x:(r1)+
	move	(r1)+

c3dto2d_loop
c3dto2d_end

	rts

; -----------------------------------------------------------------------------
;
; Polygone an der z-Ebene clippen (3D-Clipping)
;
; Bem.: Neue Punkte überschreiben Normalenvektoren!
;
clip_polygon_3d
; r0 = x:Punktearray rotiert
; r2 = x:Polygonarray sortiert
; r3 = x:Polygonarray sortiert, 3D-geclippt
; x0 = Anzahl der Polygone
; x1 = Anzahl der Punkte
; ----
; x0 = Neue Anzahl der Punkte
; x1 = Neue Anzahl der Polygone

	move	x0,a
	tst		a				; Noch Polygone vorhanden?
	jne		cp3d_start

	move	x1,x0				; Alte Anzahl Punkte
	move	a1,x1				; Keine Polygone
	rts

cp3d_start

	move	#cp3d_counter,r7
	clr		a
	move	x1,p:(r7)+			; Temp. Zähler für Punkte
	move	a1,p:(r7)-			; Temp. Zähler für Polygone

	move	r0,a
	add		x1,a
	add		x1,a
	add		x1,a
	move	a1,r1				; Zeiger auf Punktearrayende

	move	#2,n5
	move	#2,n6

	do		x0,cp3d_loop1		; Schleife über alle Polygone

	clr	b 	x:(r2)+,a			; Anzahl der Punkte/Polygon
	move	a1,n2
	move	b0,x:(r3)+			; Neue Anzahl (P/P) auf Null
	lua		(r3)+,r4			; Geclippte Punkte
	move	x:(r2)+,x1			; Farbe
	move	x1,x:(r3)-			; Farbe speichern

	do		a1,cp3d_loop2		; Schleife über alle P/P

	move	x:(r2)+,x0			; Nummer von Punkt #0
	move	r0,a
	add		x0,a
	move	a1,r5				; Adresse von Punkt #0
	move	x:(r2)-,x0			; Nummer von Punkt #1
	move	x:(r5+n5),a			; P0z
	move	r0,b
	add		x0,b
	move	b1,r6				; Adresse von Punkt #1

	tst		a					; Liegt P0z hinter der z-Ebene?
	jmi		cp3d_clip			; Ja -> Clipping!

	move	x:(r3),b			; Anzahl der P/P ++
	move	#>1,x0
	add		x0,b
	move	b1,x:(r3)

	move	x:(r2),x0			; Punkt #0 speichern
	move	x0,x:(r4)+

	move	x:(r6+n6),b			; P1z

	tst		b					; Liegt P1z hinter der z-Ebene?
	jpl		cp3d_no_clip		; Nein -> kein Clipping!

	move	a,x0				; Bruch berechnen
	sub		b,a					; P0z-P1z
	move	a1,x1
	move	x0,a
	andi	#$fe,ccr
	rep		#24
	div		x1,a				; P0z/(P0z-P1z)
	move	a0,x0				; F = P0z/(P0z-P1z)

	move	x:(r5)+,y1			; P0x
	move	x:(r6)+,a			; P1x
	sub		y1,a				; P1x-P0x
	move	a1,x1
	move	y1,a
	mac		x0,x1,a				; F*(P1x-P0x)+P0x
	move	a1,x:(r1)+			; P0x geclippt

	move	x:(r5)+n5,y1			; P0y
	move	x:(r6)+n6,a			; P1y
	sub		y1,a				; P1y-P0y
	move	a1,x1
	move	y1,a
	mac		x0,x1,a				; F*(P1y-P0y)+P0y
	move	a1,x:(r1)+			; P0y geclippt

	clr		b
	move	b1,x:(r1)+			; P0z geclippt

	move	x:(r3),b			; Anzahl der Punkte ++
	move	#>1,x0
	add		x0,b
	move	b1,x:(r3)

	move	p:(r7),b
	move	b1,x1
	add		x0,b				; Temp. Punktezähler ++
	move	b1,p:(r7)

	move	x1,b
	add		x1,b				; Speichere Nummer des
	add		x1,b				; geclippten Punktes
	move	b1,x:(r4)+

	jmp		cp3d_no_clip

cp3d_clip
	move	a1,x0
	move	x:(r6+n6),a			; P1z
	tst		a					; Liegt P1z auch hinter
								; der z-Ebene?
	jmi		cp3d_no_clip		; Ja -> kein Clipping!

	move	x0,b

	move	a,x0				; Bruch berechen
	sub		b,a					; P1z-P0z
	move	a1,x1
	move	x0,a
	andi	#$fe,ccr
	rep		#24
	div		x1,a				; P1z/(P1z-P0z)
	move	a0,x0				; F = P1z/(P1z-P0z)

	move	x:(r6)+,y1			; P1x
	move	x:(r5)+,a			; P0x
	sub		y1,a				; P0x-P1x
	move	a1,x1
	move	y1,a
	mac		x0,x1,a				; F*(P0x-P1x)+P1x
	move	a1,x:(r1)+			; P1x geclippt

	move	x:(r6)+n6,y1		; P1y
	move	x:(r5)+n5,a			; P0y
	sub		y1,a				; P0y-P1y
	move	a1,x1
	move	y1,a
	mac		x0,x1,a				; F*(P0y-P1y)+P1y
	move	a1,x:(r1)+			; P1y geclippt

	clr		b
	move	b1,x:(r1)+			; P1z geclippt

	move	x:(r3),b			; Anzahl der Punkte ++
	move	#>1,x0
	add		x0,b
	move	b1,x:(r3)

	move	p:(r7),b
	move	b1,x1
	add		x0,b				; Temp. Punktezähler ++
	move	b1,p:(r7)

	move	x1,b
	add		x1,b				; Speichere Nummer des
	add		x1,b				; geclippten Punktes
	move	b1,x:(r4)+

cp3d_no_clip

	move	(r2)+

cp3d_loop2

	move	(r2)+				; Nächstes Polygon
	move	r4,r3

	move	#>1,x0
	move	(r7)+
	move	p:(r7),b
	add		x0,b				; Polygonzähler ++
	move	b1,p:(r7)-

cp3d_loop1
	move	p:(r7)+,x0			; Neue Anzahl der Punkte
	move	p:(r7)+,x1			; Neue Anzahl der Polygone

	rts

cp3d_counter
	ds	1						; Temp. Punktezähler
	ds	1						; Temp. Polygonzähler

; -----------------------------------------------------------------------------
;
; Flächensortierung mit Hilfe eines BSP-Baums
;
; Bem.: "jsr"-Rekursion ist wegen dem zu kleinen Stack nicht möglich!
;       Abhilfe: eigenes Stacksystem ;)
;
sort_polygon_bsp
; r0 = y:Polygonarray ("hinteres" Polygon)
; r1 = x:Polygonarray sortiert
; r2 = x:Punktearray
; r4 = y:Betrachter Position
; r7 = y:Eigener Stack
; ----
; x0 = Neue Anzahl von Polygonen

	move	#3,n0
	move	n0,n5
	move	#2,n3
	move	n3,n4
	clr		a
	move	a1,r6				; Polygonzähler

	move	#spb_end,y0
	move	y0,y:-(r7)			; Letzte Rücksprungadresse

;
; Rekursives durchschreiten des Baums
;
; n0 = Index
;
spb_recurse

	move	n0,a
	tst		a					; Abbruch?
	jeq		spb_return			; Ja -> Return

;
; Polygon auf Sichtbarkeit testen
;

	lua		(r0)+n0,r3
	move	r2,a
	tfr		a,b y:(r3+n3),x0	; Nummer von Punkt0
	add		x0,a (r3)-
	move	y:(r3),y0			; Nummer der Normale
	move	a1,r3				; Adresse von Punkt0
	add		y0,b y:(r4)+,a		; Cx
	move	b1,r5				; Adresse der Normale
	move	x:(r3)+,x0 y:(r4)+,b		; P0x | Cy
	sub		x0,a x:(r3)+,x1		; Cx-P0x | P0y
	move	x:(r5)+,y0			; Nx
	move	a1,x0
	mpy		x0,y0,a	x:(r5)+,y0	; a = (Cx-P0x)*Nx | Ny
	sub		x1,b x:(r5),y1		; Cy-P0y | Nz
	move	b1,x0
	mac		x0,y0,a	x:(r3),x0 y:(r4),b	; a = a+(Cy-P0y)*Ny | P0z | Cz
	sub		x0,b				; Cz-P0z
	move	b1,x0
	mac		x0,y1,a	(r4)-n4			; a = a+(Cz-P0z)*Nz

	jmi		spb_no_draw			; Nicht sichtbar -> Polygon
								; nicht "zeichnen"

;
; Falls Polygon sichtbar...
;
; Gehe nach hinten
;
	move	n0,y:-(r7)
	move	y:(r0+n0),n0		; Index auf "hinteres" Polygon
	move	#spb_return1,y0
	move	y0,y:-(r7)			; Rücksprungadresse
	jmp		spb_recurse			; Gehe nach "hinten"

spb_return1
;
; Kopiere (zeichne) sichtbares Polygon und berechne seine Lichtfarbe.
;
	lua		(r0)+n0,r5
	move	(r6)+				; Polygonzähler ++
	lua		(r5)-n5,r5
	nop
	move	y:(r5)+,x0			; Anzahl der Punkte/Polygon
	move	x0,a
	move	a1,n1
	move	x0,x:(r1)+
	move	y:(r5)+,b			; Farbe (F)
	move	y:(r5)+,y0			; Zeiger auf Normale

	move	r2,a
	add		y0,a
	move	a1,r3				; Normalenvektoradresse

	move	y:vector_light_ray,y0		; Lx
	move	x:(r3)+,x0			; Nx
	mpy		x0,y0,a
	move	y:vector_light_ray+1,y0		; Ly
	move	x:(r3)+,x0			; Ny
	mac		x0,y0,a
	move	y:vector_light_ray+2,y0		; Lz
	move	x:(r3),x0			; Nz
	mac		x0,y0,a				; Nx*Lx+Ny*Ly+Nz*Lz
	move	a1,x0
	move	#>16,x1
	move 	x1,a				; 16
	mac		-x0,x1,a			; -(Nx*Lx+Ny*Ly+Nz*Lz)*16+16
	add		b,a				; (Nx*Lx+Ny*Ly+Nz*Lz)*16+16+F
	move	a1,x:(r1)+

	move	(r5)+
	move	(r5)+

	move	y:(r5),y0			; Punkt #0
	move	n1,a
	move	a1,x0
	do		x0,spb_loop_copy_polygon	; Alle Punkte kopieren
	move	y:(r5)+,x1
	move	x1,x:(r1)+
spb_loop_copy_polygon

	move	y0,x:(r1)+			; S. Arraybemerkung!

;
; Gehe nach vorne
;
	move	n0,y:-(r7)
	move	(r0)+
	move	y:(r0+n0),n0		; Index auf "vorderes" Polygon
	move	(r0)-
	move	#spb_return,y0
	move	y0,y:-(r7)			; Rücksprungadresse
	jmp		spb_recurse			; Gehe nach "vorne"

spb_no_draw
;
; Falls Polygon nicht sichtbar...
;
; Gehe nach vorne
;
	move	n0,y:-(r7)
	move	(r0)+
	move	y:(r0+n0),n0		; Index auf "vorderes" Polygon
	move	(r0)-
	move	#spb_return2,y0
	move	y0,y:-(r7)			; Rücksprungadresse
	jmp		spb_recurse			; Gehe nach "vorne"

spb_return2

;
; Gehe nach hinten
;
	move	n0,y:-(r7)
	move	y:(r0+n0),n0		; Index auf "hinteres" Polygon
	move	#spb_return,y0
	move	y0,y:-(r7)			; Rücksprungadresse
	jmp		spb_recurse			; Gehe nach "hinten"

spb_return
	move	y:(r7)+,r5
	move	y:(r7)+,n0
	jmp		(r5)				; "Return"

spb_end

	move	r6,x0				; Polygonzähler übergeben

	rts

; -----------------------------------------------------------------------------
;
; Rotationsmatrizen für Kamera, Objekt und beide berechnen
;
make_rotation_matrix
; r0 = x:Objekt Rotationsmatrix
; r4 = y:Objekt sincos-Tabelle + 2
; r5 = y:Kamera sincos-Tabelle + 2
; r6 = y:Kamera Rotationsmatrix
; r7 = y:Gesamt Rotationsmatrix

	move	#2,n4
	move	n4,n5
	lua		(r4)+n4,r2
	lua		(r5)+n5,r3
	move	n4,n2
	move	n4,n3

	move	#8,n0
	move	n0,n6

;
; Objekt-Matrixparameter:
;
; sx bedeutet: sin(x-Winkel), etc.
;
; cy * cz

	move	y:(r2)+,y0			; cy
	move	y:(r2)-n2,y1		; cz
	mpy		y0,y1,a y:(r4)-,y1	; cy * cz | sz
	move	a1,x:(r0)+

; cy * sz

	mpy		y0,y1,a	y:(r4)-,b	; cy * sz | sy
	move	a1,x:(r0)+

; - sy

	neg		b y:(r2)+n2,y0		; - sy | cx
	move	b1,x:(r0)+

; sx * sy * cz - cx * sz

	mpy		-y0,y1,a y:(r4)+,y0	; - cx * sz | sx
	move	y:(r4)+,y1			; sy
	mpy		y0,y1,b y:(r2)-n2,x1	; sx * sy | cz
	move	b1,y0
	mac		y0,x1,a y:(r4)-n4,x0	; sx * sy * cz - cx * sz | sz
	move	a1,x:(r0)+

; sx * sy * sz + cx * cz

	mpy		y0,x0,a y:(r2)+,x0	; sx * sy * sz | cx
	mac		x1,x0,a y:(r2)-,y1	; sx * sy * sz + cx * cz | cy
	move	a1,x:(r0)+

; sx * cy

	move	y:(r4)+n4,y0		; sx
	mpy		y0,y1,a y:(r4)-,y1	; sx * cy | sz
	move	a1,x:(r0)+

; cx * sy * cz + sx * sz

	mpy		y0,y1,a y:(r4)-,y0	; sx * sz | sy
	mpy		x0,y0,b				; cx * sy
	move	b1,y0
	mac		y0,x1,a				; cx * sy * cz + sx * sz
	move	a1,x:(r0)+

; cx * sy * sz - sx * cz

	mpy		y0,y1,a y:(r4),y0	; cx * sy * sz | sx
	mac		-y0,x1,a y:(r2)+,y0	; cx * sy * sz + sx * cz | cx
	move	a1,x:(r0)+

; cx * cy

	move	y:(r2),y1			; cy
	mpy		y0,y1,a				; cx * cy
	move	a1,x:(r0)-n0

;
; Kamera-Matrixparameter:
;
; cy * cz

	move	y:(r3)+,y0			; cy
	move	y:(r3)-n3,y1		; cz
	mpy		y0,y1,a y:(r5)-,y1	; cy * cz | sz
	move	a1,y:(r6)+

; cy * sz

	mpy		y0,y1,a	y:(r5)-,b	; cy * sz | sy
	move	a1,y:(r6)+

; - sy

	neg		b y:(r3)+n3,y0		; - sy | cx
	move	b1,y:(r6)+

; sx * sy * cz - cx * sz

	mpy		-y0,y1,a y:(r5)+,y0	; - cx * sz | sx
	move	y:(r5)+,y1			; sy
	mpy		y0,y1,b y:(r3)-n3,x1	; sx * sy | cz
	move	b1,y0
	mac		y0,x1,a y:(r5)-n5,x0	; sx * sy * cz - cx * sz | sz
	move	a1,y:(r6)+

; sx * sy * sz + cx * cz

	mpy		y0,x0,a y:(r3)+,x0	; sx * sy * sz | cx
	mac		x1,x0,a y:(r3)-,y1	; sx * sy * sz + cx * cz | cy
	move	a1,y:(r6)+

; sx * cy

	move	y:(r5)+n5,y0		; sx
	mpy		y0,y1,a y:(r5)-,y1	; sx * cy | sz
	move	a1,y:(r6)+

; cx * sy * cz + sx * sz

	mpy		y0,y1,a y:(r5)-,y0	; sx * sz | sy
	mpy		x0,y0,b				; cx * sy
	move	b1,y0
	mac		y0,x1,a				; cx * sy * cz + sx * sz
	move	a1,y:(r6)+

; cx * sy * sz - sx * cz

	mpy		y0,y1,a y:(r5),y0	; cx * sy * sz | sx
	mac		-y0,x1,a y:(r3)+,y0	; cx * sy * sz + sx * cz | cx
	move	a1,y:(r6)+

; cx * cy

	move	y:(r3),y1			; cy
	mpy		y0,y1,a				; cx * cy
	move	a1,y:(r6)-n6

;
; Matrizenmultiplikation (Objekt * Kamera) ausführen
;
	move	#3,n6

	move	r0,r1
	move	r6,r5

	do		#3,mrm_loop1

	do		#3,mrm_loop2

	move	x:(r0)+,x0 y:(r6)+n6,y0
	mpy		x0,y0,a x:(r0)+,x0 y:(r6)+n6,y0
	mac		x0,y0,a x:(r0)+,x0 y:(r6)+n6,y0
	mac		x0,y0,a

	move	r5,r6
	move	a1,y:(r7)+

mrm_loop2

	lua		(r5)+,r5
	move	r1,r0
	move	r5,r6

mrm_loop1

	rts

; -----------------------------------------------------------------------------
;
; Punktearray rotieren und translatieren
;
rotate_translate
; r0 = x:Punktearray
; r1 = x:Objekt Position
; r2 = x:Punktearray rotiert
; r4 = y:Rotationsmatrix
; x0 = Anzahl der Punkte

	move	#8,n4

;
; A, B, ..., I : Parameter der Rotationsmatrix
;
	move	x:(r1)+,y1						; xoff
	tfr		y1,a x:(r0)+,x1 y:(r4)+,y0		; x | A

	do		x0,rt_loop1

	mac		x1,y0,a x:(r0)+,x0 y:(r4)+,y0	; x*A+xoff | y | B
	mac		x0,y0,a x:(r0)-,x0 y:(r4)+,y0	; x*A+y*B+xoff | z | C
	mac		x0,y0,a x:(r1)+,x0 y:(r4)+,y0	; x*A+y*B+z*C+xoff | yoff | D
	move	a1,x:(r2)+

	tfr		x0,a x:(r1)-,b					; zoff
	mac		x1,y0,a x:(r0)+,x0 y:(r4)+,y0	; x*D+yoff | y | E
	mac		x0,y0,a x:(r0)-,x0 y:(r4)+,y0	; x*D+y*E+yoff | z | F
	mac		x0,y0,a y:(r4)+,y0				; x*D+y*E+z*F+yoff | G
	move	a1,x:(r2)+

	mac		x1,y0,b x:(r0)+,x0 y:(r4)+,y0	; x*G + zoff | y | H
	mac		x0,y0,b x:(r0)+,x0				; x*G+y*H+zoff | z
	tfr		y1,a y:(r4)-n4,y0				; xoff | I
	mac		x0,y0,b x:(r0)+,x1 y:(r4)+,y0	; x*G+y*H+z*I+zoff | x | A
	move	b1,x:(r2)+

rt_loop1

	rts

; -----------------------------------------------------------------------------
	end
; -----------------------------------------------------------------------------
