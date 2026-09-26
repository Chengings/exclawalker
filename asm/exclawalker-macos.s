// exclawalker — arm64 macOS port of src/lib.rs + src/main.rs, ASCII only.
// Reads the first line of stdin, trims trailing whitespace, and prints each
// byte as `!c`, space-separated, followed by a newline.
//
// Build: clang -arch arm64 -o exclawalker exclawalker-macos.s
// See docs/asm-port.md for design notes and known divergences.

	.equ	STDIN, 0
	.equ	STDOUT, 1
	.equ	STDERR, 2
	.equ	EINTR, 4
	.equ	EBADF, 9
	.equ	SIGPIPE, 13
	.equ	SIG_DFL, 0
	.equ	INCAP, 65536		// longest line accepted after trimming
	.equ	READ_CHUNK, 8192	// what Rust's stdin BufReader asks for per read
	.equ	NL, 10
	.equ	SPACE, 32
	.equ	BANG, 33

	.section	__TEXT,__const
rerr:	.ascii	"exclawalker: read error\n"
	.equ	RERR_LEN, . - rerr
werr:	.ascii	"exclawalker: write error\n"
	.equ	WERR_LEN, . - werr
lerr:	.ascii	"exclawalker: line too long\n"
	.equ	LERR_LEN, . - lerr

	.section	__TEXT,__text,regular,pure_instructions
	.globl	_main
	.p2align	2

// Register use across calls (callee-saved):
//   x19  input buffer base
//   x20  line length
//   x21  output write pointer
//   x22  bytes left to write
//   x23  INCAP
//   x24  line length when whitespace was first dropped (all ones if never)
_main:
	stp	x29, x30, [sp, #-64]!
	mov	x29, sp
	stp	x19, x20, [sp, #16]
	stp	x21, x22, [sp, #32]
	stp	x23, x24, [sp, #48]

// Restore SIGPIPE's default action: a parent may have left it ignored, and a
// closed reader should kill the process the same way every time.
	mov	w0, #SIGPIPE
	mov	x1, #SIG_DFL
	bl	_signal

	adrp	x19, inbuf@PAGE
	add	x19, x19, inbuf@PAGEOFF
	mov	x20, #0
	ldr	x23, =INCAP		// literal pool: any value assembles
	mov	x24, #-1

// Read until newline or EOF, always asking for READ_CHUNK bytes as Rust does,
// so both leave the same unread bytes on stdin for a later reader. The buffer
// holds INCAP + READ_CHUNK, so a read always fits while the line is ≤ INCAP.
Lread:
	cmp	x20, x23
	b.hi	Lover
	mov	x0, #STDIN
	add	x1, x19, x20
	ldr	x2, =READ_CHUNK
	bl	_read
	cmp	x0, #0
	b.eq	Ldone			// EOF
	b.lt	Lread_err
	add	x1, x19, x20		// first new byte
	add	x20, x20, x0
	add	x2, x19, x20		// end of new bytes
Lscan:
	ldrb	w3, [x1], #1
	cmp	w3, #NL
	b.eq	Lcut
	cmp	x1, x2
	b.lo	Lscan
	b	Lread
Lcut:
	sub	x20, x1, x19
	sub	x20, x20, #1		// drop the newline and anything after it
Ldone:
	bl	Ltrim
	cmp	x20, x24		// content after dropped whitespace: too long
	b.hi	Ltoo_long
	cmp	x20, x23
	b.hi	Ltoo_long
	b	Lemit

// Past INCAP with no newline yet. The line still fits only if everything past
// INCAP turns out to be trailing whitespace, so drop that and keep reading.
// Content arriving after dropped whitespace means the untrimmed line already
// exceeded INCAP, so it can't fit: x24 catches that here and at Ldone.
Lover:
	bl	Ltrim
	cmp	x20, x23
	b.hi	Ltoo_long
	cmp	x20, x24
	b.hi	Ltoo_long
	mov	x24, x20
	b	Lread

// Expand each byte c into "!c ", then turn the last space into a newline.
Lemit:
	adrp	x21, outbuf@PAGE
	add	x21, x21, outbuf@PAGEOFF
	mov	x0, x21			// write cursor
	mov	x1, x19			// read cursor
	add	x2, x19, x20		// read end
	mov	w4, #BANG
	mov	w5, #SPACE
	cbz	x20, Lnewline
Lexpand:
	ldrb	w3, [x1], #1
	strb	w4, [x0]
	strb	w3, [x0, #1]
	strb	w5, [x0, #2]
	add	x0, x0, #3
	cmp	x1, x2
	b.lo	Lexpand
	sub	x0, x0, #1		// back over the trailing space
Lnewline:
	mov	w3, #NL
	strb	w3, [x0], #1
	sub	x22, x0, x21

// Write everything, handling short writes.
Lwrite:
	mov	x0, #STDOUT
	mov	x1, x21
	mov	x2, x22
	bl	_write
	cmp	x0, #0
	b.lt	Lwrite_err
	b.eq	Lwrite_fail		// no progress (Rust panics here: exit 134)
	add	x21, x21, x0
	subs	x22, x22, x0
	b.ne	Lwrite
Lok:
	mov	w0, #0
Lret:
	ldp	x23, x24, [sp, #48]
	ldp	x21, x22, [sp, #32]
	ldp	x19, x20, [sp, #16]
	ldp	x29, x30, [sp], #64
	ret

Lread_err:
	bl	___error
	ldr	w0, [x0]
	cmp	w0, #EINTR
	b.eq	Lread
	cmp	w0, #EBADF		// closed stdin reads as empty, as in Rust
	b.eq	Ldone
	adrp	x1, rerr@PAGE
	add	x1, x1, rerr@PAGEOFF
	mov	x2, #RERR_LEN
	b	Lerr_msg

Lwrite_err:
	bl	___error
	ldr	w0, [x0]
	cmp	w0, #EINTR
	b.eq	Lwrite
	cmp	w0, #EBADF		// closed stdout discards output, as in Rust
	b.eq	Lok
Lwrite_fail:
	adrp	x1, werr@PAGE
	add	x1, x1, werr@PAGEOFF
	mov	x2, #WERR_LEN
	b	Lerr_msg

Ltoo_long:
	adrp	x1, lerr@PAGE
	add	x1, x1, lerr@PAGEOFF
	mov	x2, #LERR_LEN
Lerr_msg:
	mov	x0, #STDERR
	bl	_write
	mov	w0, #1
	b	Lret

// Trim trailing whitespace (space or 0x09–0x0D) off the x20-byte line at x19.
// A leaf: no frame needed. Clobbers x1, w3, w4.
Ltrim:
	cbz	x20, 2f
	add	x1, x19, x20
	ldurb	w3, [x1, #-1]
	sub	w4, w3, #9
	cmp	w4, #4
	b.ls	1f
	cmp	w3, #SPACE
	b.ne	2f
1:	sub	x20, x20, #1
	b	Ltrim
2:	ret

	.zerofill	__DATA,__bss,inbuf,INCAP+READ_CHUNK,4
	.zerofill	__DATA,__bss,outbuf,INCAP*3,4
