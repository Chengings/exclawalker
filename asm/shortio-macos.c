// Test shim for asm/test.sh, loaded with DYLD_INSERT_LIBRARIES. Interposes
// read(2) on stdin and write(2) on stdout so that every transfer is short and
// every third call fails with EINTR. Blocking pipes never do this on their own,
// so without the shim the retry and short-transfer paths go untested.
//
// If SHORTIO_LOG names a file, each intercepted call appends one byte to it:
// 'r' short read, 'w' short write, 'i' injected EINTR. The test checks the log
// to prove the shim was actually loaded.
//
// Interposing layout from dyld's include/mach-o/dyld-interposing.h (built for
// arm64, not arm64e, so no pointer authentication applies).

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <unistd.h>

enum { READ_MAX = 3, WRITE_MAX = 7, EINTR_EVERY = 3 };

static int log_fd = -1;

__attribute__((constructor)) static void open_log(void) {
	const char *path = getenv("SHORTIO_LOG");
	if (path)
		log_fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0600);
}

static void note(char c) {
	if (log_fd >= 0)
		(void)write(log_fd, &c, 1); // our own calls are not interposed
}

// Returns 1 when this call should fail with EINTR instead.
static int inject_eintr(unsigned *calls) {
	if (++*calls % EINTR_EVERY)
		return 0;
	note('i');
	errno = EINTR;
	return 1;
}

static ssize_t short_read(int fd, void *buf, size_t n) {
	static unsigned calls;
	if (fd == STDIN_FILENO) {
		if (inject_eintr(&calls))
			return -1;
		note('r');
		if (n > READ_MAX)
			n = READ_MAX;
	}
	return read(fd, buf, n);
}

static ssize_t short_write(int fd, const void *buf, size_t n) {
	static unsigned calls;
	if (fd == STDOUT_FILENO) {
		if (inject_eintr(&calls))
			return -1;
		note('w');
		if (n > WRITE_MAX)
			n = WRITE_MAX;
	}
	return write(fd, buf, n);
}

__attribute__((used, section("__DATA,__interpose,interposing")))
static const struct {
	const void *replacement;
	const void *replacee;
} interposers[] = {
	{(const void *)(unsigned long)&short_read, (const void *)(unsigned long)&read},
	{(const void *)(unsigned long)&short_write, (const void *)(unsigned long)&write},
};
