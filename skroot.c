
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

static int __audit_fd;
static int (*__audit_open)(const char*, int, ...);
static int (*__audit_open64)(const char*, int, ...);
static char *(*__audit_getenv)(const char* name);
static int (*__audit_libc_start_main)(int (*main) (int, char * *, char * *),
        int argc, char * * ubp_av, void (*init) (void), void (*fini) (void),
        void (*rtld_fini) (void), void (* stack_end));
static void (*__audit_exit)(int);
static pid_t (*__audit_fork)(void);
static int (*__audit_creat)(const char*, mode_t);
static FILE *(*__audit_fopen)(const char*, const char*);
static FILE *(*__audit_fopen64)(const char*, const char*);
static int (*__audit_stat)(const char *, struct stat *);

void __audit_log(const char *type, const char* format, ...)
{
    int len = 0;
    struct timeval tv;
    va_list args;
    char buf[2048] = "";
    if(type != NULL)
    {
        gettimeofday(&tv, NULL);
        unsigned int msecs = tv.tv_sec * 1000 + tv.tv_usec / 1000;
        len = snprintf(buf, sizeof(buf), "%d %u %s: ", getpid(), msecs, type);
    }
    va_start(args, format);
    len += vsnprintf(&buf[len], sizeof(buf) - len, format, args);
    va_end(args);
    while(buf[len] != 0) len++;
    write(__audit_fd, buf, len);
}

__attribute__((destructor)) void fini()
{
    __audit_log("fini", "\n");
    close(__audit_fd);
}

__attribute__((constructor)) void init()
{
    char *filename = "/home/sbrugada/audit.dit";
    __audit_open = dlsym(RTLD_NEXT, "open");
    __audit_open64 = dlsym(RTLD_NEXT, "open64");
    __audit_fd = __audit_open(filename,
                             O_WRONLY |  O_CREAT | O_APPEND, 0600);
    __audit_libc_start_main = dlsym(RTLD_NEXT, "__libc_start_main");
    __audit_getenv = dlsym(RTLD_NEXT, "getenv");
    __audit_exit = dlsym(RTLD_NEXT, "_exit");
    __audit_fork = dlsym(RTLD_NEXT, "fork");
    __audit_creat = dlsym(RTLD_NEXT, "creat");
    __audit_fopen = dlsym(RTLD_NEXT, "fopen");
    __audit_fopen64 = dlsym(RTLD_NEXT, "fopen64");
    __audit_stat = dlsym(RTLD_NEXT, "stat");   
    __audit_log("init", "\n");
}

int __libc_start_main(int (*main) (int, char * *, char * *),
             int argc, char * * ubp_av, void (*init) (void),
             void (*fini) (void), void (*rtld_fini) (void), void (* stack_end)) 
{
    char **argv = ubp_av;
    char **env = NULL;
    char *cwd;
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

void _exit(int status)
{
    __audit_log("exit", "%d", status);
    (*__audit_exit)(status);
}

pid_t fork()
{
    pid_t child = __audit_fork();
    __audit_log("forking", "%d\n", getpid());
    if(child == 0)
    {
        __audit_log("fork", "%d\n", getppid());
    }
    return child;
}

char *NOTgetenv(const char *name)
{
    __audit_log("getenv", "%s\n", name);
    return (*__audit_getenv)(name);
}

void __audit_log_path(const char *type, const char *path, const char *mode)
{
    char *rpath = realpath(path, NULL);
    const char *rtype = rpath == NULL ? "miss" : type;
    const char *filename = rpath == NULL ? path : rpath;
    __audit_log(rtype, "%s %s\n", filename, mode);
    free(rpath);
}

int open(const char *path, int flags, ...)
{
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
    __audit_log_path("open", path, mode);
    return result;
}

int open64(const char *path, int flags, ...)
{
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
    __audit_log_path("open", path, mode);
    return result;
}

FILE *fopen(const char* path, const char *mode)
{
    FILE *result = __audit_fopen(path, mode);
    __audit_log_path("open", path, mode);
    return result;
}

FILE *fopen64(const char* path, const char *mode)
{
    FILE *result = __audit_fopen64(path, mode);
    __audit_log_path("open", path, mode);
    return result;
}

int stat(const char *path, struct stat *buf)
{
    __audit_log("stat", "%s\n", path);
    return __audit_stat(path, buf);
}

int creat(const char* path, mode_t mode)
{
    char *rpath = realpath(path, NULL);
    __audit_log("open", "%s wr\n", rpath);
    free(rpath);
    return __audit_creat(path, mode);
}
