// SPDX-License-Identifier: GPL-2.0
/*
 * iobench -- random-read latency probe for comparing block I/O schedulers.
 *
 * Why it exists
 * -------------
 * The device has no fio, and driving toybox dd from shell measures process
 * spawn (~1-3 ms) rather than the disk (~50-200 us for a 4K UFS read), so the
 * signal would be buried 10-50x under the noise. What actually decides whether
 * an I/O scheduler helps a phone is the LATENCY DISTRIBUTION of small random
 * reads while other I/O is in flight -- the app-launch pattern -- so this
 * reports percentiles, not averages.
 *
 * Why freestanding
 * ----------------
 * The only cross toolchain here is the AOSP kernel clang, which ships no
 * bionic sysroot, and installing a full NDK to get one is a poor trade for a
 * ~200 line probe. So this talks to the kernel directly: no libc, no headers,
 * raw aarch64 syscalls. It also means one process does one job, and the caller
 * supplies concurrency by launching several instances -- no threads needed.
 *
 * Safety
 * ------
 * The target is opened O_RDONLY. This tool cannot write anything, anywhere.
 *
 * Build:
 *   clang --target=aarch64-linux-android31 -O2 -ffreestanding -nostdlib \
 *         -static -Wl,-e,_start -o iobench iobench.c
 *
 * Usage:
 *   iobench <device> <seconds> <seed>
 *
 * Output (one line, machine readable):
 *   n=<reads> iops=<n/s> avg=<us> p50= p95= p99= p999= max=
 */

typedef unsigned long u64;
typedef long s64;
typedef unsigned int u32;

/* ------------------------------------------------------------ syscalls --- */

static inline s64 sys(s64 n, s64 a, s64 b, s64 c, s64 d, s64 e)
{
	register s64 x8 __asm__("x8") = n;
	register s64 x0 __asm__("x0") = a;
	register s64 x1 __asm__("x1") = b;
	register s64 x2 __asm__("x2") = c;
	register s64 x3 __asm__("x3") = d;
	register s64 x4 __asm__("x4") = e;

	__asm__ volatile("svc #0"
			 : "+r"(x0)
			 : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4)
			 : "memory", "cc");
	return x0;
}

#define SYS_openat		56
#define SYS_close		57
#define SYS_pread64		67
#define SYS_write		64
#define SYS_exit_group		94
#define SYS_clock_gettime	113
#define SYS_ioctl		29

#define AT_FDCWD		-100
#define O_RDONLY		0
#define O_DIRECT		0x10000
#define BLKGETSIZE64		0x80081272UL
#define CLOCK_MONOTONIC		1

struct timespec { s64 sec; s64 nsec; };

static u64 now_ns(void)
{
	struct timespec ts;

	sys(SYS_clock_gettime, CLOCK_MONOTONIC, (s64)&ts, 0, 0, 0);
	return (u64)ts.sec * 1000000000ul + (u64)ts.nsec;
}

/* ------------------------------------------------------------- output --- */

static char obuf[512];
static int olen;

static void emit(const char *s)
{
	while (*s && olen < (int)sizeof(obuf) - 1)
		obuf[olen++] = *s++;
}

static void emit_u64(u64 v)
{
	char tmp[24];
	int i = 0;

	if (!v) {
		emit("0");
		return;
	}
	while (v) {
		tmp[i++] = (char)('0' + (v % 10));
		v /= 10;
	}
	while (i-- > 0 && olen < (int)sizeof(obuf) - 1)
		obuf[olen++] = tmp[i];
}

static void flush_out(void)
{
	obuf[olen++] = '\n';
	sys(SYS_write, 1, (s64)obuf, olen, 0, 0);
}

/* --------------------------------------------------------- histogram --- */
/*
 * Buckets: 1 us resolution up to 2047 us, then 16 us up to ~33 ms, then one
 * overflow bin. Percentiles come straight out of the counts -- no sorting, no
 * big allocation, and full precision exactly where phone I/O latency lives.
 */
#define FINE	2048
#define COARSE	2048
#define NBINS	(FINE + COARSE + 1)

static u32 hist[NBINS];

static int bin_of(u64 us)
{
	if (us < FINE)
		return (int)us;
	if (us < FINE + (u64)COARSE * 16)
		return FINE + (int)((us - FINE) / 16);
	return NBINS - 1;
}

static u64 bin_floor_us(int b)
{
	if (b < FINE)
		return (u64)b;
	if (b < FINE + COARSE)
		return FINE + (u64)(b - FINE) * 16;
	return FINE + (u64)COARSE * 16;
}

static u64 percentile(u64 total, double p)
{
	u64 want = (u64)(p / 100.0 * (double)total);
	u64 acc = 0;
	int b;

	if (!want)
		want = 1;
	for (b = 0; b < NBINS; b++) {
		acc += hist[b];
		if (acc >= want)
			return bin_floor_us(b);
	}
	return bin_floor_us(NBINS - 1);
}

/* -------------------------------------------------------------- main --- */

static u64 rnd(u64 *s)
{
	u64 x = *s;

	x ^= x << 13;
	x ^= x >> 7;
	x ^= x << 17;
	return *s = x;
}

static u64 parse_u64(const char *s)
{
	u64 v = 0;

	while (*s >= '0' && *s <= '9')
		v = v * 10 + (u64)(*s++ - '0');
	return v;
}

#define BLK 4096
static char buf[BLK] __attribute__((aligned(BLK)));

void _start_c(long argc, char **argv)
{
	const char *dev;
	u64 secs, seed, devsz = 0, nblocks, deadline, t_start;
	u64 n = 0, sum_us = 0, maxus = 0;
	int fd;

	if (argc < 4) {
		emit("usage: iobench <device> <seconds> <seed>");
		flush_out();
		sys(SYS_exit_group, 2, 0, 0, 0, 0);
	}

	dev = argv[1];
	secs = parse_u64(argv[2]);
	seed = parse_u64(argv[3]);
	if (!seed)
		seed = 0x9e3779b97f4a7c15ul;
	if (!secs)
		secs = 10;

	fd = (int)sys(SYS_openat, AT_FDCWD, (s64)dev, O_RDONLY | O_DIRECT, 0, 0);
	if (fd < 0) {
		emit("error=open");
		flush_out();
		sys(SYS_exit_group, 1, 0, 0, 0, 0);
	}

	if (sys(SYS_ioctl, fd, (s64)BLKGETSIZE64, (s64)&devsz, 0, 0) < 0 || !devsz) {
		emit("error=size");
		flush_out();
		sys(SYS_exit_group, 1, 0, 0, 0, 0);
	}

	nblocks = devsz / BLK;
	t_start = now_ns();
	deadline = t_start + secs * 1000000000ul;

	for (;;) {
		u64 off, t0, t1, us;

		t0 = now_ns();
		if (t0 >= deadline)
			break;

		off = (rnd(&seed) % nblocks) * BLK;
		if (sys(SYS_pread64, fd, (s64)buf, BLK, (s64)off, 0) != BLK)
			break;

		t1 = now_ns();
		us = (t1 - t0) / 1000;

		hist[bin_of(us)]++;
		sum_us += us;
		if (us > maxus)
			maxus = us;
		n++;
	}

	sys(SYS_close, fd, 0, 0, 0, 0);

	if (n < 50) {
		emit("error=too_few_samples n=");
		emit_u64(n);
		flush_out();
		sys(SYS_exit_group, 1, 0, 0, 0, 0);
	}

	emit("n=");        emit_u64(n);
	emit(" iops=");    emit_u64(n / secs);
	emit(" avg=");     emit_u64(sum_us / n);
	emit(" p50=");     emit_u64(percentile(n, 50.0));
	emit(" p95=");     emit_u64(percentile(n, 95.0));
	emit(" p99=");     emit_u64(percentile(n, 99.0));
	emit(" p999=");    emit_u64(percentile(n, 99.9));
	emit(" max=");     emit_u64(maxus);
	flush_out();

	sys(SYS_exit_group, 0, 0, 0, 0, 0);
}

/*
 * Entry point. The kernel hands us the stack with argc at [sp] and argv just
 * above it, so hand those to the C function and never return.
 */
__asm__(
".global _start\n"
"_start:\n"
"	ldr x0, [sp]\n"
"	add x1, sp, #8\n"
"	bl _start_c\n"
"	mov x8, #94\n"
"	mov x0, #0\n"
"	svc #0\n"
);
