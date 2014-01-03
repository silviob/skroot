
#define _GNU_SOURCE

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <limits.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdarg.h>
#include <string.h>
#include <pwd.h>
#include <sys/time.h>

struct __SkrootArray {
    int size;
    int* data;
};

static int __audit_fd;
static int __audit_loaded = 0;
static int __audit_successful = -1;
static int (*__audit_open)(const char*, int, ...);
static int (*__audit_open64)(const char*, int, ...);
static ssize_t (*__audit_read)(int, void *, size_t);
static ssize_t (*__audit_write)(int, const void *, size_t);
static int (*__audit_close)(int);
static char *(*__audit_getenv)(const char* name);
static int (*__audit_libc_start_main)(int (*main) (int, char * *, char * *),
        int argc, char * * ubp_av, void (*init) (void), void (*fini) (void),
        void (*rtld_fini) (void), void (* stack_end));
static void (*__audit_exit)(int);
static pid_t (*__audit_fork)(void);
static int (*__audit_creat)(const char*, mode_t);
static FILE *(*__audit_fopen)(const char*, const char*);
static FILE *(*__audit_fopen64)(const char*, const char*);
static size_t (*__audit_fread)(void*, size_t, size_t, FILE*);
static size_t (*__audit_fwrite)(const void *, size_t, size_t, FILE*);
static int (*__audit_fclose)(FILE*);
static int (*__audit_stat)(const char*, struct stat*);
static struct __SkrootArray __audit_read_bytes;
static struct __SkrootArray __audit_write_bytes;

void __audit_log(const char *type, const char* format, ...)
{
    struct timeval tv;
    va_list args;
    char buf[8192] = "";
    int len = 0;
    if(type != NULL)
    {
        gettimeofday(&tv, NULL);
        unsigned int msecs = tv.tv_sec * 1000 + tv.tv_usec / 1000;
        len = snprintf(buf, sizeof(buf) - 1, "%d %u %s: ", getpid(), msecs, type);
    }
    va_start(args, format);
    len += vsnprintf(&buf[len], sizeof(buf) - len - 1, format, args);
    va_end(args);
    __audit_write(__audit_fd, buf, len < 8191 ? len : 8191);
}

void __audit_double_array(struct __SkrootArray *ary)
{
    int i = 0;

    int new_size = ary->size > 0 ? ary->size * 2 : 2;
    int *new_data = malloc(sizeof(int) * new_size);
    for(i = 0; i < ary->size; i++) new_data[i] = ary->data[i];
    for(; i < new_size; i++) new_data[i] = -1;
    ary->size = new_size;
    if(ary->data != NULL) free(ary->data);
    ary->data = new_data;
}

void __audit_increment_fd(struct __SkrootArray *ary, int fd, ssize_t inc)
{
    if(inc == -1) return;
    while(fd >= ary->size) __audit_double_array(ary);
    if(ary->data[fd] == -1)
        ary->data[fd] = inc;
    else
        ary->data[fd] += inc;
}

int __audit_query_fd(struct __SkrootArray *ary, int fd)
{
    if(fd < ary->size) return ary->data[fd];
    return 0;
}

__attribute__((destructor)) void fini()
{
    __audit_log("fini", "%d\n", __audit_successful);
    __audit_close(__audit_fd);
}

__attribute__((constructor)) void init()
{
    if(!__audit_loaded)
    {
        __audit_read_bytes.size = 0;
        __audit_read_bytes.data = NULL;
        __audit_write_bytes.size = 0;
        __audit_write_bytes.data = NULL;
        __audit_open = dlsym(RTLD_NEXT, "open");
        __audit_open64 = dlsym(RTLD_NEXT, "open64");
        __audit_read = dlsym(RTLD_NEXT, "read");
        __audit_write = dlsym(RTLD_NEXT, "write");
        __audit_close = dlsym(RTLD_NEXT, "close");
        __audit_getenv = dlsym(RTLD_NEXT, "getenv");
        char *filename_env = "SKROOT_FILE";
        char *filename = __audit_getenv(filename_env);
        __audit_fd = __audit_open(filename,
                                 O_WRONLY |  O_CREAT | O_APPEND, 0600);
        __audit_libc_start_main = dlsym(RTLD_NEXT, "__libc_start_main");
        __audit_exit = dlsym(RTLD_NEXT, "exit");
        __audit_fork = dlsym(RTLD_NEXT, "fork");
        __audit_creat = dlsym(RTLD_NEXT, "creat");
        __audit_fopen = dlsym(RTLD_NEXT, "fopen");
        __audit_fopen64 = dlsym(RTLD_NEXT, "fopen64");
        __audit_fread = dlsym(RTLD_NEXT, "fread");
        __audit_fclose = dlsym(RTLD_NEXT, "fclose");
        __audit_fwrite = dlsym(RTLD_NEXT, "fwrite");
        __audit_stat = dlsym(RTLD_NEXT, "stat");
        __audit_log("init", "\n");
        __audit_loaded = 1;
    }
}

int __libc_start_main(int (*main) (int, char * *, char * *),
             int argc, char * * ubp_av, void (*init) (void),
             void (*fini) (void), void (*rtld_fini) (void), void (* stack_end)) 
{
    char **argv = ubp_av;
    char **env = NULL;
    char *cwd;
    if(!__audit_loaded) init();
    __audit_log("start", "%d\n", getppid());
    cwd = getcwd(NULL, 0);
    __audit_log("cwd", "%s\n", cwd);
    free(cwd); 
    while(*argv)
    {
        __audit_log("argv", "%s\n", *argv);
        argv++;
    }
    argv++;
    env = argv;
    while(*env)
    {
        __audit_log("env", "%s\n", *env);
        env++;
    }
    return (*__audit_libc_start_main)(main, argc, ubp_av, init,
                                          fini, rtld_fini, stack_end);
}

void exit(int status)
{
    if(!__audit_loaded) init();
    __audit_log("exit", "%d\n", status);
    __audit_successful = status;
    (*__audit_exit)(status);
}

pid_t fork()
{
    if(!__audit_loaded) init();
    __audit_log("forking", "\n");
    pid_t child = __audit_fork();
    if(child == 0)
    {
        __audit_close(__audit_fd);
        __audit_loaded = 0;
        init();
        __audit_log("fork", "%d\n", getppid());
    }
    return child;
}

char *NOTgetenv(const char *name)
{
    if(!__audit_loaded) init();
    if(name) __audit_log("getenv", "%s\n", name);
    return (*__audit_getenv)(name);
}

ssize_t read(int fd, void *buf, size_t size)
{
    if(!__audit_loaded) init();
    ssize_t result = __audit_read(fd, buf, size);
    __audit_increment_fd(&__audit_read_bytes, fd, result);
    return result;
}

size_t fread(void *ptr, size_t size, size_t nmemb, FILE *stream)
{
    if(!__audit_loaded) init();
    size_t result = __audit_fread(ptr, size, nmemb, stream);
    if(stream != NULL) __audit_increment_fd(&__audit_read_bytes, fileno(stream),
                                                                    result * size);
    return result;
}

ssize_t write(int fd, const void *buf, size_t count)
{
    if(!__audit_loaded) init();
    ssize_t result = __audit_write(fd, buf, count);
    __audit_increment_fd(&__audit_write_bytes, fd, result);
    return result;
}

size_t fwrite(const void *ptr, size_t size, size_t nmemb, FILE *stream)
{
    if(!__audit_loaded) init();
    size_t result = __audit_fwrite(ptr, size, nmemb, stream);
    if(stream != NULL) __audit_increment_fd(&__audit_write_bytes, fileno(stream),
                                                                    result * size);
    return result;
}

int close(int fd)
{
    if(!__audit_loaded) init();
    __audit_log("close", "%d %d %d\n", fd,
                        __audit_query_fd(&__audit_read_bytes, fd),
                        __audit_query_fd(&__audit_write_bytes, fd));
    if(__audit_read_bytes.size > fd) __audit_read_bytes.data[fd] = -1;
    if(__audit_write_bytes.size > fd) __audit_write_bytes.data[fd] = -1;
    return __audit_close(fd);
}

int fclose(FILE *fp)
{
    if(!__audit_loaded) init();
    if(fp == NULL) return;
    int fd = fileno(fp);
    __audit_log("closef", "%d %d %d\n", fd,
                        __audit_query_fd(&__audit_read_bytes, fd),
                        __audit_query_fd(&__audit_write_bytes, fd));
    if(__audit_read_bytes.size > fd) __audit_read_bytes.data[fd] = -1;
    if(__audit_write_bytes.size > fd) __audit_write_bytes.data[fd] = -1;
    return __audit_fclose(fp);
}

void __audit_log_path(const char *type, const char *path, int fd, const char *mode)
{
    char resolved_path[PATH_MAX];
    char *rpath = realpath(path, resolved_path);
    const char *rtype = rpath == NULL ? "miss" : type;
    const char *filename = rpath == NULL ? path : resolved_path;
    __audit_log(rtype, "%s %d %s\n", filename, fd, mode);
    //free(rpath);
}

int open(const char *path, int flags, ...)
{
    if(!__audit_loaded) init();
    char *mode = "rd";
    mode = flags & O_WRONLY ? "wr" : mode;
    mode = flags & O_RDWR ? "rdwr" : mode;
    int result = -1;
    const char *filename = NULL;
    if(flags & O_CREAT)
    {
        va_list args;
        va_start(args, flags);
        mode_t mode = va_arg(args, mode_t);
        va_end(args);
        result = (*__audit_open)(path, flags, mode);
    } else
    {
        result = (*__audit_open)(path, flags);
    }
    __audit_log_path("open", path, result, mode);
    return result;
}

int open64(const char *path, int flags, ...)
{
    if(!__audit_loaded) init();
    char *mode = "rd";
    mode = flags & O_WRONLY ? "wr" : mode;
    mode = flags & O_RDWR ? "rdwr" : mode;
    int result = -1;
    const char *filename = NULL;
    if(flags & O_CREAT)
    {
        va_list args;
        va_start(args, flags);
        mode_t mode = va_arg(args, mode_t);
        va_end(args);
        result = (*__audit_open64)(path, flags, mode);
    } else
    {
        result = (*__audit_open64)(path, flags);
    }
    __audit_log_path("open", path, result, mode);
    return result;
}

FILE *fopen(const char* path, const char *mode)
{
    if(!__audit_loaded) init();
    FILE *result = __audit_fopen(path, mode);
    int fd = result == NULL ? -1 : fileno(result);
    __audit_log_path("open", path, fd, mode);
    return result;
}

FILE *fopen64(const char* path, const char *mode)
{
    if(!__audit_loaded) init();
    FILE *result = __audit_fopen64(path, mode);
    int fd = result == NULL ? -1 : fileno(result);
    __audit_log_path("open", path, fd, mode);
    return result;
}

int stat(const char *path, struct stat *buf)
{
    if(!__audit_loaded) init();
    __audit_log("stat", "%s\n", path);
    return __audit_stat(path, buf);
}

int creat(const char* path, mode_t mode)
{
    if(!__audit_loaded) init();
    char *rpath = realpath(path, NULL);
    __audit_log("open", "%s wr\n", rpath);
    free(rpath);
    return __audit_creat(path, mode);
}
