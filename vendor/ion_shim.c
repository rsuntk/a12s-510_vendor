// This kernel has no /dev/ion; libion.so is rebuilt on dma-buf heaps for the legacy a12s camera HAL.
// A "handle" is the dma-buf fd itself.
#include <android/log.h>
#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#define LOG_TAG "ion_shim"
#define ALOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)
#define ALOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)

struct dma_heap_allocation_data {
    uint64_t len;
    uint32_t fd;
    uint32_t fd_flags;
    uint64_t heap_flags;
};
#define DMA_HEAP_IOC_MAGIC 'H'
#define DMA_HEAP_IOCTL_ALLOC _IOWR(DMA_HEAP_IOC_MAGIC, 0x0, struct dma_heap_allocation_data)

typedef int ion_user_handle_t;

int ion_open(void)
{
    // the system heap node is 0444, so it cannot be opened O_RDWR
    int fd = open("/dev/dma_heap/system", O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        fd = open("/dev/dma_heap/camera", O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        int err = errno;
        ALOGE("open /dev/dma_heap failed: %s", strerror(err));
        return -err;
    }
    ALOGI("ion_open() -> fd %d", fd);
    return fd;
}

int ion_close(int fd)
{
    ALOGI("ion_close(fd %d)", fd);
    if (fd >= 0)
        close(fd);
    return 0;
}

int ion_alloc_fd(int fd, size_t len, size_t align, unsigned int heap_mask, unsigned int flags, int *handle_fd)
{
    (void)align;
    (void)heap_mask;
    (void)flags;
    if (fd < 0 || !handle_fd)
        return -EINVAL;

    struct dma_heap_allocation_data data = {
        .len = (uint64_t)len,
        .fd_flags = O_RDWR | O_CLOEXEC,
    };
    if (ioctl(fd, DMA_HEAP_IOCTL_ALLOC, &data) < 0) {
        int err = errno;
        ALOGE("DMA_HEAP_IOCTL_ALLOC (%zu bytes) failed: %s", len, strerror(err));
        return -err;
    }
    *handle_fd = (int)data.fd;
    ALOGI("ion_alloc_fd(%zu) -> fd %d", len, *handle_fd);
    return 0;
}

int ion_alloc(int fd, size_t len, size_t align, unsigned int heap_mask, unsigned int flags, ion_user_handle_t *handle)
{
    int handle_fd = -1;
    int ret = ion_alloc_fd(fd, len, align, heap_mask, flags, &handle_fd);
    if (ret == 0 && handle)
        *handle = handle_fd;
    return ret;
}

int ion_free(int fd, ion_user_handle_t handle)
{
    (void)fd;
    if (handle >= 0)
        close(handle);
    return 0;
}

int ion_sync_fd(int fd, int handle_fd)
{
    (void)fd;
    (void)handle_fd;
    return 0;
}

int ion_is_legacy(int fd)
{
    (void)fd;
    return 0;
}

int ion_is_using_modular_heaps(int fd)
{
    (void)fd;
    return 0;
}

int ion_share(int fd, ion_user_handle_t handle, int *share_fd)
{
    (void)fd;
    if (handle < 0 || !share_fd)
        return -EINVAL;
    *share_fd = dup(handle);
    return *share_fd >= 0 ? 0 : -errno;
}

int ion_import(int fd, int share_fd, ion_user_handle_t *handle)
{
    (void)fd;
    if (share_fd < 0 || !handle)
        return -EINVAL;
    *handle = dup(share_fd);
    return *handle >= 0 ? 0 : -errno;
}

int ion_map(int fd, ion_user_handle_t handle, size_t length, int prot, int flags, off_t offset,
            unsigned char **ptr, int *map_fd)
{
    (void)fd;
    if (!ptr || !map_fd || handle < 0)
        return -EINVAL;
    void *p = mmap(NULL, length, prot, flags, handle, offset);
    if (p == MAP_FAILED)
        return -errno;
    // the caller owns map_fd and closes it separately from the handle
    int dup_fd = dup(handle);
    if (dup_fd < 0) {
        int err = errno;
        munmap(p, length);
        return -err;
    }
    *ptr = (unsigned char *)p;
    *map_fd = dup_fd;
    return 0;
}

// No heap list to report: a count of 1 would make callers parse an unfilled ion_heap_data.
int ion_query_heap_cnt(int fd, int *cnt)
{
    (void)fd;
    if (!cnt)
        return -EINVAL;
    *cnt = 0;
    return 0;
}

int ion_query_get_heaps(int fd, int cnt, void *buffers)
{
    (void)fd;
    (void)cnt;
    (void)buffers;
    return 0;
}
