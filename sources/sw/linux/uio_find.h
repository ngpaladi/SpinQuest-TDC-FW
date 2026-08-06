/* Resolve /dev/uioN by device name (and optionally map0 physical address).
 * UIO probe order is not stable: on the Krio image the four PS axi-pmon
 * devices claim uio0-3, so hard-coded numbers break. */
#ifndef UIO_FIND_H
#define UIO_FIND_H

#include <stdio.h>
#include <string.h>

/* Returns 0 on success and writes "/dev/uioN" into dev (size devlen).
 * Pass addr = 0 to match by name only. */
static int uio_find(const char *name, unsigned long addr,
                    char *dev, size_t devlen)
{
    char path[128], buf[128];
    for (int i = 0; i < 32; i++) {
        FILE *f;
        snprintf(path, sizeof path, "/sys/class/uio/uio%d/name", i);
        f = fopen(path, "r");
        if (!f)
            continue;
        if (!fgets(buf, sizeof buf, f)) { fclose(f); continue; }
        fclose(f);
        buf[strcspn(buf, "\n")] = 0;
        if (strcmp(buf, name) != 0)
            continue;
        if (addr) {
            unsigned long a = 0;
            snprintf(path, sizeof path,
                     "/sys/class/uio/uio%d/maps/map0/addr", i);
            f = fopen(path, "r");
            if (!f)
                continue;
            if (fscanf(f, "%lx", &a) != 1) { fclose(f); continue; }
            fclose(f);
            if (a != addr)
                continue;
        }
        snprintf(dev, devlen, "/dev/uio%d", i);
        return 0;
    }
    return -1;
}

#endif
