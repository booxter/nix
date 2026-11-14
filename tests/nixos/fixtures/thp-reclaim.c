#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

int main(void) {
    const size_t huge = 2 * 1024 * 1024;
    const size_t size = 32 * 1024 * 1024;
    void *mapping = mmap(NULL, size + huge, PROT_READ | PROT_WRITE,
                         MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    assert(mapping != MAP_FAILED);
    unsigned char *data = (void *)(((uintptr_t)mapping + huge - 1) & ~(huge - 1));
    assert(madvise(data, size, MADV_HUGEPAGE) == 0);
    memset(data, 0x5a, size);
    /* MADV_COLLAPSE makes the fixture independent of khugepaged's schedule. */
    assert(madvise(data, size, MADV_COLLAPSE) == 0);

    /* Preserve existing backing, but prevent khugepaged from filling the holes
       again after reclaim splits these pages. */
    assert(madvise(data, size, MADV_NOHUGEPAGE) == 0);
    for (size_t offset = 0; offset < size; offset += huge) {
        assert(madvise(data + offset + 4096, huge - 4096, MADV_DONTNEED) == 0);
    }
    FILE *ready = fopen("/run/thp-ready", "w");
    assert(ready != NULL);
    fclose(ready);

    /* Keep checking the retained data while the daemon reclaims its backing. */
    for (;;) {
        for (size_t offset = 0; offset < size; offset += huge) {
            for (size_t byte = 0; byte < 4096; byte++) {
                assert(data[offset + byte] == 0x5a);
            }
        }
        sleep(1);
    }
}
