#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/statfs.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define CLUSTER_BYTES (16 * 1024ULL)
#define PAIR_BYTES (32 * 1024ULL)
#define READ_BYTES (4 * 1024ULL)
#define BUFFER_BYTES (256 * 1024ULL)
#define TMPFS_MAGIC 0x01021994
#define F2FS_MAGIC 0xF2F52010

enum operation { OP_WRITE, OP_SEQ_READ, OP_RAND_READ };
struct entry { char *rel; uint64_t size; int is_dir; };
struct collection { struct entry *v; size_t len, cap; size_t symlinks; uint64_t regular_bytes, regular_files; };
struct devstat { uint64_t read_ios, read_sectors, write_ios, write_sectors; };
struct file_record { const char *rel; uint64_t original_bytes, bytes, calls; int active; double secs; };
struct job {
    enum operation op;
    int input_fd, output_fd;
    uint64_t size, start, end, nreq, req_start, req_end;
    const uint64_t *random_clusters;
    uint64_t seed, bytes, calls;
    int err;
};
struct options {
    const char *source, *target, *device, *per_file_csv, *summary_csv, *label;
    enum operation op;
    int op_set, threads, cold;
    uint64_t seed;
};

static void usage(const char *program) {
    fprintf(stderr,
        "Usage: %s --mode write|seqread|randread --source FILE_OR_DIR --target DIR --threads N\\n"
        "          [--device /dev/nvme1n1] [--cold] [--seed 2027] [--per-file-csv FILE]\\n"
        "  write: target must be absent or empty; write real bytes, finish with syncfs().\\n"
        "  reads: target must contain files from a previous write; --cold is required.\\n"
        "  seqread: full-file sequential read. randread: one 4KiB read per 16KiB cluster.\\n"
        "  all modes: process files one by one, with N threads inside each file.\\n", program);
}
static void fatal(const char *s) { perror(s); exit(EXIT_FAILURE); }
static void *must_malloc(size_t n) { void *p = malloc(n ? n : 1); if (!p) fatal("malloc"); return p; }
static char *join(const char *a, const char *b) {
    char *out;
    if (asprintf(&out, "%s/%s", a, b) < 0) fatal("asprintf");
    return out;
}
static double seconds_now(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts)) fatal("clock_gettime");
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1000000000.0;
}
static uint64_t splitmix64(uint64_t *state) {
    uint64_t z = (*state += UINT64_C(0x9e3779b97f4a7c15));
    z = (z ^ (z >> 30)) * UINT64_C(0xbf58476d1ce4e5b9);
    z = (z ^ (z >> 27)) * UINT64_C(0x94d049bb133111eb);
    return z ^ (z >> 31);
}
static uint64_t stable_hash(const char *s) {
    uint64_t h = UINT64_C(14695981039346656037);
    while (*s) { h ^= (unsigned char)*s++; h *= UINT64_C(1099511628211); }
    return h;
}
static void append_entry(struct collection *c, const char *rel, uint64_t size, int is_dir) {
    if (c->len == c->cap) {
        size_t nc = c->cap ? c->cap * 2 : 128;
        struct entry *tmp = realloc(c->v, nc * sizeof(*tmp));
        if (!tmp) fatal("realloc");
        c->v = tmp; c->cap = nc;
    }
    c->v[c->len++] = (struct entry){strdup(rel), size, is_dir};
    if (!c->v[c->len-1].rel) fatal("strdup");
    if (!is_dir) { c->regular_files++; c->regular_bytes += size; }
}
static void walk(const char *base, const char *rel, struct collection *c) {
    char *path = *rel ? join(base, rel) : strdup(base);
    if (!path) fatal("strdup");
    struct dirent **names = NULL;
    int n = scandir(path, &names, NULL, alphasort);
    if (n < 0) fatal(path);
    for (int i = 0; i < n; i++) {
        const char *name = names[i]->d_name;
        if (strcmp(name, ".") && strcmp(name, "..")) {
            char *child_rel = *rel ? join(rel, name) : strdup(name);
            if (!child_rel) fatal("strdup");
            char *full = join(base, child_rel);
            struct stat st;
            if (lstat(full, &st)) fatal(full);
            if (S_ISDIR(st.st_mode)) {
                append_entry(c, child_rel, 0, 1);
                walk(base, child_rel, c);
            } else if (S_ISREG(st.st_mode)) {
                append_entry(c, child_rel, (uint64_t)st.st_size, 0);
            } else if (S_ISLNK(st.st_mode)) {
                c->symlinks++;  /* skip links, as in the original logical-size script */
            }
            free(full);
            free(child_rel);
        }
        free(names[i]);
    }
    free(names);
    free(path);
}
static void collect_source(const char *source, struct collection *c, char **base_out) {
    struct stat st;
    if (lstat(source, &st)) fatal(source);
    if (S_ISREG(st.st_mode)) {
        char *dup = strdup(source), *slash;
        if (!dup) fatal("strdup");
        slash = strrchr(dup, '/');
        if (slash) {
            char *fname = strdup(slash + 1);
            if (!fname) fatal("strdup");
            if (slash == dup) slash[1] = '\0'; else *slash = '\0';
            *base_out = strdup(dup);
            if (!*base_out) fatal("strdup");
            append_entry(c, fname, (uint64_t)st.st_size, 0);
            free(fname);
        } else {
            *base_out = strdup(".");
            if (!*base_out) fatal("strdup");
            append_entry(c, dup, (uint64_t)st.st_size, 0);
        }
        free(dup);
    } else if (S_ISDIR(st.st_mode)) {
        *base_out = strdup(source);
        if (!*base_out) fatal("strdup");
        walk(*base_out, "", c);
    } else {
        fprintf(stderr, "Source must be a regular file or directory: %s\n", source);
        exit(EXIT_FAILURE);
    }
}
static void ensure_parents(const char *path) {
    char *buf = strdup(path);
    if (!buf) fatal("strdup");
    for (char *p = buf + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            if (mkdir(buf, 0755) && errno != EEXIST) fatal(buf);
            *p = '/';
        }
    }
    free(buf);
}
static int directory_empty(const char *path) {
    DIR *dir = opendir(path);
    if (!dir) fatal(path);
    struct dirent *e;
    while ((e = readdir(dir))) {
        if (strcmp(e->d_name, ".") && strcmp(e->d_name, "..")) {
            closedir(dir); return 0;
        }
    }
    closedir(dir); return 1;
}
static void csv_string(FILE *f, const char *s) {
    fputc('"', f);
    for (; *s; s++) { if (*s == '"') fputc('"', f); fputc(*s, f); }
    fputc('"', f);
}
static void prepare_target(const struct options *o) {
    struct stat st;
    if (lstat(o->target, &st) == 0) {
        if (!S_ISDIR(st.st_mode)) { fprintf(stderr, "Target not directory: %s\n", o->target); exit(EXIT_FAILURE); }
        if (o->op == OP_WRITE && !directory_empty(o->target)) {
            fprintf(stderr, "Refusing to overwrite a nonempty destination: %s\n", o->target);
            exit(EXIT_FAILURE);
        }
    } else if (errno == ENOENT && o->op == OP_WRITE) {
        ensure_parents(o->target);
        if (mkdir(o->target, 0755) && errno != EEXIST) fatal("mkdir target");
    } else { fatal("target"); }
}
static int read_devstat(const char *dev, struct devstat *s) {
    if (!dev) return 0;
    const char *base = strrchr(dev, '/');
    base = base ? base+1 : dev;
    char *p;
    if (asprintf(&p, "/sys/class/block/%s/stat", base) < 0) fatal("asprintf");
    FILE *f = fopen(p, "r");
    if (!f) { perror(p); free(p); return -1; }
    unsigned long long rio, rm, rsec, rt, wio, wm, wsec;
    int n = fscanf(f, "%llu %llu %llu %llu %llu %llu %llu", &rio, &rm, &rsec, &rt, &wio, &wm, &wsec);
    fclose(f); free(p);
    if (n != 7) return -1;
    *s = (struct devstat){rio, rsec, wio, wsec}; return 0;
}
static void drop_caches_required(void) {
    int fd = open("/proc/sys/vm/drop_caches", O_WRONLY | O_CLOEXEC);
    if (fd < 0) fatal("open drop_caches (run as root for cold reads)");
    ssize_t n = write(fd, "3\n", 2);
    int e = errno;
    close(fd);
    if (n != 2) { errno = e; fatal("write drop_caches"); }
}
static int read_exact(int fd, unsigned char *buf, size_t n, off_t offset) {
    size_t total = 0;
    while (total < n) {
        ssize_t got = pread(fd, buf + total, n - total, offset + (off_t)total);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) return got == 0 ? EIO : errno;
        total += (size_t)got;
    }
    return 0;
}
static int write_exact(int fd, const unsigned char *buf, size_t n, off_t offset) {
    size_t total = 0;
    while (total < n) {
        ssize_t sent = pwrite(fd, buf + total, n - total, offset + (off_t)total);
        if (sent < 0 && errno == EINTR) continue;
        if (sent <= 0) return sent == 0 ? EIO : errno;
        total += (size_t)sent;
    }
    return 0;
}
static void *do_io(void *arg) {
    struct job *j = arg;
    unsigned char *buffer = must_malloc(BUFFER_BYTES);
    if (j->op == OP_RAND_READ) {
        for (uint64_t k = j->req_start; k < j->req_end; k++) {
            uint64_t cl = j->random_clusters[k];
            uint64_t base = cl * CLUSTER_BYTES;
            uint64_t available = j->size - base;
            uint64_t pages = (available + READ_BYTES - 1) / READ_BYTES;
            if (pages > 4) pages = 4;
            uint64_t state = j->seed ^ (cl * UINT64_C(0x9e3779b97f4a7c15));
            uint64_t page = splitmix64(&state) % pages;
            uint64_t off = base + page * READ_BYTES;
            size_t len = (size_t)((j->size-off) < READ_BYTES ? (j->size-off) : READ_BYTES);
            j->err = read_exact(j->input_fd, buffer, len, (off_t)off);
            if (j->err) break;
            j->bytes += len; j->calls++;
        }
    } else {
        for (uint64_t pos = j->start; pos < j->end;) {
            size_t len = (size_t)((j->end-pos) < BUFFER_BYTES ? (j->end-pos) : BUFFER_BYTES);
            if (j->op == OP_WRITE) {
                j->err = read_exact(j->input_fd, buffer, len, (off_t)pos);
                if (!j->err) j->err = write_exact(j->output_fd, buffer, len, (off_t)pos);
            } else {
                j->err = read_exact(j->input_fd, buffer, len, (off_t)pos);
            }
            if (j->err) break;
            pos += len; j->bytes += len; j->calls++;
        }
    }
    free(buffer);
    return NULL;
}
static uint64_t *make_shuffled_clusters(uint64_t n, uint64_t seed) {
    uint64_t *items = must_malloc((size_t)n * sizeof(*items));
    for (uint64_t i = 0; i < n; i++) items[i] = i;
    for (uint64_t i = n; i > 1; i--) {
        uint64_t k = splitmix64(&seed) % i;
        uint64_t tmp = items[i-1]; items[i-1] = items[k]; items[k] = tmp;
    }
    return items;
}
static int benchmark_file(const struct options *o, const char *src, const char *dst,
                          uint64_t filesize, const char *rel, uint64_t *bytes, uint64_t *calls,
                          int *active_threads) {
    *bytes = 0; *calls = 0; *active_threads = 0;
    int in = -1, out = -1;
    if (o->op == OP_WRITE) {
        in = open(src, O_RDONLY | O_CLOEXEC);
        if (in < 0) { perror(src); return -1; }
        out = open(dst, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0644);
        if (out < 0) { perror(dst); close(in); return -1; }
        if (ftruncate(out, (off_t)filesize) < 0) { perror("ftruncate"); close(in); close(out); return -1; }
    } else {
        in = open(dst, O_RDONLY | O_CLOEXEC);
        if (in < 0) { perror(dst); return -1; }
        struct stat st;
        if (fstat(in, &st) || (uint64_t)st.st_size != filesize) {
            fprintf(stderr, "Size mismatch: %s\n", dst);
            close(in); return -1;
        }
    }
    if (!filesize) { if (close(in)) perror("close input"); if (out >= 0 && close(out)) perror("close output"); return 0; }

    uint64_t chunks = (filesize + PAIR_BYTES - 1) / PAIR_BYTES;
    int nthreads = o->threads;
    if ((uint64_t)nthreads > chunks) nthreads = (int)chunks;
    *active_threads = nthreads;
    struct job *jobs = calloc((size_t)nthreads, sizeof(*jobs));
    pthread_t *ids = calloc((size_t)nthreads, sizeof(*ids));
    if (!jobs || !ids) fatal("calloc jobs");

    uint64_t nreq = (filesize + CLUSTER_BYTES - 1) / CLUSTER_BYTES;
    uint64_t seed = o->seed ^ stable_hash(rel);
    uint64_t *random_clusters = o->op == OP_RAND_READ ? make_shuffled_clusters(nreq, seed) : NULL;
    for (int i = 0; i < nthreads; i++) {
        uint64_t a = (chunks * (uint64_t)i / (uint64_t)nthreads) * PAIR_BYTES;
        uint64_t b = (chunks * (uint64_t)(i+1) / (uint64_t)nthreads) * PAIR_BYTES;
        if (b > filesize) b = filesize;
        jobs[i] = (struct job){
            .op=o->op, .input_fd=in, .output_fd=out, .size=filesize,
            .start=a, .end=b, .nreq=nreq,
            .req_start=nreq*(uint64_t)i/(uint64_t)nthreads,
            .req_end=nreq*(uint64_t)(i+1)/(uint64_t)nthreads,
            .random_clusters=random_clusters, .seed=seed
        };
    }
    int launched = 0, rc = 0;
    if (nthreads == 1) {
        do_io(&jobs[0]);
    } else {
        for (int i = 0; i < nthreads; i++) {
            int e = pthread_create(&ids[i], NULL, do_io, &jobs[i]);
            if (e) { fprintf(stderr, "pthread_create: %s\n", strerror(e)); rc = -1; break; }
            launched++;
        }
        for (int i = 0; i < launched; i++) {
            int e = pthread_join(ids[i], NULL);
            if (e) { fprintf(stderr, "pthread_join: %s\n", strerror(e)); rc = -1; }
        }
    }
    for (int i = 0; i < nthreads; i++) {
        *bytes += jobs[i].bytes;
        *calls += jobs[i].calls;
        if (jobs[i].err) {
            fprintf(stderr, "I/O failed: %s: %s\n", rel, strerror(jobs[i].err));
            rc = -1;
        }
    }
    if (close(in)) { perror("close input"); rc = -1; }
    if (out >= 0 && close(out)) { perror("close output"); rc = -1; }
    free(random_clusters); free(jobs); free(ids);
    return rc;
}
static const char *mode_name(enum operation op) {
    return op==OP_WRITE ? "write" : op==OP_SEQ_READ ? "seqread" : "randread";
}
int main(int argc, char **argv) {
    struct options o = {.threads=1, .seed=2027};
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--mode") && ++i < argc) {
            o.op_set = 1;
            if (!strcmp(argv[i], "write")) o.op=OP_WRITE;
            else if (!strcmp(argv[i], "seqread")) o.op=OP_SEQ_READ;
            else if (!strcmp(argv[i], "randread")) o.op=OP_RAND_READ;
            else { usage(argv[0]); return 2; }
        } else if (!strcmp(argv[i], "--source") && ++i < argc) o.source=argv[i];
        else if (!strcmp(argv[i], "--target") && ++i < argc) o.target=argv[i];
        else if (!strcmp(argv[i], "--device") && ++i < argc) o.device=argv[i];
        else if (!strcmp(argv[i], "--per-file-csv") && ++i < argc) o.per_file_csv=argv[i];
        else if (!strcmp(argv[i], "--summary-csv") && ++i < argc) o.summary_csv=argv[i];
        else if (!strcmp(argv[i], "--label") && ++i < argc) o.label=argv[i];
        else if (!strcmp(argv[i], "--threads") && ++i < argc) o.threads=atoi(argv[i]);
        else if (!strcmp(argv[i], "--seed") && ++i < argc) o.seed=strtoull(argv[i], NULL, 10);
        else if (!strcmp(argv[i], "--cold")) o.cold=1;
        else { usage(argv[0]); return 2; }
    }
    if (!o.op_set || !o.source || !o.target || o.threads < 1 || o.threads > 256 ||
        (o.op != OP_WRITE && !o.cold) || (o.op != OP_WRITE && !o.device)) {
        usage(argv[0]);
        if (o.op_set && o.op != OP_WRITE) fprintf(stderr, "Cold reads require --cold AND --device.\n");
        return 2;
    }
    char *rsrc = realpath(o.source, NULL);
    if (!rsrc) fatal("realpath source");
    char *rtarget = realpath(o.target, NULL);
    if (rtarget && (!strcmp(rsrc, rtarget) ||
        (!strncmp(rtarget, rsrc, strlen(rsrc)) && rtarget[strlen(rsrc)]=='/'))) {
        fprintf(stderr, "Target must not be inside source; refusing to overwrite or recurse.\n");
        return 2;
    }
    free(rsrc); free(rtarget);

    struct collection c={0};
    char *base=NULL;
    collect_source(o.source, &c, &base);
    if (c.regular_files == 0) { fprintf(stderr, "No regular files found.\n"); return 2; }
    prepare_target(&o);
    int rootfd = open(o.target, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (rootfd < 0) fatal("open target dir");
    struct statfs sfs;
    if (statfs(o.target, &sfs) == 0 && (unsigned long)sfs.f_type != F2FS_MAGIC)
        fprintf(stderr, "[WARN] Target is not F2FS/CoPack (F2FS magic mismatch). Verify the mount before benchmarking.\n");
    if (o.op == OP_WRITE && statfs(o.source, &sfs) == 0 && (unsigned long)sfs.f_type != TMPFS_MAGIC)
        fprintf(stderr, "[WARN] Source not on tmpfs: source-disk reads may contaminate write throughput.\n");

    /* Do not write CSV inside the timed region; that would distort especially small-file workloads. */
    struct file_record *records = o.per_file_csv ? calloc((size_t)c.regular_files, sizeof(*records)) : NULL;
    if (o.per_file_csv && !records) fatal("calloc file records");
    if (o.cold) {
        if (syncfs(rootfd)) fatal("syncfs before cold read");
        drop_caches_required();
    }
    struct devstat pre={0}, post={0};
    if (o.device && read_devstat(o.device, &pre)) {
        fprintf(stderr, "Could not read block device stat: %s\n", o.device);
        return 2;
    }

    double t0 = seconds_now();
    uint64_t actual_bytes=0, actual_calls=0, files_processed=0, underutilized=0;
    for (size_t k=0; k<c.len; k++) {
        const struct entry *e=&c.v[k];
        char *dst=join(o.target,e->rel);
        if (e->is_dir) {
            if (o.op == OP_WRITE && mkdir(dst,0755) && errno != EEXIST) fatal(dst);
            free(dst); continue;
        }
        char *src=join(base,e->rel);
        uint64_t b=0, calls=0;
        int active=0;
        double tf0=seconds_now();
        if (benchmark_file(&o,src,dst,e->size,e->rel,&b,&calls,&active)) {
            fprintf(stderr,"Benchmark aborted at file %s\n",e->rel);
            return 1;
        }
        double dt=seconds_now()-tf0;
        if (active < o.threads) underutilized++;
        actual_bytes += b;
        actual_calls += calls;
        files_processed++;
        if (records)
            records[files_processed-1] = (struct file_record){e->rel,e->size,b,calls,active,dt};
        free(src); free(dst);
    }
    double submission=seconds_now()-t0;
    double sync_seconds=0;
    if (o.op == OP_WRITE) {
        double s0=seconds_now();
        if (syncfs(rootfd)) fatal("syncfs after write");
        sync_seconds=seconds_now()-s0;
    }
    double total=seconds_now()-t0;
    if (o.device && read_devstat(o.device,&post)) fatal("read devstat after test");
    if (records) {
        FILE *csv = fopen(o.per_file_csv, "w");
        if (!csv) fatal("fopen per-file-csv");
        fprintf(csv,"file_index,relative_path,file_bytes,active_workers,elapsed_seconds,processed_bytes,operations,throughput_MiB_s\n");
        for (uint64_t i=0; i<files_processed; i++) {
            const struct file_record *r = &records[i];
            fprintf(csv,"%" PRIu64 ",",i+1);
            csv_string(csv,r->rel);
            fprintf(csv,",%" PRIu64 ",%d,%.9f,%" PRIu64 ",%" PRIu64 ",%.6f\n",
                r->original_bytes,r->active,r->secs,r->bytes,r->calls,
                r->secs>0?(double)r->bytes/r->secs/1048576.:0.);
        }
        if (fclose(csv)) fatal("close per-file-csv");
        free(records);
    }
    close(rootfd);
    printf("\n=== Real-data F2FS / CoPack benchmark ===\n");
    printf("mode:                   %s\n",mode_name(o.op));
    printf("source:                 %s\n",o.source);
    printf("target:                 %s\n",o.target);
    printf("requested_workers:      %d\n",o.threads);
    printf("files_processed:        %" PRIu64 "\n",files_processed);
    printf("files_with_less_workers:%" PRIu64 "\n",underutilized);
    printf("symlinks_skipped:       %zu\n",c.symlinks);
    printf("dataset_logical_bytes:  %" PRIu64 "\n",c.regular_bytes);
    printf("processed_bytes:        %" PRIu64 "\n",actual_bytes);
    printf("operations:             %" PRIu64 "\n",actual_calls);
    printf("I/O_phase_seconds:      %.6f\n",submission);
    printf("syncfs_seconds:         %.6f\n",sync_seconds);
    printf("total_seconds:          %.6f\n",total);
    printf("throughput_MiB_s:       %.3f\n",total>0?(double)actual_bytes/1048576./total:0.);
    printf("IOPS:                   %.3f\n",total>0?(double)actual_calls/total:0.);
    if (o.device) {
        printf("device:                 %s\n",o.device);
        printf("device_read_bytes:      %" PRIu64 "\n",(post.read_sectors-pre.read_sectors)*UINT64_C(512));
        printf("device_read_requests:   %" PRIu64 "\n",post.read_ios-pre.read_ios);
        printf("device_write_bytes:     %" PRIu64 "\n",(post.write_sectors-pre.write_sectors)*UINT64_C(512));
        printf("device_write_requests:  %" PRIu64 "\n",post.write_ios-pre.write_ios);
        if (o.op != OP_WRITE && (post.read_ios == pre.read_ios || post.read_sectors == pre.read_sectors))
            fprintf(stderr,"[ERROR] No physical device reads observed. Treat this cold-read result as INVALID.\n");
        else if (o.op != OP_WRITE && actual_bytes > 0 &&
                 (post.read_sectors-pre.read_sectors)*UINT64_C(512) < actual_bytes / 100)
            fprintf(stderr,"[WARN] Device read bytes under 1%% of application read bytes; investigate page cache or device selection.\n");
    }
    if (o.op == OP_WRITE && actual_bytes != c.regular_bytes) {
        fprintf(stderr,"[ERROR] Bytes written do not match dataset logical bytes.\n");
        return 1;
    }
    if (o.summary_csv) {
        struct stat st;
        int needs_header = stat(o.summary_csv, &st) != 0 || st.st_size == 0;
        FILE *sf = fopen(o.summary_csv, "a");
        if (!sf) fatal("fopen summary-csv");
        if (needs_header)
            fprintf(sf,"label,mode,source,target,requested_workers,files,source_logical_bytes,processed_bytes,operations,io_seconds,syncfs_seconds,total_seconds,throughput_MiB_s,IOPS,device_read_bytes,device_read_requests,device_write_bytes,device_write_requests\n");
        csv_string(sf,o.label ? o.label : ""); fputc(',',sf);
        csv_string(sf,mode_name(o.op)); fputc(',',sf);
        csv_string(sf,o.source); fputc(',',sf);
        csv_string(sf,o.target);
        fprintf(sf,",%d,%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%.9f,%.9f,%.9f,%.6f,%.6f,%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 "\n",
            o.threads,files_processed,c.regular_bytes,actual_bytes,actual_calls,
            submission,sync_seconds,total,
            total>0?(double)actual_bytes/1048576./total:0.,
            total>0?(double)actual_calls/total:0.,
            o.device?(post.read_sectors-pre.read_sectors)*UINT64_C(512):0,
            o.device?post.read_ios-pre.read_ios:0,
            o.device?(post.write_sectors-pre.write_sectors)*UINT64_C(512):0,
            o.device?post.write_ios-pre.write_ios:0);
        if (fclose(sf)) fatal("close summary-csv");
    }
    int invalid_read = o.op != OP_WRITE && o.device &&
                       (post.read_ios == pre.read_ios || post.read_sectors == pre.read_sectors);
    for (size_t k=0; k<c.len; k++) free(c.v[k].rel);
    free(c.v); free(base);
    return invalid_read ? 3 : 0;
}
