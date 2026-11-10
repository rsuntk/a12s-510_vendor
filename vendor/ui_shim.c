// The a12s camera HAL calls GraphicBufferMapper::unlock(buffer_handle_t), which the A14 libui no longer exports;
// it is rebuilt on top of unlock(buffer_handle_t, base::unique_fd*) the way the old libui did it.
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/ioctl.h>
#include <unistd.h>

struct native_handle;

int _ZN7android19GraphicBufferMapper6unlockEPK13native_handlePNS_4base14unique_fd_implINS4_13DefaultCloserEEE(
        void *mapper, const struct native_handle *handle, int *fence);

__attribute__((visibility("default")))
int _ZN7android19GraphicBufferMapper6unlockEPK13native_handle(void *mapper, const struct native_handle *handle)
{
    int fence = -1;
    int ret = _ZN7android19GraphicBufferMapper6unlockEPK13native_handlePNS_4base14unique_fd_implINS4_13DefaultCloserEEE(
            mapper, handle, &fence);

    if (fence >= 0) {
        struct pollfd pfd = { .fd = fence, .events = POLLIN };
        while (poll(&pfd, 1, -1) < 0 && errno == EINTR)
            ;
        close(fence);
    }
    return ret;
}
