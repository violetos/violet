// Copyright (c) 2024-2026 YiraSan
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/stat.h>

#if defined(__APPLE__)
#include <stdlib.h> /* arc4random_buf */
#else
#include <sys/random.h> /* getrandom */
#endif

#define DIR POSIX_DIR
#include <dirent.h>
#undef DIR

#include "ff.h"
#include "diskio.h"

#define SECTOR_SIZE 512
#define ESP_START_SECTOR 2048ULL
#define GPT_TABLE_SECTORS 32ULL
#define TRAILING_SECTORS (1ULL + GPT_TABLE_SECTORS)

#define FAT32_MIN_SECTORS 524288ULL
#define SIZE_MARGIN_PERCENT 20ULL
#define SIZE_MARGIN_FIXED_BYTES (4ULL * 1024 * 1024)
#define ALIGN_SECTORS 2048ULL

typedef struct {
    const char *volume_label;
    const char *partition_name;
    uint64_t forced_size_mb;
} ImageOptions;

static FILE *img_file = NULL;
static uint64_t total_sectors = 0;
static uint64_t esp_sectors = 0;

static void fatal(const char *msg) {
    fprintf(stderr, "Fatal error: %s\n", msg);
    if (img_file) fclose(img_file);
    exit(1);
}

static void check_ff(FRESULT res, const char *msg) {
    if (res != FR_OK) {
        fprintf(stderr, "FatFs error (%d): %s\n", res, msg);
        if (img_file) fclose(img_file);
        exit(1);
    }
}

static void xfseek(long offset, int whence) {
    if (fseek(img_file, offset, whence) != 0) fatal("fseek a échoué");
}

static void xfwrite(const void *ptr, size_t size, size_t count) {
    if (fwrite(ptr, size, count, img_file) != count) fatal("écriture disque incomplète");
}

static void put_u16(uint8_t *buf, size_t off, uint16_t v) {
    buf[off] = (uint8_t)(v);
    buf[off + 1] = (uint8_t)(v >> 8);
}

static void put_u32(uint8_t *buf, size_t off, uint32_t v) {
    for (int i = 0; i < 4; i++) buf[off + i] = (uint8_t)(v >> (8 * i));
}

static void put_u64(uint8_t *buf, size_t off, uint64_t v) {
    for (int i = 0; i < 8; i++) buf[off + i] = (uint8_t)(v >> (8 * i));
}

static void random_bytes(uint8_t *buf, size_t len) {
#if defined(__APPLE__)
    arc4random_buf(buf, len);
#else
    size_t got = 0;
    while (got < len) {
        ssize_t r = getrandom(buf + got, len - got, 0);
        if (r < 0) fatal("getrandom() a échoué");
        got += (size_t)r;
    }
#endif
}

static void make_guid(uint8_t out[16]) {
    random_bytes(out, 16);
    out[6] = (uint8_t)((out[6] & 0x0F) | 0x40);
    out[8] = (uint8_t)((out[8] & 0x3F) | 0x80);
}

static const uint8_t ESP_TYPE_GUID[16] = {
    0x28, 0x73, 0x2A, 0xC1, 0x1F, 0xF8, 0xD2, 0x11,
    0xBA, 0x4B, 0x00, 0xA0, 0xC9, 0x3E, 0xC9, 0x3B
};

static uint32_t calculate_crc32(const uint8_t *data, size_t length) {
    uint32_t crc = 0xFFFFFFFF;
    for (size_t i = 0; i < length; i++) {
        crc ^= data[i];
        for (int j = 0; j < 8; j++) {
            crc = (crc >> 1) ^ ((crc & 1) ? 0xEDB88320u : 0u);
        }
    }
    return ~crc;
}

static void write_partition_name(uint8_t *entry_buf, const char *name) {
    size_t i = 0;
    for (; name[i] != '\0' && i < 36; i++) {
        put_u16(entry_buf, 56 + i * 2, (uint16_t)(unsigned char)name[i]);
    }
    for (; i < 36; i++) {
        put_u16(entry_buf, 56 + i * 2, 0);
    }
}

static void build_protective_mbr(uint8_t *buf, uint64_t total_sec) {
    memset(buf, 0, SECTOR_SIZE);
    uint8_t *p = buf + 0x1BE;
    p[0] = 0x00;
    p[1] = 0x00; p[2] = 0x02; p[3] = 0x00;
    p[4] = 0xEE;
    p[5] = 0xFF; p[6] = 0xFF; p[7] = 0xFF;
    put_u32(p, 8, 1);
    uint64_t covered = total_sec - 1;
    if (covered > 0xFFFFFFFFULL) covered = 0xFFFFFFFFULL;
    put_u32(p, 12, (uint32_t)covered);
    buf[510] = 0x55;
    buf[511] = 0xAA;
}

static void build_partition_entry(
    uint8_t *entry_buf,
    const uint8_t type_guid[16],
    const uint8_t unique_guid[16],
    uint64_t start_lba,
    uint64_t end_lba,
    const char *name
) {
    memset(entry_buf, 0, 128);
    memcpy(entry_buf, type_guid, 16);
    memcpy(entry_buf + 16, unique_guid, 16);
    put_u64(entry_buf, 32, start_lba);
    put_u64(entry_buf, 40, end_lba);
    put_u64(entry_buf, 48, 0);
    write_partition_name(entry_buf, name);
}

static void build_gpt_header(
    uint8_t *buf,
    uint64_t my_lba,
    uint64_t alt_lba,
    uint64_t first_usable,
    uint64_t last_usable,
    const uint8_t disk_guid[16],
    uint64_t part_entry_lba,
    uint32_t part_array_crc
) {
    memset(buf, 0, SECTOR_SIZE);
    memcpy(buf, "EFI PART", 8);
    put_u32(buf, 8, 0x00010000);
    put_u32(buf, 12, 92);
    put_u32(buf, 16, 0);
    put_u32(buf, 20, 0);
    put_u64(buf, 24, my_lba);
    put_u64(buf, 32, alt_lba);
    put_u64(buf, 40, first_usable);
    put_u64(buf, 48, last_usable);
    memcpy(buf + 56, disk_guid, 16);
    put_u64(buf, 72, part_entry_lba);
    put_u32(buf, 80, 128);
    put_u32(buf, 84, 128);
    put_u32(buf, 88, part_array_crc);

    uint32_t header_crc = calculate_crc32(buf, 92);
    put_u32(buf, 16, header_crc);
}

static uint64_t dir_size_recursive(const char *path) {
    uint64_t total = 0;
    POSIX_DIR *dir = opendir(path);
    if (!dir) fatal("failed to open the root directory to calculate the size");

    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;

        char full[1024];
        snprintf(full, sizeof(full), "%s/%s", path, entry->d_name);

        struct stat st;
        if (stat(full, &st) != 0) continue;

        if (S_ISDIR(st.st_mode)) {
            total += dir_size_recursive(full);
        } else {
            total += ((uint64_t)st.st_size + 4095) & ~(uint64_t)4095;
        }
    }
    closedir(dir);
    return total;
}

static uint64_t compute_esp_sectors(uint64_t content_bytes, uint64_t forced_size_mb) {
    if (forced_size_mb != 0) {
        uint64_t forced_sectors = forced_size_mb * 1024ULL * 1024ULL / SECTOR_SIZE;
        if (forced_sectors < FAT32_MIN_SECTORS) {
            fatal("--size-mb is below the minimum required for a valid FAT32 (~33 MiB");
        }
        return forced_sectors;
    }

    uint64_t needed_bytes = content_bytes
        + (content_bytes * SIZE_MARGIN_PERCENT / 100)
        + SIZE_MARGIN_FIXED_BYTES;
    uint64_t needed_sectors = (needed_bytes + SECTOR_SIZE - 1) / SECTOR_SIZE;

    if (needed_sectors < FAT32_MIN_SECTORS) needed_sectors = FAT32_MIN_SECTORS;

    needed_sectors = (needed_sectors + ALIGN_SECTORS - 1) & ~(ALIGN_SECTORS - 1);
    return needed_sectors;
}

DSTATUS disk_initialize(BYTE pdrv) { return pdrv ? STA_NOINIT : 0; }
DSTATUS disk_status(BYTE pdrv) { return pdrv ? STA_NOINIT : 0; }

static DRESULT disk_io(LBA_t sector, UINT count, void *buffer, int is_write) {
    long offset = (long)((ESP_START_SECTOR + sector) * SECTOR_SIZE);
    if (!img_file || fseek(img_file, offset, SEEK_SET) != 0) return RES_ERROR;
    size_t n = is_write
        ? fwrite(buffer, SECTOR_SIZE, count, img_file)
        : fread(buffer, SECTOR_SIZE, count, img_file);
    return (n == count) ? RES_OK : RES_ERROR;
}

DRESULT disk_read(BYTE pdrv, BYTE *b, LBA_t s, UINT c) { return pdrv ? RES_PARERR : disk_io(s, c, b, 0); }
DRESULT disk_write(BYTE pdrv, const BYTE *b, LBA_t s, UINT c) { return pdrv ? RES_PARERR : disk_io(s, c, (void *)b, 1); }

DRESULT disk_ioctl(BYTE pdrv, BYTE cmd, void *buff) {
    if (pdrv) return RES_PARERR;
    switch (cmd) {
        case CTRL_SYNC: fflush(img_file); return RES_OK;
        case GET_SECTOR_COUNT: *(DWORD *)buff = (DWORD)esp_sectors; return RES_OK;
        case GET_SECTOR_SIZE: *(WORD *)buff = SECTOR_SIZE; return RES_OK;
        case GET_BLOCK_SIZE: *(DWORD *)buff = 1; return RES_OK;
        default: return RES_PARERR;
    }
}

DWORD get_fattime(void) {
    time_t t = time(NULL);
    struct tm *tm = localtime(&t);
    return ((DWORD)(tm->tm_year + 1900 - 1980) << 25)
         | ((DWORD)(tm->tm_mon + 1) << 21)
         | ((DWORD)(tm->tm_mday) << 16)
         | ((DWORD)(tm->tm_hour) << 11)
         | ((DWORD)(tm->tm_min) << 5)
         | (DWORD)(tm->tm_sec >> 1);
}

static void inject_files(const char *host_dir, const char *fat_dir) {
    POSIX_DIR *dir = opendir(host_dir);
    if (!dir) fatal("failed to open source directory");

    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;

        char h_path[1024], f_path[1024];
        snprintf(h_path, sizeof(h_path), "%s/%s", host_dir, entry->d_name);
        snprintf(f_path, sizeof(f_path), "%s/%s", fat_dir, entry->d_name);

        struct stat st;
        if (stat(h_path, &st) != 0) continue;

        if (S_ISDIR(st.st_mode)) {
            FRESULT r = f_mkdir(f_path);
            if (r != FR_OK && r != FR_EXIST) check_ff(r, "failed to create directory in the image");
            inject_files(h_path, f_path);
        } else {
            FIL fdst;
            check_ff(f_open(&fdst, f_path, FA_WRITE | FA_CREATE_ALWAYS), f_path);

            FILE *fsrc = fopen(h_path, "rb");
            if (!fsrc) fatal("failed to read source file");

            uint8_t buf[8192];
            size_t n;
            while ((n = fread(buf, 1, sizeof(buf), fsrc)) > 0) {
                UINT written;
                check_ff(f_write(&fdst, buf, (UINT)n, &written), "disk write failed");
                if (written != n) fatal("disk full or write corruption");
            }

            fclose(fsrc);
            f_close(&fdst);
        }
    }
    closedir(dir);
}

static void print_usage(const char *prog) {
    fprintf(stderr,
        "Usage: %s <source_dir> <output.img> "
        "[--label NAME] [--volume-label NAME] [--size-mb N]\n"
        "  --label NAME         ESP partition GPT name (default: \"ESP\")\n"
        "  --volume-label NAME  FAT32 volume label, max 11 characters (default: \"ESP\")\n"
        "  --size-mb N          force the ESP size (default: auto-calculated)\n",
        prog);
}

static ImageOptions parse_args(int argc, char **argv, const char **src_dir, const char **out_img) {
    if (argc < 3) {
        print_usage(argv[0]);
        exit(1);
    }
    *src_dir = argv[1];
    *out_img = argv[2];

    ImageOptions opt = { .volume_label = "ESP", .partition_name = "ESP", .forced_size_mb = 0 };

    for (int i = 3; i < argc; i++) {
        if (strcmp(argv[i], "--label") == 0 && i + 1 < argc) {
            opt.partition_name = argv[++i];
        } else if (strcmp(argv[i], "--volume-label") == 0 && i + 1 < argc) {
            opt.volume_label = argv[++i];
        } else if (strcmp(argv[i], "--size-mb") == 0 && i + 1 < argc) {
            opt.forced_size_mb = strtoull(argv[++i], NULL, 10);
        } else {
            fprintf(stderr, "Unknown option: %s\n", argv[i]);
            print_usage(argv[0]);
            exit(1);
        }
    }

    return opt;
}

int main(int argc, char **argv) {
    const char *src_dir, *out_img;
    ImageOptions opt = parse_args(argc, argv, &src_dir, &out_img);

    if (strlen(opt.volume_label) > 11) fatal("--volume-label exceeds 11 characters (FAT limit)");

    uint64_t content_bytes = dir_size_recursive(src_dir);
    esp_sectors = compute_esp_sectors(content_bytes, opt.forced_size_mb);
    total_sectors = ESP_START_SECTOR + esp_sectors + TRAILING_SECTORS;

    img_file = fopen(out_img, "wb+");
    if (!img_file) fatal("failed to create .img file");

    {
        uint8_t *chunk = calloc(1, 1024 * 1024);
        if (!chunk) fatal("failed to allocate memory");
        uint64_t total_bytes = total_sectors * SECTOR_SIZE;
        for (uint64_t written = 0; written < total_bytes; written += 1024 * 1024) {
            uint64_t remaining = total_bytes - written;
            size_t chunk_len = remaining < 1024 * 1024 ? (size_t)remaining : 1024 * 1024;
            xfwrite(chunk, 1, chunk_len);
        }
        free(chunk);
    }
    xfseek(0, SEEK_SET);

    uint8_t mbr[SECTOR_SIZE];
    build_protective_mbr(mbr, total_sectors);
    xfwrite(mbr, 1, SECTOR_SIZE);

    uint8_t disk_guid[16], esp_unique_guid[16];
    make_guid(disk_guid);
    make_guid(esp_unique_guid);

    uint64_t esp_start_lba = ESP_START_SECTOR;
    uint64_t esp_end_lba = ESP_START_SECTOR + esp_sectors - 1;

    uint8_t *partition_table = calloc(1, 128 * 128);
    if (!partition_table) fatal("failed to allocate memory");
    build_partition_entry(partition_table, ESP_TYPE_GUID, esp_unique_guid, esp_start_lba, esp_end_lba, opt.partition_name);

    uint32_t entries_crc = calculate_crc32(partition_table, 128 * 128);

    uint64_t backup_header_lba = total_sectors - 1;
    uint64_t backup_table_lba = total_sectors - 1 - GPT_TABLE_SECTORS;

    uint8_t gpt_primary[SECTOR_SIZE];
    build_gpt_header(gpt_primary, 1, backup_header_lba, 34, backup_table_lba - 1, disk_guid, 2, entries_crc);
    xfwrite(gpt_primary, 1, SECTOR_SIZE);
    xfwrite(partition_table, 1, 128 * 128);

    FATFS fs;
    BYTE work[FF_MAX_SS];
    MKFS_PARM mkfs_opt = { .fmt = FM_FAT32 | FM_SFD, .au_size = 4096 };

    if (f_mount(&fs, "0:", 1) == FR_NO_FILESYSTEM) {
        check_ff(f_mkfs("0:", &mkfs_opt, work, sizeof(work)), "formatting failed");
        check_ff(f_mount(&fs, "0:", 1), "mount after formatting failed");
        char label_cmd[32];
        snprintf(label_cmd, sizeof(label_cmd), "0:%s", opt.volume_label);
        check_ff(f_setlabel(label_cmd), "failed to set volume label");
    }
    inject_files(src_dir, "0:");
    f_mount(0, "0:", 0);

    xfseek((long)(backup_table_lba * SECTOR_SIZE), SEEK_SET);
    xfwrite(partition_table, 1, 128 * 128);

    uint8_t gpt_backup[SECTOR_SIZE];
    build_gpt_header(gpt_backup, backup_header_lba, 1, 34, backup_table_lba - 1, disk_guid, backup_table_lba, entries_crc);
    xfwrite(gpt_backup, 1, SECTOR_SIZE);

    free(partition_table);
    fclose(img_file);

    fprintf(stdout, "Result image : %llu MiB (ESP : %llu MiB)\n",
        (unsigned long long)(total_sectors * SECTOR_SIZE / (1024 * 1024)),
        (unsigned long long)(esp_sectors * SECTOR_SIZE / (1024 * 1024)));

    return 0;
}
