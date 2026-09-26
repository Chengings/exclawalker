// Test tracer for asm/test.sh on aarch64 Linux: `shortio PROGRAM [ARGS…]`.
// Runs PROGRAM under ptrace and rewrites its read(2) calls on stdin and
// write(2) calls on stdout so that every transfer is short and every third
// call fails with EINTR. Blocking pipes never do this on their own, so without
// it the retry and short-transfer paths go untested.
//
// The Linux assembly port is static with raw syscalls, so LD_PRELOAD can't
// interpose it (the macOS port uses asm/shortio-macos.c instead). ptrace works
// the same on the static assembly and the dynamically linked Rust build.
//
// arm64 specifics: the syscall number can only be changed through the
// NT_ARM_SYSTEM_CALL regset, not x8; setting it to -1 skips the call, and the
// return value is then set in x0 at the syscall-exit stop.
//
// If SHORTIO_LOG names a file, each rewritten call appends one byte to it:
// 'r' short read, 'w' short write, 'i' injected EINTR. The test checks the log
// to prove the tracer actually intercepted something.
//
// Exits with PROGRAM's exit status, or 128 + signal if it was killed, the way
// a shell reports it.

#define _GNU_SOURCE
#include <elf.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/ptrace.h>
#include <sys/syscall.h>
#include <sys/uio.h>
#include <sys/user.h>
#include <sys/wait.h>
#include <unistd.h>

enum { READ_MAX = 3, WRITE_MAX = 7, EINTR_EVERY = 3 };

static int log_fd = -1;
static pid_t child;

static void die(const char *what) {
	perror(what);
	if (child > 0)
		kill(child, SIGKILL);
	exit(125);
}

static void note(char c) {
	if (log_fd >= 0 && write(log_fd, &c, 1) != 1)
		die("write log");
}

static void get_regs(struct user_regs_struct *regs) {
	struct iovec iov = {regs, sizeof *regs};
	if (ptrace(PTRACE_GETREGSET, child, NT_PRSTATUS, &iov) == -1)
		die("PTRACE_GETREGSET");
}

static void set_regs(struct user_regs_struct *regs) {
	struct iovec iov = {regs, sizeof *regs};
	if (ptrace(PTRACE_SETREGSET, child, NT_PRSTATUS, &iov) == -1)
		die("PTRACE_SETREGSET");
}

static void skip_syscall(void) {
	int nr = -1;
	struct iovec iov = {&nr, sizeof nr};
	if (ptrace(PTRACE_SETREGSET, child, NT_ARM_SYSTEM_CALL, &iov) == -1)
		die("PTRACE_SETREGSET NT_ARM_SYSTEM_CALL");
}

// At a syscall-entry stop: shorten or cancel the call. Returns 1 if the call
// was cancelled and needs -EINTR set at its exit stop.
static int on_entry(const struct __ptrace_syscall_info *info) {
	static unsigned reads, writes;
	uint64_t nr = info->entry.nr, fd = info->entry.args[0];
	uint64_t count = info->entry.args[2];
	unsigned *calls;
	uint64_t max;
	char tag;

	if (nr == SYS_read && fd == STDIN_FILENO) {
		calls = &reads, max = READ_MAX, tag = 'r';
	} else if (nr == SYS_write && fd == STDOUT_FILENO) {
		calls = &writes, max = WRITE_MAX, tag = 'w';
	} else {
		return 0;
	}

	if (++*calls % EINTR_EVERY == 0) {
		note('i');
		skip_syscall();
		return 1;
	}
	note(tag);
	if (count > max) {
		struct user_regs_struct regs;
		get_regs(&regs);
		regs.regs[2] = max;
		set_regs(&regs);
	}
	return 0;
}

int main(int argc, char **argv) {
	if (argc < 2) {
		fprintf(stderr, "usage: %s PROGRAM [ARGS...]\n", argv[0]);
		return 2;
	}
	const char *path = getenv("SHORTIO_LOG");
	if (path && (log_fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0600)) == -1)
		die(path);

	child = fork();
	if (child == -1)
		die("fork");
	if (child == 0) {
		if (ptrace(PTRACE_TRACEME, 0, 0, 0) == -1)
			die("PTRACE_TRACEME");
		raise(SIGSTOP); // let the parent set options before exec
		execvp(argv[1], argv + 1);
		die(argv[1]);
	}

	int status;
	if (waitpid(child, &status, 0) == -1 || !WIFSTOPPED(status))
		die("waitpid (initial stop)");
	if (ptrace(PTRACE_SETOPTIONS, child, 0,
		   PTRACE_O_TRACESYSGOOD | PTRACE_O_TRACEEXEC | PTRACE_O_EXITKILL) == -1)
		die("PTRACE_SETOPTIONS");

	int pending_eintr = 0, sig = 0;
	for (;;) {
		if (ptrace(PTRACE_SYSCALL, child, 0, sig) == -1)
			die("PTRACE_SYSCALL");
		sig = 0;
		if (waitpid(child, &status, 0) == -1)
			die("waitpid");
		if (WIFEXITED(status))
			return WEXITSTATUS(status);
		if (WIFSIGNALED(status))
			return 128 + WTERMSIG(status);
		if (!WIFSTOPPED(status))
			continue;

		if (WSTOPSIG(status) == (SIGTRAP | 0x80)) { // syscall stop
			struct __ptrace_syscall_info info;
			if (ptrace(PTRACE_GET_SYSCALL_INFO, child, sizeof info, &info) == -1)
				die("PTRACE_GET_SYSCALL_INFO");
			if (info.op == PTRACE_SYSCALL_INFO_ENTRY) {
				pending_eintr = on_entry(&info);
			} else if (info.op == PTRACE_SYSCALL_INFO_EXIT && pending_eintr) {
				struct user_regs_struct regs;
				get_regs(&regs);
				regs.regs[0] = (uint64_t)-EINTR;
				set_regs(&regs);
				pending_eintr = 0;
			}
		} else if (status >> 8 == (SIGTRAP | (PTRACE_EVENT_EXEC << 8))) {
			// exec event: nothing to deliver
		} else {
			sig = WSTOPSIG(status); // pass real signals (for example SIGPIPE) through
		}
	}
}
