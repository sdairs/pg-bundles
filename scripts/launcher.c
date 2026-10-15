/*
 * Launcher for *-unknown-linux-musl bundles.
 *
 * The bundle's real executables (libexec/<name>) are dynamically linked
 * against musl, and PT_INTERP cannot be relative, so they are never executed
 * by the kernel directly. Instead bin/<name> is this small static binary
 * (one file, hard-linked under every program name), which runs
 *
 *   <root>/libexec/ld/<name> --library-path=<root>/lib --preload= \
 *       --argv0=<root>/bin/<name> -- <root>/libexec/<name> args...
 *
 * libexec/ld/<name> is a symlink to the bundled musl loader,
 * lib/ld-musl-<arch>.so.1, so the bundle's own loader and libc are used on any
 * Linux host, glibc or musl, and no host library is ever loaded. Executing it
 * through a symlink named after the program keeps the process name
 * (/proc/<pid>/comm, what pgrep, pkill and top show) "postgres", "psql", ...
 * rather than "ld-musl-<arch>".
 *
 * --argv0 makes PostgreSQL see bin/<name> as its own path: it derives share/
 * and lib/ from it, and finds sibling programs (initdb -> postgres, pg_ctl ->
 * postgres, pg_dumpall -> pg_dump) as bin/ launchers, so those go through the
 * loader as well. --preload= drops a host LD_PRELOAD (glibc objects) for the
 * bundle's processes; the environment itself is passed on unchanged.
 *
 * Built by scripts/build.sh with: cc -static -Os -s
 */
#define _GNU_SOURCE
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void die(const char *what, const char *arg)
{
	int e = errno;
	fprintf(stderr, "pg-bundles launcher: %s %s: %s\n", what, arg ? arg : "", strerror(e));
	exit(127);
}

int main(int argc, char **argv)
{
	char self[PATH_MAX];
	ssize_t n = readlink("/proc/self/exe", self, sizeof self - 1);

	if (n > 0)
		self[n] = '\0';
	else if (!argv[0] || !strchr(argv[0], '/') || !realpath(argv[0], self))
		die("cannot find own path via /proc/self/exe or argv[0]", argv[0]);

	/* self = <root>/bin/<name> */
	char *slash = strrchr(self, '/');
	if (!slash || slash == self)
		die("unexpected location", self);
	*slash = '\0';
	const char *name = slash + 1;
	const char *bindir = self;
	char *rootend = strrchr(self, '/');
	if (!rootend)
		die("unexpected location", self);
	int rootlen = (int) (rootend - self);

	char ldso[PATH_MAX], prog[PATH_MAX], libpath[PATH_MAX + 32], argv0[PATH_MAX + 32];
	if (snprintf(ldso, sizeof ldso, "%.*s/libexec/ld/%s", rootlen, self, name) >= (int) sizeof ldso ||
		snprintf(prog, sizeof prog, "%.*s/libexec/%s", rootlen, self, name) >= (int) sizeof prog ||
		snprintf(libpath, sizeof libpath, "--library-path=%.*s/lib", rootlen, self) >= (int) sizeof libpath ||
		snprintf(argv0, sizeof argv0, "--argv0=%s/%s", bindir, name) >= (int) sizeof argv0)
	{
		errno = ENAMETOOLONG;
		die("path too long", self);
	}

	char **nargv = calloc((size_t) argc + 6, sizeof *nargv);
	if (!nargv)
		die("out of memory", NULL);
	int i = 0;
	nargv[i++] = ldso;
	nargv[i++] = libpath;
	nargv[i++] = "--preload=";
	nargv[i++] = argv0;
	nargv[i++] = "--";
	nargv[i++] = prog;
	for (int j = 1; j < argc; j++)
		nargv[i++] = argv[j];
	nargv[i] = NULL;

	execv(ldso, nargv);
	die("cannot execute", ldso);
	return 127;
}
