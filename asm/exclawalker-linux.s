// exclawalker — aarch64 Linux port of src/lib.rs + src/main.rs, ASCII only.
// Reads the first line of stdin, trims trailing whitespace, and prints each
// byte as `!c`, space-separated, followed by a newline.
//
// Static, no libc: Linux keeps its syscall ABI stable, so the program talks to
// the kernel directly (svc #0, number in x8, args in x0–x5, result in x0,
// errors as -errno). Same algorithm as exclawalker-macos.s.
//
// Build: as -o exclawalker.o exclawalker-linux.s && ld -static -s -o exclawalker exclawalker.o
// See docs/asm-port.md for design notes and known divergences.

	.equ	SYS_READ, 63
	.equ	SYS_WRITE, 64
	.equ	SYS_EXIT_GROUP, 94
	.equ	SYS_RT_SIGACTION, 134
	.equ	STDIN, 0
	.equ	STDOUT, 1
	.equ	STDERR, 2
	.equ	EINTR, 4
	.equ	EBADF, 9
	.equ	SIGPIPE, 13
	.equ	SIGSET_SIZE, 8		// kernel sigset_t: 64 signals
	.equ	INCAP, 65536		// longest line accepted after trimming
	.equ	READ_CHUNK, 8192	// what Rust's stdin BufReader asks for per read
	.equ	NL, 10
	.equ	SPACE, 32
	.equ	BANG, 33

	.section	.rodata
rerr:	.ascii	"exclawalker: read error\n"
	.equ	RERR_LEN, . - rerr
werr:	.ascii	"exclawalker: write error\n"
	.equ	WERR_LEN, . - werr
lerr:	.ascii	"exclawalker: line too long\n"
	.equ	LERR_LEN, . - lerr

	.text
	.globl	_start
	.type	_start, %function
	.p2align	2

// No stack use; the only call is the local .Ltrim.
//   x19  input buffer base
//   x20  line length
//   x21  output write pointer
//   x22  bytes left to write
//   x23  INCAP
//   x24  line length when whitespace was first dropped (all ones if never)
_start:
	mov	x29, #0			// mark the outermost frame for debuggers
	mov	x30, #0

// Restore SIGPIPE's default action: a parent may have left it ignored, and a
// closed reader should kill the process the same way every time. An all-zero
// kernel struct sigaction is SIG_DFL with no flags and an empty mask.
	mov	x0, #SIGPIPE
	adrp	x1, sigdfl
	add	x1, x1, :lo12:sigdfl
	mov	x2, #0
	mov	x3, #SIGSET_SIZE
	mov	x8, #SYS_RT_SIGACTION
	svc	#0

	adrp	x19, inbuf
	add	x19, x19, :lo12:inbuf
	mov	x20, #0
	ldr	x23, =INCAP		// literal pool: any value assembles
	mov	x24, #-1

// Read until newline or EOF, always asking for READ_CHUNK bytes as Rust does,
// so both leave the same unread bytes on stdin for a later reader. The buffer
// holds INCAP + READ_CHUNK, so a read always fits while the line is ≤ INCAP.
.Lread:
	cmp	x20, x23
	b.hi	.Lover
	mov	x0, #STDIN
	add	x1, x19, x20
	ldr	x2, =READ_CHUNK
	mov	x8, #SYS_READ
	svc	#0
	cmp	x0, #0
	b.eq	.Ldone			// EOF
	b.lt	.Lread_err
	add	x1, x19, x20		// first new byte
	add	x20, x20, x0
	add	x2, x19, x20		// end of new bytes
.Lscan:
	ldrb	w3, [x1], #1
	cmp	w3, #NL
	b.eq	.Lcut
	cmp	x1, x2
	b.lo	.Lscan
	b	.Lread
.Lcut:
	sub	x20, x1, x19
	sub	x20, x20, #1		// drop the newline and anything after it
.Ldone:
	bl	.Ltrim
	cmp	x20, x24		// content after dropped whitespace: too long
	b.hi	.Ltoo_long
	cmp	x20, x23
	b.hi	.Ltoo_long
	b	.Lemit

// Past INCAP with no newline yet. The line still fits only if everything past
// INCAP turns out to be trailing whitespace, so drop that and keep reading.
// Content arriving after dropped whitespace means the untrimmed line already
// exceeded INCAP, so it can't fit: x24 catches that here and at .Ldone.
.Lover:
	bl	.Ltrim
	cmp	x20, x23
	b.hi	.Ltoo_long
	cmp	x20, x24
	b.hi	.Ltoo_long
	mov	x24, x20
	b	.Lread

// Expand each byte c into "!c ", then turn the last space into a newline.
.Lemit:
	adrp	x21, outbuf
	add	x21, x21, :lo12:outbuf
	mov	x0, x21			// write cursor
	mov	x1, x19			// read cursor
	add	x2, x19, x20		// read end
	mov	w4, #BANG
	mov	w5, #SPACE
	cbz	x20, .Lnewline
.Lexpand:
	ldrb	w3, [x1], #1
	strb	w4, [x0]
	strb	w3, [x0, #1]
	strb	w5, [x0, #2]
	add	x0, x0, #3
	cmp	x1, x2
	b.lo	.Lexpand
	sub	x0, x0, #1		// back over the trailing space
.Lnewline:
	mov	w3, #NL
	strb	w3, [x0], #1
	sub	x22, x0, x21

// Write everything, handling short writes.
.Lwrite:
	mov	x0, #STDOUT
	mov	x1, x21
	mov	x2, x22
	mov	x8, #SYS_WRITE
	svc	#0
	cmp	x0, #0
	b.lt	.Lwrite_err
	b.eq	.Lwrite_fail		// no progress (Rust panics here: exit 134)
	add	x21, x21, x0
	subs	x22, x22, x0
	b.ne	.Lwrite
.Lok:
	mov	x0, #0
	b	.Lexit

.Lread_err:
	cmn	x0, #EINTR		// x0 == -EINTR
	b.eq	.Lread
	cmn	x0, #EBADF		// closed stdin reads as empty, as in Rust
	b.eq	.Ldone
	adrp	x1, rerr
	add	x1, x1, :lo12:rerr
	mov	x2, #RERR_LEN
	b	.Lerr_msg

.Lwrite_err:
	cmn	x0, #EINTR
	b.eq	.Lwrite
	cmn	x0, #EBADF		// closed stdout discards output, as in Rust
	b.eq	.Lok
.Lwrite_fail:
	adrp	x1, werr
	add	x1, x1, :lo12:werr
	mov	x2, #WERR_LEN
	b	.Lerr_msg

.Ltoo_long:
	adrp	x1, lerr
	add	x1, x1, :lo12:lerr
	mov	x2, #LERR_LEN
.Lerr_msg:
	mov	x0, #STDERR
	mov	x8, #SYS_WRITE
	svc	#0			// best effort: nothing more to do if this fails
	mov	x0, #1
.Lexit:
	mov	x8, #SYS_EXIT_GROUP
	svc	#0

// Trim trailing whitespace (space or 0x09–0x0D) off the x20-byte line at x19.
// Clobbers x1, w3, w4.
.Ltrim:
	cbz	x20, 2f
	add	x1, x19, x20
	ldurb	w3, [x1, #-1]
	sub	w4, w3, #9
	cmp	w4, #4
	b.ls	1f
	cmp	w3, #SPACE
	b.ne	2f
1:	sub	x20, x20, #1
	b	.Ltrim
2:	ret
	.size	_start, . - _start

	.bss
	.balign	16
sigdfl:	.skip	32			// struct sigaction: handler, flags, restorer, mask
inbuf:	.skip	INCAP + READ_CHUNK
	.balign	16
outbuf:	.skip	INCAP * 3

	.section	.note.GNU-stack, "", %progbits	// non-executable stack
