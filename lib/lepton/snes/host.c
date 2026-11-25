/*
 * lepton-snes: a libretro frontend without a screen, for Lepton's SNES
 * window (Lepton.SNES.Window). Built when the snes app is installed, with
 * the app's own tcc (Lepton.SNES.build/1).
 *
 *   lepton-snes CORE.so ROM SAVE_DIR WIDTH HEIGHT
 *
 * It runs the core at the game's own rate (60 frames a second, 50 for
 * PAL) and talks over stdin and stdout in packets: a 4-byte big-endian
 * length, then a type byte and the data (Erlang's {packet, 4}).
 *
 * Out:  'I' fps*1000 (u32) rate (u32)        once the game is loaded
 *       'V' width (u16) height (u16) pixels  a frame, scaled to fit the
 *                                            window, XRGB8888 (bgr0)
 *       'A' samples                          stereo S16_LE at 48 kHz
 *       'M' text                             something to show
 * In:   'K' buttons (u16)                    the pad (libretro joypad bits)
 *       'S' width (u16) height (u16)         the window's new size
 *       'P' paused (u8)
 *       'R'                                  reset
 *       'W' slot (u8)  /  'L' slot (u8)      save / load a state
 *       'Q'                                  save and quit (EOF too)
 *
 * The cartridge's battery RAM (save games) is written to SAVE_DIR/NAME.srm
 * when it changes (checked every 2 seconds) and on quit; states go to
 * SAVE_DIR/NAME.stateN.
 */
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>


struct retro_game_info { const char *path; const void *data; size_t size; const char *meta; };
struct retro_system_info { const char *library_name; const char *library_version; const char *valid_extensions; bool need_fullpath; bool block_extract; };
struct retro_game_geometry { unsigned base_width, base_height, max_width, max_height; float aspect_ratio; };
struct retro_system_timing { double fps; double sample_rate; };
struct retro_system_av_info { struct retro_game_geometry geometry; struct retro_system_timing timing; };
struct retro_log_callback { void (*log)(int level, const char *fmt, ...); };
struct retro_variable { const char *key; const char *value; };

typedef bool (*env_cb)(unsigned, void *);
typedef void (*video_cb)(const void *, unsigned, unsigned, size_t);
typedef void (*audio_cb)(int16_t, int16_t);
typedef size_t (*audio_batch_cb)(const int16_t *, size_t);
typedef void (*poll_cb)(void);
typedef int16_t (*state_cb)(unsigned, unsigned, unsigned, unsigned);

static void (*r_init)(void);
static void (*r_deinit)(void);
static void (*r_set_environment)(env_cb);
static void (*r_set_video)(video_cb);
static void (*r_set_audio)(audio_cb);
static void (*r_set_audio_batch)(audio_batch_cb);
static void (*r_set_poll)(poll_cb);
static void (*r_set_state)(state_cb);
static void (*r_get_system_info)(struct retro_system_info *);
static void (*r_get_av_info)(struct retro_system_av_info *);
static void (*r_set_controller)(unsigned, unsigned);
static void (*r_reset)(void);
static void (*r_run)(void);
static size_t (*r_serialize_size)(void);
static bool (*r_serialize)(void *, size_t);
static bool (*r_unserialize)(const void *, size_t);
static bool (*r_load_game)(const struct retro_game_info *);
static void (*r_unload_game)(void);
static void *(*r_get_memory_data)(unsigned);
static size_t (*r_get_memory_size)(unsigned);

static int pixel_format = 0; /* 0: 0RGB1555, 1: XRGB8888, 2: RGB565 */
static unsigned out_w = 512, out_h = 448;
static uint16_t buttons = 0;
static const char *save_dir = ".";
static double core_rate = 32040.0;

static uint8_t *frame_pkt = 0;
static size_t frame_cap = 0;
static int16_t *in_audio = 0;
static size_t in_count = 0, in_cap = 0;
static double resample_pos = 0.0;
static int16_t last_l = 0, last_r = 0;

/* -- packets ------------------------------------------------------------------------------------ */

static void write_all(const void *buf, size_t n) {
  const uint8_t *p = buf;
  while (n > 0) {
    ssize_t w = write(1, p, n);
    if (w < 0) { if (errno == EINTR) continue; exit(0); }
    p += w; n -= (size_t)w;
  }
}

static void packet(uint8_t type, const void *data, size_t n) {
  uint8_t head[5];
  uint32_t len = (uint32_t)(n + 1);
  head[0] = len >> 24; head[1] = len >> 16; head[2] = len >> 8; head[3] = len; head[4] = type;
  write_all(head, 5);
  if (n) write_all(data, n);
}

static void message(const char *fmt, ...) {
  char text[512];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(text, sizeof text, fmt, ap);
  va_end(ap);
  packet('M', text, strlen(text));
}

static void core_log(int level, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  vfprintf(stderr, fmt, ap);
  va_end(ap);
}

/* -- the core's callbacks --------------------------------------------------------------------------- */

static bool environment(unsigned cmd, void *data) {
  switch (cmd) {
    case 3: *(bool *)data = 1; return 1;                         /* GET_CAN_DUPE */
    case 9: case 31: *(const char **)data = save_dir; return 1;  /* system, save directories */
    case 10: {                                                   /* SET_PIXEL_FORMAT */
      int f = *(const int *)data;
      if (f < 0 || f > 2) return 0;
      pixel_format = f;
      return 1;
    }
    case 11: case 16: case 35: case 36: return 1;                /* descriptors, variables, controllers, memory maps */
    case 15: ((struct retro_variable *)data)->value = 0; return 0; /* GET_VARIABLE: the defaults */
    case 17: *(bool *)data = 0; return 1;                        /* GET_VARIABLE_UPDATE */
    case 27: ((struct retro_log_callback *)data)->log = core_log; return 1;
    case 52: *(unsigned *)data = 0; return 1;                    /* GET_CORE_OPTIONS_VERSION: v0 */
    default: return 0;
  }
}

static inline uint32_t to_xrgb(const void *src, unsigned x) {
  if (pixel_format == 1) return ((const uint32_t *)src)[x];
  uint16_t p = ((const uint16_t *)src)[x];
  unsigned r, g, b;
  if (pixel_format == 2) { r = (p >> 11) & 31; g = (p >> 5) & 63; b = p & 31; g = (g << 2) | (g >> 4); }
  else { r = (p >> 10) & 31; g = (p >> 5) & 31; b = p & 31; g = (g << 3) | (g >> 2); }
  r = (r << 3) | (r >> 2);
  b = (b << 3) | (b >> 2);
  return (r << 16) | (g << 8) | b;
}

/* The picture fitted in the window at the SNES's 8:7 (256x224) shape, black around it. */
static void video(const void *data, unsigned w, unsigned h, size_t pitch) {
  if (!data || w == 0 || h == 0) return; /* a repeated frame: nothing new */
  size_t pixels = (size_t)out_w * out_h;
  size_t need = 4 + pixels * 4;
  if (frame_cap < need) { frame_pkt = realloc(frame_pkt, need); frame_cap = need; }
  frame_pkt[0] = out_w >> 8; frame_pkt[1] = out_w; frame_pkt[2] = out_h >> 8; frame_pkt[3] = out_h;
  uint32_t *out = (uint32_t *)(frame_pkt + 4);

  unsigned dw = out_w, dh = (unsigned)((uint64_t)out_w * 224 / 256);
  if (dh > out_h) { dh = out_h; dw = (unsigned)((uint64_t)out_h * 256 / 224); }
  if (dw == 0 || dh == 0) return;
  unsigned ox = (out_w - dw) / 2, oy = (out_h - dh) / 2;
  memset(out, 0, pixels * 4);

  static unsigned *xmap = 0, xmap_n = 0, xmap_w = 0, xmap_src = 0;
  if (xmap_n != dw || xmap_src != w) {
    xmap = realloc(xmap, dw * sizeof *xmap);
    for (unsigned x = 0; x < dw; x++) xmap[x] = (unsigned)((uint64_t)x * w / dw);
    xmap_n = dw; xmap_src = w; xmap_w = dw;
  }

  int last_sy = -1;
  for (unsigned y = 0; y < dh; y++) {
    unsigned sy = (unsigned)((uint64_t)y * h / dh);
    uint32_t *row = out + (size_t)(oy + y) * out_w + ox;
    if ((int)sy == last_sy) { memcpy(row, row - out_w, dw * 4); continue; }
    const uint8_t *src = (const uint8_t *)data + (size_t)sy * pitch;
    for (unsigned x = 0; x < dw; x++) row[x] = to_xrgb(src, xmap[x]);
    last_sy = (int)sy;
  }
  (void)xmap_w;
  packet('V', frame_pkt, need);
}

static void audio_push(const int16_t *s, size_t frames) {
  if (in_count + frames > in_cap) {
    in_cap = (in_count + frames) * 2;
    in_audio = realloc(in_audio, in_cap * 4);
  }
  memcpy(in_audio + in_count * 2, s, frames * 4);
  in_count += frames;
}

static void audio(int16_t l, int16_t r) { int16_t s[2] = {l, r}; audio_push(s, 1); }
static size_t audio_batch(const int16_t *s, size_t frames) { audio_push(s, frames); return frames; }
static void input_poll(void) {}

static int16_t input_state(unsigned port, unsigned device, unsigned index, unsigned id) {
  if (port != 0 || device != 1) return 0;         /* the first pad only */
  if (id == 256) return (int16_t)buttons;          /* JOYPAD_MASK */
  return id < 16 ? (buttons >> id) & 1 : 0;
}

/* The frame's sound, at 48 kHz (linear interpolation), as one packet. */
static void flush_audio(void) {
  if (in_count == 0) return;
  double step = core_rate / 48000.0;
  size_t max_out = (size_t)(in_count / step) + 4;
  int16_t *out = malloc(max_out * 4);
  size_t n = 0;
  while (resample_pos < (double)in_count && n < max_out) {
    size_t i = (size_t)resample_pos;
    double t = resample_pos - (double)i;
    int16_t al = i == 0 ? last_l : in_audio[(i - 1) * 2], ar = i == 0 ? last_r : in_audio[(i - 1) * 2 + 1];
    int16_t bl = in_audio[i * 2], br = in_audio[i * 2 + 1];
    out[n * 2] = (int16_t)(al + (bl - al) * t);
    out[n * 2 + 1] = (int16_t)(ar + (br - ar) * t);
    n++;
    resample_pos += step;
  }
  resample_pos -= (double)in_count;
  last_l = in_audio[(in_count - 1) * 2];
  last_r = in_audio[(in_count - 1) * 2 + 1];
  in_count = 0;
  packet('A', out, n * 4);
  free(out);
}

/* -- saves -------------------------------------------------------------------------------------------- */

static char base_name[512];

static void save_path(char *buf, size_t n, const char *ext) { snprintf(buf, n, "%s/%s%s", save_dir, base_name, ext); }

static int write_file(const char *path, const void *data, size_t n) {
  char tmp[1100];
  snprintf(tmp, sizeof tmp, "%s.tmp", path);
  FILE *f = fopen(tmp, "wb");
  if (!f) return 0;
  size_t w = fwrite(data, 1, n, f);
  if (fclose(f) != 0 || w != n) { unlink(tmp); return 0; }
  return rename(tmp, path) == 0;
}

static void *read_file(const char *path, size_t *n) {
  FILE *f = fopen(path, "rb");
  if (!f) return 0;
  fseek(f, 0, SEEK_END);
  long size = ftell(f);
  fseek(f, 0, SEEK_SET);
  if (size < 0) { fclose(f); return 0; }
  void *data = malloc(size ? (size_t)size : 1);
  *n = fread(data, 1, (size_t)size, f);
  fclose(f);
  return data;
}

static uint8_t *sram_copy = 0;

static void save_sram(int force) {
  uint8_t *sram = r_get_memory_data(0);
  size_t n = r_get_memory_size(0);
  if (!sram || n == 0) return;
  if (!sram_copy) { sram_copy = malloc(n); memcpy(sram_copy, sram, n); if (!force) return; }
  if (!force && memcmp(sram, sram_copy, n) == 0) return;
  char path[1100];
  save_path(path, sizeof path, ".srm");
  if (write_file(path, sram, n)) memcpy(sram_copy, sram, n);
}

static void load_sram(void) {
  uint8_t *sram = r_get_memory_data(0);
  size_t n = r_get_memory_size(0), got = 0;
  char path[1100];
  save_path(path, sizeof path, ".srm");
  void *data = read_file(path, &got);
  if (data && sram && n) memcpy(sram, data, got < n ? got : n);
  free(data);
  if (sram && n) { sram_copy = malloc(n); memcpy(sram_copy, sram, n); }
}

static void state(int save, int slot) {
  char path[1100], ext[32];
  snprintf(ext, sizeof ext, ".state%d", slot);
  save_path(path, sizeof path, ext);
  if (save) {
    size_t n = r_serialize_size();
    void *data = malloc(n ? n : 1);
    if (n && r_serialize(data, n) && write_file(path, data, n)) message("Saved state %d", slot);
    else message("Couldn't save state %d", slot);
    free(data);
  } else {
    size_t n = 0;
    void *data = read_file(path, &n);
    if (data && r_unserialize(data, n)) message("Loaded state %d", slot);
    else message(data ? "State %d doesn't fit this game" : "No state %d saved yet", slot);
    free(data);
  }
}

/* -- commands -------------------------------------------------------------------------------------- */

static uint8_t in_buf[1 << 16];
static size_t in_len = 0;
static int paused = 0, quit = 0;

static void command(const uint8_t *p, size_t n) {
  if (n == 0) return;
  switch (p[0]) {
    case 'K': if (n >= 3) buttons = (uint16_t)((p[1] << 8) | p[2]); break;
    case 'S': if (n >= 5) { unsigned w = (p[1] << 8) | p[2], h = (p[3] << 8) | p[4]; if (w >= 16 && h >= 16 && w <= 8192 && h <= 8192) { out_w = w; out_h = h; } } break;
    case 'P': if (n >= 2) paused = p[1]; break;
    case 'R': r_reset(); message("Reset"); break;
    case 'W': if (n >= 2) state(1, p[1]); break;
    case 'L': if (n >= 2) state(0, p[1]); break;
    case 'Q': quit = 1; break;
  }
}

/* Read what's there (waiting up to `ms`), and act on whole packets. */
static void read_commands(int ms) {
  struct pollfd pfd = {0, POLLIN, 0};
  if (poll(&pfd, 1, ms) <= 0) return;
  ssize_t r = read(0, in_buf + in_len, sizeof in_buf - in_len);
  if (r <= 0) { if (r == 0 || errno != EINTR) quit = 1; return; }
  in_len += (size_t)r;
  size_t at = 0;
  while (in_len - at >= 4) {
    uint32_t len = ((uint32_t)in_buf[at] << 24) | (in_buf[at + 1] << 16) | (in_buf[at + 2] << 8) | in_buf[at + 3];
    if (len > sizeof in_buf - 4) { quit = 1; return; }
    if (in_len - at - 4 < len) break;
    command(in_buf + at + 4, len);
    at += 4 + len;
  }
  memmove(in_buf, in_buf + at, in_len - at);
  in_len -= at;
}

static double now(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec + t.tv_nsec / 1e9;
}

#define SYM(var, name) do { *(void **)&var = dlsym(core, name); if (!var) { fprintf(stderr, "lepton-snes: the core has no %s\n", name); return 3; } } while (0)

int main(int argc, char **argv) {
  if (argc < 6) { fprintf(stderr, "usage: lepton-snes CORE ROM SAVE_DIR WIDTH HEIGHT\n"); return 2; }
  save_dir = argv[3];
  out_w = (unsigned)atoi(argv[4]);
  out_h = (unsigned)atoi(argv[5]);
  if (out_w < 16) out_w = 512;
  if (out_h < 16) out_h = 448;

  const char *slash = strrchr(argv[2], '/');
  snprintf(base_name, sizeof base_name, "%s", slash ? slash + 1 : argv[2]);
  char *dot = strrchr(base_name, '.');
  if (dot && dot != base_name) *dot = 0;

  void *core = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!core) { fprintf(stderr, "lepton-snes: %s\n", dlerror()); return 3; }
  SYM(r_init, "retro_init"); SYM(r_deinit, "retro_deinit");
  SYM(r_set_environment, "retro_set_environment"); SYM(r_set_video, "retro_set_video_refresh");
  SYM(r_set_audio, "retro_set_audio_sample"); SYM(r_set_audio_batch, "retro_set_audio_sample_batch");
  SYM(r_set_poll, "retro_set_input_poll"); SYM(r_set_state, "retro_set_input_state");
  SYM(r_get_system_info, "retro_get_system_info"); SYM(r_get_av_info, "retro_get_system_av_info");
  SYM(r_set_controller, "retro_set_controller_port_device"); SYM(r_reset, "retro_reset"); SYM(r_run, "retro_run");
  SYM(r_serialize_size, "retro_serialize_size"); SYM(r_serialize, "retro_serialize"); SYM(r_unserialize, "retro_unserialize");
  SYM(r_load_game, "retro_load_game"); SYM(r_unload_game, "retro_unload_game");
  SYM(r_get_memory_data, "retro_get_memory_data"); SYM(r_get_memory_size, "retro_get_memory_size");

  r_set_environment(environment);
  r_init();
  r_set_video(video);
  r_set_audio(audio);
  r_set_audio_batch(audio_batch);
  r_set_poll(input_poll);
  r_set_state(input_state);

  struct retro_system_info sys;
  memset(&sys, 0, sizeof sys);
  r_get_system_info(&sys);

  size_t size = 0;
  void *rom = read_file(argv[2], &size);
  if (!rom) { fprintf(stderr, "lepton-snes: can't read %s\n", argv[2]); return 4; }
  struct retro_game_info game = {argv[2], rom, size, 0};
  if (!r_load_game(&game)) { fprintf(stderr, "lepton-snes: %s couldn't load this ROM\n", sys.library_name ? sys.library_name : "the core"); return 5; }
  r_set_controller(0, 1);

  struct retro_system_av_info av;
  memset(&av, 0, sizeof av);
  r_get_av_info(&av);
  double fps = av.timing.fps > 1 ? av.timing.fps : 60.0988;
  if (av.timing.sample_rate > 1000) core_rate = av.timing.sample_rate;
  load_sram();

  uint8_t info[8];
  uint32_t f = (uint32_t)(fps * 1000), sr = 48000;
  info[0] = f >> 24; info[1] = f >> 16; info[2] = f >> 8; info[3] = f;
  info[4] = sr >> 24; info[5] = sr >> 16; info[6] = sr >> 8; info[7] = sr;
  packet('I', info, 8);

  double period = 1.0 / fps, next = now(), last_save = next;
  while (!quit) {
    double t = now();
    if (paused) { read_commands(100); next = now(); continue; }
    if (t < next) { read_commands((int)((next - t) * 1000)); continue; }
    read_commands(0);
    r_run();
    flush_audio();
    next += period;
    /* Far behind (the machine was busy): start counting again from now. */
    if (now() - next > 0.25) next = now();
    if (t - last_save > 2.0) { save_sram(0); last_save = t; }
  }

  save_sram(1);
  r_unload_game();
  r_deinit();
  return 0;
}
