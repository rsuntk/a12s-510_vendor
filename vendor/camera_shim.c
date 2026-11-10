/* camera_module_t of the a12s legacy HAL (0x168) laid out as the A14 HWL expects (0x188) */
#include <android/log.h>
#include <dlfcn.h>
#include <pthread.h>
#include <string.h>

#define A12S_HAL "/vendor/lib64/hw/camera.exynos850.so"

struct hw_module {
    unsigned long long head;
    void *ptr[3];
    void *methods;
    void *dso;
    unsigned long long reserved[25];
};

struct a12s_module {
    struct hw_module common;
    void *get_number_of_cameras, *get_camera_info, *set_callbacks, *get_vendor_tag_ops, *open_legacy,
         *set_torch_mode, *init, *get_physical_camera_info, *is_stream_combination_supported,
         *notify_device_state_change, *set_torch_mode_strength, *reserved[3];
};

struct a14_module {
    struct hw_module common;
    void *get_number_of_cameras, *get_camera_info, *get_session_characteristics,
         *construct_default_request_settings, *set_callbacks, *get_vendor_tag_ops, *open_legacy,
         *set_torch_mode, *init, *get_physical_camera_info, *is_stream_combination_supported,
         *notify_device_state_change, *reserved[2], *set_torch_mode_strength,
         *get_concurrent_streaming_camera_ids, *is_concurrent_stream_combination_supported, *reserved2;
};

_Static_assert(sizeof(struct hw_module) == 248, "hw_module_t");
_Static_assert(sizeof(struct a12s_module) == 0x168, "a12s HMI");
_Static_assert(sizeof(struct a14_module) == 0x188, "A14 HMI");

__attribute__((visibility("default"))) struct a14_module HMI;

/* a12s HAL reads the Samsung stream option at +0x38; the A14 HWL keeps it in bits 16+ of +0x50 */
#define A12S_STREAM_OPTION 0x38
#define A14_STREAM_OPTION 0x52

struct stream_config {
    unsigned int num_streams;
    char **streams;
    unsigned int operation_mode;
    const void *session_parameters;
};

/* camera3_device_ops: 10 hooks + reserved[8], copied with two spare slots */
#define OPS_SLOTS 20
#define OPS_CONFIGURE_STREAMS 1
#define DEVICE_CLOSE 112
#define DEVICE_OPS 120

struct camera_info {
    int facing;
    int orientation;
    unsigned int device_version;
    const void *static_camera_characteristics;
    int resource_cost;
    void *conflicting_devices;
    size_t conflicting_devices_length;
};

typedef int (*configure_streams_t)(void *dev, struct stream_config *cfg);
typedef int (*open_t)(const void *module, const char *id, void **dev);
typedef int (*close_t)(void *dev);
typedef int (*get_camera_info_t)(int camera_id, struct camera_info *info);

static const void *(*hal_methods)[1];
static configure_streams_t hal_configure_streams;
static close_t hal_close;
static get_camera_info_t hal_get_camera_info;
static void *shim_ops[OPS_SLOTS];

typedef void camera_metadata_t;
typedef struct {
    size_t index;
    unsigned int tag;
    unsigned char type;
    size_t count;
    union {
        const unsigned char *u8;
        const int *i32;
    } data;
} metadata_ro_entry_t;

typedef camera_metadata_t *(*alloc_meta_t)(size_t, size_t);
typedef void (*free_meta_t)(camera_metadata_t *);
typedef int (*append_meta_t)(camera_metadata_t *, const camera_metadata_t *);
typedef int (*add_entry_t)(camera_metadata_t *, unsigned int, const void *, size_t);
typedef int (*find_entry_t)(const camera_metadata_t *, unsigned int, metadata_ro_entry_t *);
typedef size_t (*count_meta_t)(const camera_metadata_t *);

#define TAG_FLASH_AVAILABLE 0x50000
#define TAG_FLASH_MAX_LEVEL 0x50002
#define TAG_FLASH_DEF_LEVEL 0x50003

static struct {
    find_entry_t find_entry;
    alloc_meta_t alloc;
    free_meta_t free;
    append_meta_t append;
    add_entry_t add_entry;
    count_meta_t count_entries;
    count_meta_t count_data;
} meta;

#define MAX_CAMERAS 8
static const camera_metadata_t *cached_metadata[MAX_CAMERAS];
static unsigned char checked[MAX_CAMERAS];
static pthread_mutex_t cache_lock = PTHREAD_MUTEX_INITIALIZER;

static void load_metadata_syms(void)
{
    void *h = dlopen("libcamera_metadata.so", RTLD_NOW);
    if (!h)
        return;
    meta.find_entry = (find_entry_t)dlsym(h, "find_camera_metadata_ro_entry");
    meta.alloc = (alloc_meta_t)dlsym(h, "allocate_camera_metadata");
    meta.free = (free_meta_t)dlsym(h, "free_camera_metadata");
    meta.append = (append_meta_t)dlsym(h, "append_camera_metadata");
    meta.add_entry = (add_entry_t)dlsym(h, "add_camera_metadata_entry");
    meta.count_entries = (count_meta_t)dlsym(h, "get_camera_metadata_entry_count");
    meta.count_data = (count_meta_t)dlsym(h, "get_camera_metadata_data_count");
    if (!meta.find_entry || !meta.alloc || !meta.free || !meta.append || !meta.add_entry ||
        !meta.count_entries || !meta.count_data) {
        memset(&meta, 0, sizeof(meta));
        dlclose(h);
    }
}

static const camera_metadata_t *patch_torch_levels(int camera_id, const camera_metadata_t *src)
{
    metadata_ro_entry_t entry;
    if (meta.find_entry(src, TAG_FLASH_AVAILABLE, &entry) != 0 || !entry.count || entry.data.u8[0] != 1)
        return NULL;
    if (meta.find_entry(src, TAG_FLASH_MAX_LEVEL, &entry) == 0)
        return NULL;

    camera_metadata_t *patched = meta.alloc(meta.count_entries(src) + 2, meta.count_data(src));
    if (!patched)
        return NULL;

    int max_level = 5;
    int def_level = 1;
    if (meta.append(patched, src) || meta.add_entry(patched, TAG_FLASH_MAX_LEVEL, &max_level, 1) ||
        meta.add_entry(patched, TAG_FLASH_DEF_LEVEL, &def_level, 1)) {
        meta.free(patched);
        return NULL;
    }
    __android_log_print(ANDROID_LOG_INFO, "camera_shim", "patched camera %d torch levels (max=%d def=%d)",
                        camera_id, max_level, def_level);
    return patched;
}

static int shim_get_camera_info(int camera_id, struct camera_info *info)
{
    int ret = hal_get_camera_info(camera_id, info);
    if (ret || !info || !info->static_camera_characteristics || !meta.find_entry ||
        camera_id < 0 || camera_id >= MAX_CAMERAS)
        return ret;

    pthread_mutex_lock(&cache_lock);
    if (!checked[camera_id]) {
        cached_metadata[camera_id] = patch_torch_levels(camera_id, info->static_camera_characteristics);
        checked[camera_id] = 1;
    }
    if (cached_metadata[camera_id])
        info->static_camera_characteristics = cached_metadata[camera_id];
    pthread_mutex_unlock(&cache_lock);
    return ret;
}

static int shim_close(void *dev)
{
    int ret = hal_close(dev);
    __android_log_print(ANDROID_LOG_INFO, "camera_shim", "close %p ret %d", dev, ret);
    return ret;
}

static int shim_configure_streams(void *dev, struct stream_config *cfg)
{
    for (unsigned int i = 0; cfg && i < cfg->num_streams; i++) {
        char *s = cfg->streams[i];
        int opt;
        memcpy(&opt, s + A14_STREAM_OPTION, sizeof(opt));
        memcpy(s + A12S_STREAM_OPTION, &opt, sizeof(opt));
    }
    return hal_configure_streams(dev, cfg);
}

static int shim_open(const void *module, const char *id, void **dev)
{
    int ret = ((open_t)(*hal_methods)[0])(module, id, dev);
    if (ret || !*dev)
        return ret;
    void ***ops = (void ***)((char *)*dev + DEVICE_OPS);
    if (!hal_configure_streams) {
        memcpy(shim_ops, *ops, sizeof(shim_ops));
        hal_configure_streams = (configure_streams_t)shim_ops[OPS_CONFIGURE_STREAMS];
        shim_ops[OPS_CONFIGURE_STREAMS] = (void *)shim_configure_streams;
    }
    *ops = shim_ops;
    close_t *close = (close_t *)((char *)*dev + DEVICE_CLOSE);
    if (!hal_close)
        hal_close = *close;
    *close = shim_close;
    __android_log_print(ANDROID_LOG_INFO, "camera_shim", "open %s %p", id, *dev);
    return 0;
}

static const void *shim_methods[1] = { (const void *)shim_open };

__attribute__((constructor)) static void camera_shim_init(void)
{
    void *h = dlopen(A12S_HAL, RTLD_NOW);
    const struct a12s_module *m = h ? dlsym(h, "HMI") : NULL;
    if (!m)
        return;
    void *dso = HMI.common.dso;
    HMI.common = m->common;
    HMI.common.dso = dso;
    hal_methods = m->common.methods;
    HMI.common.methods = (void *)shim_methods;
    HMI.get_number_of_cameras = m->get_number_of_cameras;
    hal_get_camera_info = (get_camera_info_t)m->get_camera_info;
    HMI.get_camera_info = shim_get_camera_info;
    load_metadata_syms();
    HMI.set_callbacks = m->set_callbacks;
    HMI.get_vendor_tag_ops = m->get_vendor_tag_ops;
    HMI.open_legacy = m->open_legacy;
    HMI.set_torch_mode = m->set_torch_mode;
    HMI.init = m->init;
    HMI.get_physical_camera_info = m->get_physical_camera_info;
    HMI.is_stream_combination_supported = m->is_stream_combination_supported;
    HMI.notify_device_state_change = m->notify_device_state_change;
    HMI.set_torch_mode_strength = m->set_torch_mode_strength;
}
