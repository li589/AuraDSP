#include <stdio.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
extern int memfd_create(const char*, unsigned);
int main() {
    int fd = memfd_create("t", 1|2);
    printf("memfd fd=%d\n", fd);
    if (fd < 0) return 1;
    if (ftruncate(fd, 4096)) { printf("ftruncate fail\n"); return 1; }
    void* p = mmap(0, 4096, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0);
    printf("mmap=%p (fail=%d errno=%d)\n", p, p==(void*)-1, p==(void*)-1?0:0);
    return 0;
}
