/* Mi Box S initramfs init: tries a USB root (ext4 with /sbin/init) in host mode, else falls back to a gadget-serial shell. */
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <dirent.h>
#include <stdint.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/ioctl.h>
#include <sys/reboot.h>
#include <time.h>

#define HOST_WAIT 30

static int kmsg = -1;
static void say(const char *fmt, ...) {
    char b[512]; va_list ap; va_start(ap, fmt); int n = vsnprintf(b, sizeof b - 2, fmt, ap); va_end(ap);
    b[n++] = '\n'; if (kmsg >= 0) write(kmsg, b, n); write(1, b, n);
}
static void usbreg(int memfd) {   /* Android's own write before USB works: 0xc883443c = 0xFDFFFFFF */
    long pg = 4096; off_t a = 0xc883443cUL;
    volatile uint32_t *m = mmap(0, pg, PROT_READ | PROT_WRITE, MAP_SHARED, memfd, a & ~(pg - 1));
    if (m == MAP_FAILED) { say("MIBOX: mmap reg failed: %s", strerror(errno)); return; }
    volatile uint32_t *r = m + ((a & (pg - 1)) / 4);
    uint32_t old = *r; *r = 0xFDFFFFFF; say("MIBOX: reg 0xc883443c %08x -> %08x", old, *r);
}
static void sh_on(const char *tty) {   /* respawning root shell on a tty */
    if (fork() == 0) {
        for (;;) {
            pid_t c = fork();
            if (c == 0) {
                setsid(); int fd = -1;
                for (int i = 0; i < 600 && fd < 0; i++) { fd = open(tty, O_RDWR); if (fd < 0) sleep(1); }
                if (fd < 0) _exit(1);
                ioctl(fd, TIOCSCTTY, 1);
                dup2(fd, 0); dup2(fd, 1); dup2(fd, 2);
                setenv("PATH", "/bin:/sbin", 1);
                execl("/bin/busybox", "sh", (char *)0); _exit(1);
            }
            int st; waitpid(c, &st, 0); sleep(1);
        }
    }
}
static int set_role(const char *role) {
    DIR *d = opendir("/sys/class/usb_role"); struct dirent *e; int ok = -1;
    if (!d) { say("MIBOX: no /sys/class/usb_role"); return -1; }
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        char p[300]; snprintf(p, sizeof p, "/sys/class/usb_role/%s/role", e->d_name);
        int fd = open(p, O_WRONLY);
        if (fd >= 0) { ok = write(fd, role, strlen(role)) > 0 ? 0 : -1; close(fd); say("MIBOX: role %s -> %s (%s)", e->d_name, role, ok ? "FAILED" : "ok"); }
    }
    closedir(d); return ok;
}
static int mount_root(const char *dev) {
    mkdir("/newroot", 0755);
    if (access(dev, F_OK)) return -1;
    if (mount(dev, "/newroot", "ext4", MS_NOATIME, 0) == 0) {
        if (!access("/newroot/sbin/init", X_OK) || !access("/newroot/usr/lib/systemd/systemd", X_OK)) {
            say("MIBOX: root found on %s", dev); return 0;
        }
        say("MIBOX: %s is ext4 but has no /sbin/init", dev); umount("/newroot");
    } else say("MIBOX: %s: not mountable as ext4 (%s)", dev, strerror(errno));
    return -1;
}
static int try_root(void) {
    static const char *names[] = { "sda", "sdb", "sdc", "sdd", 0 };
    for (int i = 0; names[i]; i++) for (int part = 1; part <= 4; part++) {
        char dev[64]; snprintf(dev, sizeof dev, "/dev/%s%d", names[i], part);
        if (!mount_root(dev)) return 0;
    }
    return -1;
}
static void do_switch(void) {
    say("MIBOX: switching root");
    mount("/dev", "/newroot/dev", 0, MS_MOVE, 0); mount("/proc", "/newroot/proc", 0, MS_MOVE, 0); mount("/sys", "/newroot/sys", 0, MS_MOVE, 0);
    chdir("/newroot");
    execl("/bin/busybox", "switch_root", "/newroot", "/sbin/init", (char *)0);
    say("MIBOX: switch_root failed: %s", strerror(errno));
}
/* background logger: copies /dev/kmsg to a file on the stick's FAT partition (fd inherited, survives switch_root) */
static void start_logger(void) {
    static const char *names[] = { "sda1", "sdb1", "sdc1", 0 };
    mkdir("/bootfat", 0755);
    for (int i = 0; names[i]; i++) {
        char dev[64]; snprintf(dev, sizeof dev, "/dev/%s", names[i]);
        if (access(dev, F_OK) || mount(dev, "/bootfat", "vfat", MS_NOATIME, 0)) continue;
        char lname[64]; int lf = -1;
        for (int n = 1; n < 100 && lf < 0; n++) { snprintf(lname, sizeof lname, "/bootfat/mibox-%02d.log", n); lf = open(lname, O_WRONLY | O_CREAT | O_EXCL, 0644); }
        int kf = open("/dev/kmsg", O_RDONLY);
        if (lf < 0 || kf < 0) { say("MIBOX: logger: cannot open files (%s)", strerror(errno)); return; }
        say("MIBOX: logging kernel messages to %s:%s", dev, lname + 8);
        if (fork() == 0) {
            char b[8192]; char o[8300]; time_t last = 0;
            for (;;) {
                ssize_t n = read(kf, b, sizeof b - 1);
                if (n < 0) { if (errno == EPIPE) continue; if (errno == EAGAIN) { sleep(1); continue; } sleep(1); continue; }
                b[n] = 0; int m = snprintf(o, sizeof o, "%s", b);
                if (write(lf, o, m) < 0) _exit(0);   /* give up on the first write error (no retry storm) */
                time_t t = time(0); if (t != last) { fsync(lf); last = t; }
            }
        }
        return;
    }
    say("MIBOX: logger: no FAT partition found");
}
static void rw_test(void) {
    int fd = open("/newroot/.mibox-rwtest", O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) { say("MIBOX: new root is NOT writable: %s", strerror(errno)); return; }
    write(fd, "x", 1); fsync(fd); close(fd); unlink("/newroot/.mibox-rwtest"); say("MIBOX: new root is writable");
}
static void log_sdio(void) {
    DIR *d = opendir("/sys/bus/sdio/devices"); struct dirent *e;
    if (!d) { say("MIBOX: no sdio devices dir"); return; }
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        char p[300], v[32] = "?", dv[32] = "?", cl[32] = "?"; FILE *f;
        snprintf(p, sizeof p, "/sys/bus/sdio/devices/%s/vendor", e->d_name); if ((f = fopen(p, "r"))) { fgets(v, sizeof v, f); fclose(f); }
        snprintf(p, sizeof p, "/sys/bus/sdio/devices/%s/device", e->d_name); if ((f = fopen(p, "r"))) { fgets(dv, sizeof dv, f); fclose(f); }
        snprintf(p, sizeof p, "/sys/bus/sdio/devices/%s/class", e->d_name); if ((f = fopen(p, "r"))) { fgets(cl, sizeof cl, f); fclose(f); }
        v[strcspn(v, "\n")] = 0; dv[strcspn(dv, "\n")] = 0; cl[strcspn(cl, "\n")] = 0;
        say("MIBOX: sdio %s vendor=%s device=%s class=%s", e->d_name, v, dv, cl);
    }
    closedir(d);
}
int main(void) {
    mount("proc", "/proc", "proc", 0, 0); mount("sysfs", "/sys", "sysfs", 0, 0); mount("devtmpfs", "/dev", "devtmpfs", 0, 0);
    mount("pstore", "/sys/fs/pstore", "pstore", 0, 0);
    kmsg = open("/dev/kmsg", O_WRONLY);
    say("MIBOX: init started, pid %d", getpid());
    int mf = open("/dev/mem", O_RDWR | O_SYNC);
    if (mf < 0) say("MIBOX: /dev/mem: %s", strerror(errno)); else usbreg(mf);
    log_sdio();
    sh_on("/dev/ttyGS0");
    /* 1. internal eMMC root (kernel cmdline blkdevparts maps the old Android userdata area to mmcblk1p1) */
    for (int i = 0; i < 15 && access("/dev/mmcblk1p1", F_OK); i++) sleep(1);
    if (!mount_root("/dev/mmcblk1p1")) {
        set_role("host");          /* port becomes a normal USB host for Armbian (keyboard, stick) */
        rw_test(); do_switch();
    }
    say("MIBOX: no eMMC root, switching USB port to host, waiting up to %d s for a USB root", HOST_WAIT);
    if (set_role("host") == 0) {
        for (int i = 0; i < HOST_WAIT; i++) {
            sleep(1);
            if (!try_root()) {
                rw_test(); start_logger(); do_switch();
                break;
            }
        }
        say("MIBOX: no usable USB root, switching back to device mode");
        set_role("device");
    }
    sh_on("/dev/tty0");
    say("MIBOX: shell on /dev/ttyGS0 (PC: /dev/ttyACM0) and tty0");
    for (int i = 0;; i++) { sleep(1); if (i % 30 == 0) say("MIBOX: alive %d", i); }
    return 0;
}
