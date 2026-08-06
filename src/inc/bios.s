; BIOS 	macro definitions (c) 1994 by Sascha Springer

	macro	Bconin
	move	\1,-(a7)
	move	#2,-(a7)
	trap	#13
	addq	#4,a7
	endm

	macro	Bconout
	move	\2,-(a7)
	move	\1,-(a7)
	move	#3,-(a7)
	trap	#13
	addq	#6,a7
	endm

	macro	Bconstat
	move	\1,-(a7)
	move	#1,-(a7)
	trap	#13
	addq	#4,a7
	endm

	macro	Bcostat
	move	\1,-(a7)
	move	#8,-(a7)
	trap	#13
	addq	#4,a7
	endm

	macro	Drvmap
	move	#10,-(a7)
	trap	#13
	addq	#2,a7
	endm

	macro	Getbpb
	move	\1,-(a7)
	move	#7,-(a7)
	trap	#13
	addq	#4,a7
	endm

	macro	Getmpb
	pea		\1
	clr		-(a7)
	trap	#13
	addq	#6,a7
	endm

	macro	Kbshift
	move	\1,-(a7)
	move	#11,-(a7)
	trap	#13
	addq	#4,a7
	endm

	macro	Mediach
	move	\1,-(a7)
	move	#9,-(a7)
	trap	#13
	addq	#4,a7
	endm

	macro	Rwabs
	move.l	\6,-(a7)
	move	\5,-(a7)
	move	\4,-(a7)
	move	\3,-(a7)
	pea		\2
	move	\1,-(a7)
	move	#4,-(a7)
	trap	#13
	lea		$12(a7),a7
	endm

	macro	Setexc
	pea		\2
	move	\1,-(a7)
	move	#5,-(a7)
	trap	#13
	addq	#8,a7
	endm

	macro	Tickcal
	move	#6,-(a7)
	trap	#13
	addq	#2,a7
	endm

