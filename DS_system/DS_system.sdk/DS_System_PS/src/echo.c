/*
 * echo.c - AD9268 host-triggered long capture over UDP.
 *
 * Zynq-7000 / Vivado SDK 2018.3 / standalone lwIP raw API.
 * Keep main.c unchanged.
 *
 * CAPTURE command flow:
 *   1) Arm AXI DMA S2MM SG descriptors for one FR16 long frame.
 *   2) Trigger PL through AXI-Lite register 0x38.
 *   3) Wait for DDR frame completion.
 *   4) Send all raw 16-bit two-channel waveform samples in WV32 UDP chunks.
 *   5) Send in-frame laser/temperature timeline records in LS32 UDP chunks.
 *   6) Send the CSV summary after waveform and timeline.
 *
 * Added zero-load calibration commands:
 *   CAL_START, CAL_ABORT, CAL_CLEAR, CAL_STATUS, PING
 *
 * Added auto acquisition mode (keyphasor-like L2 trigger, short frames,
 * summary + waveform only, requires calibration READY):
 *   AUTO_START[,rpm[,thr_um[,points]]], AUTO_STOP, AUTO_CFG,rpm,thr,points,
 *   AUTO_STATUS. Manual CAPTURE is rejected while auto mode is active.
 *
 * Calibration states in CSV:
 *   0 IDLE, 1 DISCARD, 2 COLLECT, 3 COMPUTE,
 *   4 VERIFY, 5 READY, 6 FAILED
 *
 * PC commands are ASCII datagrams sent from PC UDP port 50010 to board port 5000.
 */

#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>

#include "xparameters.h"
#include "xil_io.h"
#include "xil_printf.h"
#include "xil_types.h"
#include "xstatus.h"
#include "xtime_l.h"

#if defined(XPAR_AXIDMA_0_DEVICE_ID) || defined(XPAR_AXI_DMA_0_DEVICE_ID)
#include "xaxidma.h"
#include "xil_cache.h"
#define HAVE_FR16_AXI_DMA 1
#if defined(XPAR_AXIDMA_0_DEVICE_ID)
#define FR16_DMA_DEVICE_ID XPAR_AXIDMA_0_DEVICE_ID
#else
#define FR16_DMA_DEVICE_ID XPAR_AXI_DMA_0_DEVICE_ID
#endif
#if defined(XPAR_AXIDMA_0_BASEADDR)
#define FR16_DMA_BASEADDR XPAR_AXIDMA_0_BASEADDR
#elif defined(XPAR_AXI_DMA_0_BASEADDR)
#define FR16_DMA_BASEADDR XPAR_AXI_DMA_0_BASEADDR
#else
#define FR16_DMA_BASEADDR 0x40400000U
#endif
#else
#define HAVE_FR16_AXI_DMA 0
#endif

#include "lwip/err.h"
#include "lwip/udp.h"
#include "lwip/pbuf.h"
#include "lwip/ip_addr.h"
#include "lwip/netif.h"

#if defined(XPAR_LASER_AXI_REGS_0_S_AXI_BASEADDR)
# define LASER_REG_BASE XPAR_LASER_AXI_REGS_0_S_AXI_BASEADDR
#elif defined(XPAR_LASER_AXI_REGS_0_BASEADDR)
# define LASER_REG_BASE XPAR_LASER_AXI_REGS_0_BASEADDR
#else
# define LASER_REG_BASE 0x43C00000U
#endif

#define REG_MAGIC             0x00U
#define REG_PL_RESET_CTRL     REG_MAGIC  /* write-only reset control; read returns magic */
#define REG_FRAME_ID          0x04U
#define REG_LASER1_UM         0x08U
#define REG_LASER2_UM         0x0CU
#define REG_LASER3_UM         0x10U
#define REG_LASER4_UM         0x14U
#define REG_LASER5_UM         0x18U
#define REG_TEMP_X10          0x1CU
#define REG_STATUS            0x20U
#define REG_SAMPLE_COUNT      0x24U  /* R/W runtime waveform length (samples/ch) */
#define REG_ADC_A_RAW_PP      0x28U
#define REG_ADC_B_RAW_PP      0x2CU
#define REG_ADC_A_FILT_PP     0x30U
#define REG_ADC_B_FILT_PP     0x34U
#define REG_ADC_SAMPLE_INDEX  0x38U
#define REG_ADC_SAMPLE_DATA   0x3CU
#define REG_CAPTURE_CTRL      REG_ADC_SAMPLE_INDEX
#define ADC_SAMPLE_READY_MASK 0x80000000U
#define ADC_SAMPLE_INDEX_MASK 0x00000FFFU
#define EXPECTED_MAGIC        0xDA710005U
#define PL_RESET_ASSERT_WORD   0xA55A0001U
#define PL_RESET_RELEASE_WORD  0x00000000U
#define CAPTURE_START_WORD     0xCACE0001U
#define PL_RESET_KEEPALIVE_MS  600U
#define M2_LINK_STABLE_MS       2000U

#define PC_IP0                192
#define PC_IP1                168
#define PC_IP2                1
#define PC_IP3                100
#define UDP_LOCAL_PORT        5000U
#define UDP_REMOTE_PORT       50010U

/* ADC_SAMPLE_COUNT is the manual-mode long-frame length and also the PL
 * register maximum. Auto mode programs a shorter runtime length through
 * REG_SAMPLE_COUNT; PS tracks it in g_sample_count (see below). */
#define ADC_SAMPLE_COUNT              4687500U
#define ADC_SAMPLE_COUNT_MIN          16U  /* PL moving-average filter length */
#define WAVE_SAMPLES_PER_PKT          350U
#define WAVE_HEADER_BYTES             40U
#define WAVE_PACKET_BYTES             (WAVE_HEADER_BYTES + WAVE_SAMPLES_PER_PKT * 4U)
#define LS32_RECORD_BYTES             40U
#define LS32_RECORDS_PER_PKT          30U
#define LS32_HEADER_BYTES             40U
#define LS32_PACKET_BYTES             (LS32_HEADER_BYTES + LS32_RECORDS_PER_PKT * LS32_RECORD_BYTES)
#define OUTPUT_EVERY_N_FRAMES         1U
#define SEND_WAVEFORM_ENABLE          0U
#define SEND_WAVEFORM_EVERY_N_FRAMES  1U

#define FR16_FRAME_MAGIC              0x36315246U  /* 'FR16' */
#define FR16_FOOTER_MAGIC             0x454E4F44U  /* 'DONE' */
#define FR16_FRAME_VERSION            3U
#define FR16_HEADER_BYTES             256U
#define FR16_SUMMARY_BYTES            128U
#define FR16_FOOTER_BYTES             40U
#define FR16_REAL_ADC_FLAG            0x00000002U
#define FR16_HOST_TRIGGER_FLAG        0x00000004U
#define FR16_WAVE_OFFSET_BYTES        FR16_HEADER_BYTES
/* Maximum-layout constants (manual long frame). Used ONLY for ring/BD buffer
 * sizing and cache maintenance ranges. Per-frame geometry follows the runtime
 * g_sample_count via the fr16_*_rt() helpers below. */
#define FR16_WAVE_BYTES               (ADC_SAMPLE_COUNT * 4U)
#define FR16_SENSOR_TIMELINE_CAPACITY 4096U
#define FR16_SENSOR_TIMELINE_ENTRY_BYTES LS32_RECORD_BYTES
#define FR16_SENSOR_TIMELINE_BYTES    (FR16_SENSOR_TIMELINE_CAPACITY * FR16_SENSOR_TIMELINE_ENTRY_BYTES)
#define FR16_SENSOR_TIMELINE_OFFSET_BYTES (FR16_HEADER_BYTES + FR16_WAVE_BYTES)
#define FR16_SUMMARY_OFFSET_BYTES     (FR16_SENSOR_TIMELINE_OFFSET_BYTES + FR16_SENSOR_TIMELINE_BYTES)
#define FR16_FOOTER_OFFSET_BYTES      (FR16_SUMMARY_OFFSET_BYTES + FR16_SUMMARY_BYTES)
#define FR16_PAYLOAD_BYTES            (FR16_HEADER_BYTES + FR16_WAVE_BYTES + FR16_SENSOR_TIMELINE_BYTES + FR16_SUMMARY_BYTES + FR16_FOOTER_BYTES)
#define FR16_FRAME_STRIDE_BYTES       FR16_PAYLOAD_BYTES
#define FR16_FRAME_WORDS              (FR16_FRAME_STRIDE_BYTES / 4U)
#define FR16_RING_DEPTH               1U
#define FR16_BD_SPACE_BASEADDR        0x2F000000U
#define FR16_BD_SPACE_BYTES           0x00100000U
#define FR16_RING_BASEADDR            0x30000000U
#define FR16_CAPTURE_BD_MAX_COUNT     8U
#define FR16_SEND_CHUNKS_PER_POLL     16U
#define FR16_SEND_SENSOR_CHUNKS_PER_POLL 4U

/* Auto acquisition mode: keyphasor-like trigger. After t_idle exceeds
 * t_speed_ms (= shaft period from rpm minus AUTO_T_SPEED_MARGIN_MS), the next
 * L2_um dip below l_threshold_um fires one short capture. Only summary +
 * waveform are sent (no LS32 timeline). Requires calibration READY. */
#define AUTO_DEFAULT_L_THRESHOLD_UM   32000L
#define AUTO_DEFAULT_RPM              1000U
#define AUTO_DEFAULT_POINTS           3125U  /* 0.2 ms @ 15.625 MHz = 10 x 50 kHz */
#define AUTO_T_SPEED_MARGIN_MS        5U
#define AUTO_MIN_T_SPEED_MS           10U

/* DMA receive watchdog: a frame must finish DMA within this time or the
 * capture is failed visibly instead of wedging cap_state at DMA forever.
 * Long frame needs ~0.3 s capture + ~0.1 s transfer, so 20 s is generous. */
#define FR16_DMA_TIMEOUT_MS           20000U

/* AXI DMA v7.x S2MM register offsets, used only for read-only debug/status output. */
#define FR16_DMA_S2MM_DMACR_OFFSET    0x30U
#define FR16_DMA_S2MM_DMASR_OFFSET    0x34U
#define FR16_DMA_S2MM_CURDESC_OFFSET  0x38U
#define FR16_DMA_S2MM_TAILDESC_OFFSET 0x40U
#define FR16_DMASR_HALTED_MASK        0x00000001U
#define FR16_DMASR_IDLE_MASK          0x00000002U
#define FR16_DMASR_SGINCLD_MASK       0x00000008U
#define FR16_DMASR_ERR_MASK           0x00000770U
#define FR16_DMA_CR_RUNSTOP_MASK       0x00000001U
#define FR16_DMA_CR_RESET_MASK         0x00000004U

#define ADC_MODULE_FS_MVPP            9000ULL
#define ADC_MODULE_FS_UVPP_D          9000000.0
#define ADC_FULL_SCALE_CODES_D        65536.0

/* Manual long-frame calibration: PC sends one CAPTURE per calibration frame. */
#define CAL_DISCARD_FRAMES            1U
#define CAL_COLLECT_FRAMES            8U
#define CAL_VERIFY_FRAMES             4U
#define CAL_MAX_RETRIES               3U
#define CAL_MAX_INVALID_FRAMES        8U

/* Verification thresholds. */
#define CAL_VERIFY_MEAN_LIMIT_UV       100L  /* 0.100 mV */
#define CAL_VERIFY_STD_LIMIT_UV        2000L /* 2.000 mV */
#define CAL_VERIFY_DRIFT_LIMIT_UV      500L  /* 0.500 mV */

#define CAL_MIN_VALID_PP_CODE          1U
#define CAL_MAX_VALID_PP_CODE          65534U

typedef enum {
    CAL_STATE_IDLE = 0,
    CAL_STATE_DISCARD = 1,
    CAL_STATE_COLLECT = 2,
    CAL_STATE_COMPUTE = 3,
    CAL_STATE_VERIFY = 4,
    CAL_STATE_READY = 5,
    CAL_STATE_FAILED = 6
} calibration_state_t;

typedef struct {
    u32 count;
    double mean;
    double m2;
    double min_value;
    double max_value;
} online_stats_t;

typedef struct {
    calibration_state_t state;
    int valid;
    u32 attempt;
    u32 discard_count;
    u32 invalid_count;
    online_stats_t collect_a;
    online_stats_t collect_b;
    online_stats_t collect_diff;
    online_stats_t verify_diff;
    online_stats_t verify_first_half;
    online_stats_t verify_second_half;
    double zero_mean_a_code;
    double zero_mean_b_code;
    double reference_code;
    double gain_a;
    double gain_b;
    s32 verify_mean_uV;
    s32 verify_std_uV;
    s32 verify_drift_uV;
} calibration_ctx_t;

typedef struct __attribute__((packed)) {
    u32 magic;
    u16 version;
    u16 header_bytes;
    u32 frame_bytes;
    u32 frame_stride;
    u32 frame_id;
    u32 period_us;
    u32 sample_count;
    u32 sample_rate_hz;
    u32 flags;
    u32 status;
    u32 wave_offset;
    u32 wave_bytes;
    u32 summary_offset;
    u32 summary_bytes;
    u32 footer_offset;
    u32 footer_bytes;
    u32 payload_bytes;
    u32 sensor_update_mask;
    u32 ddr_overflow_count;
    u32 dma_backpressure_count;
    u32 axis_fifo_overflow_count;
    u32 sensor_timeline_offset;
    u32 sensor_timeline_bytes;
    u32 sensor_timeline_capacity;
    u32 sensor_timeline_entry_bytes;
    u32 sensor_timeline_count_hint;
    u32 reserved[38];
} fr16_frame_header_t;

typedef struct __attribute__((packed)) {
    u32 adc_a_raw_pp;
    u32 adc_b_raw_pp;
    u32 adc_a_filt_pp;
    u32 adc_b_filt_pp;
    u32 adc_a_mVpp;
    u32 adc_b_mVpp;
    s32 l1_um;
    s32 l2_um;
    s32 l3_um;
    s32 l4_um;
    s32 l5_um;
    s32 temp_x10;
    u32 sensor_status;
    u32 frame_overrun_count;
    u32 fifo_overflow_count;
    u32 frame_fifo_overflow;
    u32 sensor_timeline_offset;
    u32 sensor_timeline_bytes;
    u32 sensor_timeline_count;
    u32 sensor_timeline_entry_bytes;
    u32 sensor_timeline_overflow;
    u32 reserved[11];
} fr16_frame_summary_t;

typedef struct __attribute__((packed)) {
    u32 timestamp_us;
    u32 adc_sample_index;
    u32 update_mask;
    u32 sensor_status;
    s32 l1_um;
    s32 l2_um;
    s32 l3_um;
    s32 l4_um;
    s32 l5_um;
    s32 temp_x10;
} fr16_sensor_timeline_record_t;

typedef struct __attribute__((packed)) {
    u32 magic;
    u32 frame_id;
    u32 frame_words;
    u32 frame_bytes;
    u32 payload_bytes;
    u32 sample_count;
    u32 summary_crc;
    u32 wave_crc;
    u32 flags;
    u32 sensor_timeline_count;
} fr16_frame_footer_t;

/* Compile-time layout guards for the PL/PS binary contract. */
typedef char fr16_header_size_must_be_256[
    (sizeof(fr16_frame_header_t) == FR16_HEADER_BYTES) ? 1 : -1];
typedef char fr16_summary_must_fit_reserved_area[
    (sizeof(fr16_frame_summary_t) <= FR16_SUMMARY_BYTES) ? 1 : -1];
typedef char fr16_sensor_record_size_must_be_40[
    (sizeof(fr16_sensor_timeline_record_t) == FR16_SENSOR_TIMELINE_ENTRY_BYTES) ? 1 : -1];
typedef char fr16_footer_size_must_be_40[
    (sizeof(fr16_frame_footer_t) == FR16_FOOTER_BYTES) ? 1 : -1];

static struct udp_pcb *g_udp_pcb = NULL;
static ip_addr_t g_pc_ipaddr;
static u32 g_last_frame_id = 0xFFFFFFFFU;
static u32 g_output_divider = 0U;
static u32 g_wave_divider = 0U;
static u32 g_missed_total = 0U;
static int g_udp_ready = 0;
static volatile int g_pl_reset_active = 0;
static u32 g_pl_reset_deadline_ms = 0U;
static int g_startup_capture_hold = 0;
static int g_startup_dma_ready = 0;
static u32 g_startup_link_up_since_ms = 0U;
static int g_startup_link_wait_reported = 0;
static calibration_ctx_t g_cal;

/* Runtime waveform length (samples per channel). Mirrors PL REG_SAMPLE_COUNT;
 * manual mode keeps the default, auto mode programs a shorter value. All
 * frame geometry below is derived from it instead of compile-time constants. */
static u32 g_sample_count = ADC_SAMPLE_COUNT;

typedef struct {
    int  active;
    s32  l_threshold_um;
    u32  rpm;
    u32  t_speed_ms;
    u32  sample_count;
    u32  t_idle_ms;
    u32  last_tick_ms;
    s32  last_l2_um;
    u32  trigger_count;
} auto_mode_ctx_t;
static auto_mode_ctx_t g_auto;

extern struct netif *echo_netif;

typedef enum {
    CAPTURE_STATE_IDLE = 0,
    CAPTURE_STATE_DMA = 1,
    CAPTURE_STATE_SEND_WAVE = 2,
    CAPTURE_STATE_SEND_SENSOR = 3,
    CAPTURE_STATE_SEND_SUMMARY = 4,
    CAPTURE_STATE_ERROR = 5
} capture_state_t;

#if HAVE_FR16_AXI_DMA
static XAxiDma g_fr16_dma;
static XAxiDma_BdRing *g_fr16_rx_ring = NULL;
static int g_fr16_dma_ready = 0;
static u32 g_fr16_completed = 0U;
static u32 g_fr16_bad_header = 0U;
static u32 g_fr16_bad_footer = 0U;
static u32 g_fr16_dma_errors = 0U;
static u32 g_fr16_missed = 0U;
static u32 g_fr16_last_frame_id = 0U;
static u32 g_fr16_last_report_completed = 0U;
static u32 g_fr16_summary_checked = 0U;
static u32 g_fr16_summary_mismatch = 0U;
static UINTPTR g_fr16_last_frame_addr = (UINTPTR)0U;
static u32 g_fr16_last_calc_a_pp = 0U;
static u32 g_fr16_last_calc_b_pp = 0U;
static u32 g_fr16_last_pl_overrun = 0U;
static u32 g_fr16_last_pl_backpressure = 0U;
static u32 g_fr16_last_pl_fifo_overflow = 0U;
static int g_fr16_cache_disabled = 0; /* M2 keeps DCache enabled */
static capture_state_t g_capture_state = CAPTURE_STATE_IDLE;
static u32 g_capture_bd_count = 0U;
static u32 g_capture_bds_done = 0U;
static u32 g_capture_actual_bytes = 0U;
static u32 g_capture_wave_chunk = 0U;
static u32 g_capture_total_chunks = 0U;
static u32 g_capture_sensor_chunk = 0U;
static u32 g_capture_total_sensor_chunks = 0U;
static u32 g_capture_sensor_record_count = 0U;
static UINTPTR g_capture_frame_addr = (UINTPTR)FR16_RING_BASEADDR;
static int g_capture_validation_rc = 0;
static u32 g_capture_dma_start_ms = 0U;
#endif

static err_t udp_send_text(const char *text);
static err_t udp_send_bytes(const void *data, u16 len);
static void calibration_on_sample(u32 a_code, u32 b_code);
static u32 get_time_ms(void);

static inline u32 read_u32(u32 offset)
{
    return Xil_In32((UINTPTR)(LASER_REG_BASE + offset));
}

static inline int32_t read_s32(u32 offset)
{
    return (int32_t)Xil_In32((UINTPTR)(LASER_REG_BASE + offset));
}

static inline void write_u32(u32 offset, u32 value)
{
    Xil_Out32((UINTPTR)(LASER_REG_BASE + offset), value);
}

/* Frame geometry derived from the runtime waveform length g_sample_count.
 * FR16_FRAME_STRIDE_BYTES stays the compile-time maximum and is only used for
 * ring/BD buffer sizing; per-frame offsets must use these helpers. */
static inline u32 fr16_wave_bytes_rt(void)    { return g_sample_count * 4U; }
static inline u32 fr16_timeline_off_rt(void) { return FR16_HEADER_BYTES + fr16_wave_bytes_rt(); }
static inline u32 fr16_summary_off_rt(void)  { return fr16_timeline_off_rt() + FR16_SENSOR_TIMELINE_BYTES; }
static inline u32 fr16_footer_off_rt(void)   { return fr16_summary_off_rt() + FR16_SUMMARY_BYTES; }
static inline u32 fr16_payload_rt(void)      { return fr16_footer_off_rt() + FR16_FOOTER_BYTES; }

/* Program the PL waveform length. Call only while no capture is active: the
 * PL latches the register at capture start, and PS frame parsing follows
 * g_sample_count immediately. */
static int fr16_set_sample_count(u32 count)
{
    if ((count < ADC_SAMPLE_COUNT_MIN) || (count > ADC_SAMPLE_COUNT)) {
        return XST_FAILURE;
    }
    write_u32(REG_SAMPLE_COUNT, count);
    g_sample_count = count;
    return XST_SUCCESS;
}

static double abs_double(double x)
{
    return (x < 0.0) ? -x : x;
}

static s32 round_double_to_s32(double x)
{
    return (x >= 0.0) ? (s32)(x + 0.5) : (s32)(x - 0.5);
}

/* Avoid a dependency on libm/-lm. */
static double sqrt_local(double x)
{
    double guess;
    u32 i;
    if (x <= 0.0) return 0.0;
    guess = (x > 1.0) ? x : 1.0;
    for (i = 0U; i < 16U; i++) {
        guess = 0.5 * (guess + x / guess);
    }
    return guess;
}

static inline u32 adc_code_to_mVpp(u32 code)
{
    return (u32)(((uint64_t)code * ADC_MODULE_FS_MVPP + 32768ULL) >> 16);
}

static s32 adc_code_double_to_uVpp(double code)
{
    return round_double_to_s32(code * ADC_MODULE_FS_UVPP_D /
                               ADC_FULL_SCALE_CODES_D);
}

static s32 gain_to_ppm(double gain)
{
    return round_double_to_s32(gain * 1000000.0);
}

static void stats_reset(online_stats_t *s)
{
    if (s == NULL) return;
    s->count = 0U;
    s->mean = 0.0;
    s->m2 = 0.0;
    s->min_value = 0.0;
    s->max_value = 0.0;
}

static void stats_push(online_stats_t *s, double x)
{
    double delta;
    double delta2;
    if (s == NULL) return;

    if (s->count == 0U) {
        s->count = 1U;
        s->mean = x;
        s->m2 = 0.0;
        s->min_value = x;
        s->max_value = x;
        return;
    }

    s->count++;
    delta = x - s->mean;
    s->mean += delta / (double)s->count;
    delta2 = x - s->mean;
    s->m2 += delta * delta2;
    if (x < s->min_value) s->min_value = x;
    if (x > s->max_value) s->max_value = x;
}

static double stats_variance(const online_stats_t *s)
{
    if ((s == NULL) || (s->count < 2U)) return 0.0;
    return s->m2 / (double)(s->count - 1U);
}

static void put_u16_le(uint8_t *p, u16 v)
{
    p[0] = (uint8_t)(v & 0xFFU);
    p[1] = (uint8_t)((v >> 8) & 0xFFU);
}

static void put_u32_le(uint8_t *p, u32 v)
{
    p[0] = (uint8_t)(v & 0xFFU);
    p[1] = (uint8_t)((v >> 8) & 0xFFU);
    p[2] = (uint8_t)((v >> 16) & 0xFFU);
    p[3] = (uint8_t)((v >> 24) & 0xFFU);
}

#if HAVE_FR16_AXI_DMA
static inline UINTPTR fr16_frame_addr(u32 index)
{
    return (UINTPTR)(FR16_RING_BASEADDR +
                     (index % FR16_RING_DEPTH) * FR16_FRAME_STRIDE_BYTES);
}

static int fr16_compute_wave_pp(UINTPTR frame_addr, u32 *a_pp, u32 *b_pp)
{
    const fr16_frame_header_t *hdr = (const fr16_frame_header_t *)frame_addr;
    const u32 *wave;
    u32 i;
    int32_t a_min;
    int32_t a_max;
    int32_t b_min;
    int32_t b_max;

    if ((a_pp == NULL) || (b_pp == NULL) ||
        (hdr->wave_offset != FR16_WAVE_OFFSET_BYTES) ||
        (hdr->sample_count == 0U) ||
        (hdr->sample_count > ADC_SAMPLE_COUNT) ||
        (hdr->wave_bytes != (hdr->sample_count * 4U))) {
        return XST_FAILURE;
    }

    wave = (const u32 *)(frame_addr + hdr->wave_offset);
    a_min = a_max = (int16_t)(wave[0] & 0xFFFFU);
    b_min = b_max = (int16_t)((wave[0] >> 16) & 0xFFFFU);

    for (i = 1U; i < hdr->sample_count; i++) {
        u32 pair = wave[i];
        int32_t a = (int16_t)(pair & 0xFFFFU);
        int32_t b = (int16_t)((pair >> 16) & 0xFFFFU);
        if (a < a_min) a_min = a;
        if (a > a_max) a_max = a;
        if (b < b_min) b_min = b;
        if (b > b_max) b_max = b;
    }

    *a_pp = (u32)(a_max - a_min);
    *b_pp = (u32)(b_max - b_min);
    return XST_SUCCESS;
}

static int fr16_validate_frame(UINTPTR frame_addr)
{
    const fr16_frame_header_t *hdr = (const fr16_frame_header_t *)frame_addr;
    const fr16_frame_summary_t *sum;
    const fr16_frame_footer_t *ftr;
    u32 wave_bytes;
    u32 timeline_off;
    u32 summary_off;
    u32 footer_off;
    u32 payload;
    u32 fid;

    if ((hdr->magic != FR16_FRAME_MAGIC) ||
        (hdr->version != FR16_FRAME_VERSION) ||
        (hdr->header_bytes != FR16_HEADER_BYTES) ||
        (hdr->sample_count != g_sample_count) ||
        ((hdr->flags & FR16_REAL_ADC_FLAG) == 0U) ||
        ((hdr->flags & FR16_HOST_TRIGGER_FLAG) == 0U)) {
        g_fr16_bad_header++;
        return -1;
    }

    /* The frame layout is self-describing and follows hdr->sample_count
     * (already matched against the PS-programmed g_sample_count above). */
    wave_bytes   = hdr->sample_count * 4U;
    timeline_off = FR16_HEADER_BYTES + wave_bytes;
    summary_off  = timeline_off + FR16_SENSOR_TIMELINE_BYTES;
    footer_off   = summary_off + FR16_SUMMARY_BYTES;
    payload      = footer_off + FR16_FOOTER_BYTES;
    ftr = (const fr16_frame_footer_t *)(frame_addr + footer_off);

    if ((hdr->frame_bytes != payload) ||
        (hdr->frame_stride != payload) ||
        (hdr->wave_offset != FR16_WAVE_OFFSET_BYTES) ||
        (hdr->wave_bytes != wave_bytes) ||
        (hdr->sensor_timeline_offset != timeline_off) ||
        (hdr->sensor_timeline_bytes != FR16_SENSOR_TIMELINE_BYTES) ||
        (hdr->sensor_timeline_capacity != FR16_SENSOR_TIMELINE_CAPACITY) ||
        (hdr->sensor_timeline_entry_bytes != FR16_SENSOR_TIMELINE_ENTRY_BYTES) ||
        (hdr->summary_offset != summary_off) ||
        (hdr->summary_bytes != FR16_SUMMARY_BYTES) ||
        (hdr->footer_offset != footer_off) ||
        (hdr->footer_bytes != FR16_FOOTER_BYTES) ||
        (hdr->payload_bytes != payload)) {
        g_fr16_bad_header++;
        return -1;
    }

    if ((ftr->magic != FR16_FOOTER_MAGIC) ||
        (ftr->frame_id != hdr->frame_id) ||
        (ftr->frame_words != (payload / 4U)) ||
        (ftr->frame_bytes != payload) ||
        (ftr->payload_bytes != payload) ||
        (ftr->sample_count != g_sample_count) ||
        ((ftr->flags & FR16_REAL_ADC_FLAG) == 0U) ||
        ((ftr->flags & FR16_HOST_TRIGGER_FLAG) == 0U)) {
        g_fr16_bad_footer++;
        return -2;
    }

    sum = (const fr16_frame_summary_t *)(frame_addr + hdr->summary_offset);
    if ((sum->sensor_timeline_offset != timeline_off) ||
        (sum->sensor_timeline_bytes != FR16_SENSOR_TIMELINE_BYTES) ||
        (sum->sensor_timeline_entry_bytes != FR16_SENSOR_TIMELINE_ENTRY_BYTES) ||
        (sum->sensor_timeline_count > FR16_SENSOR_TIMELINE_CAPACITY)) {
        g_fr16_bad_header++;
        return -3;
    }

    if (ftr->sensor_timeline_count != sum->sensor_timeline_count) {
        g_fr16_bad_footer++;
        return -4;
    }

    g_fr16_summary_checked++;
    g_fr16_last_calc_a_pp = sum->adc_a_raw_pp;
    g_fr16_last_calc_b_pp = sum->adc_b_raw_pp;
    calibration_on_sample(sum->adc_a_filt_pp, sum->adc_b_filt_pp);

    fid = ftr->frame_id;
    if (g_fr16_last_frame_id != 0U) {
        u32 delta = fid - g_fr16_last_frame_id;
        if (delta > 1U) g_fr16_missed += delta - 1U;
    }
    g_fr16_last_frame_id = fid;
    g_fr16_last_frame_addr = frame_addr;
    g_fr16_last_pl_overrun = hdr->ddr_overflow_count;
    g_fr16_last_pl_backpressure = hdr->dma_backpressure_count;
    g_fr16_last_pl_fifo_overflow = hdr->axis_fifo_overflow_count;
    return 0;
}

static const char *capture_state_name(capture_state_t state)
{
    switch (state) {
    case CAPTURE_STATE_IDLE:         return "IDLE";
    case CAPTURE_STATE_DMA:          return "DMA";
    case CAPTURE_STATE_SEND_WAVE:    return "SEND_WAVE";
    case CAPTURE_STATE_SEND_SENSOR:  return "SEND_SENSOR";
    case CAPTURE_STATE_SEND_SUMMARY: return "SEND_SUMMARY";
    case CAPTURE_STATE_ERROR:        return "ERROR";
    default:                         return "UNKNOWN";
    }
}

static int fr16_setup_capture_bd(XAxiDma_BdRing *rx_ring,
                                 XAxiDma_Bd *bd,
                                 UINTPTR buf_addr,
                                 u32 len)
{
    int status;

    XAxiDma_BdClear(bd);
    status = XAxiDma_BdSetBufAddr(bd, buf_addr);
    if (status != XST_SUCCESS) return status;

    status = XAxiDma_BdSetLength(bd, len, rx_ring->MaxTransferLen);
    if (status != XST_SUCCESS) return status;

    XAxiDma_BdSetCtrl(bd, 0U);
    XAxiDma_BdSetId(bd, buf_addr);
    return XST_SUCCESS;
}

static int fr16_prepare_capture_bds(void)
{
    XAxiDma_Bd *bd_set;
    XAxiDma_Bd *bd_cur;
    UINTPTR buf_addr;
    u32 remaining;
    u32 len;
    u32 max_len;
    u32 bd_count;
    u32 i;
    int status;

    if (!g_fr16_dma_ready || (g_fr16_rx_ring == NULL)) return XST_FAILURE;

    max_len = g_fr16_rx_ring->MaxTransferLen & ~7U;
    if (max_len == 0U) return XST_FAILURE;

    /* Size the BD chain to the ACTUAL frame length, not the maximum stride:
     * S2MM stops at TLAST and never completes the remaining BDs, so a chain
     * longer than the frame leaves the capture wedged in DMA state (this is
     * what hung auto-mode short frames). */
    bd_count = (fr16_payload_rt() + max_len - 1U) / max_len;
    if ((bd_count == 0U) || (bd_count > FR16_CAPTURE_BD_MAX_COUNT)) {
        xil_printf("FR16 DMA: frame needs %u BDs, limit=%u\r\n",
                   (unsigned int)bd_count,
                   (unsigned int)FR16_CAPTURE_BD_MAX_COUNT);
        return XST_FAILURE;
    }

    if (XAxiDma_BdRingGetFreeCnt(g_fr16_rx_ring) < (int)bd_count) {
        xil_printf("FR16 DMA: not enough free BDs for capture\r\n");
        return XST_FAILURE;
    }

    status = XAxiDma_BdRingAlloc(g_fr16_rx_ring, (int)bd_count, &bd_set);
    if (status != XST_SUCCESS) return status;

    remaining = fr16_payload_rt();
    buf_addr = (UINTPTR)FR16_RING_BASEADDR;
    bd_cur = bd_set;
    for (i = 0U; i < bd_count; i++) {
        len = (remaining > max_len) ? max_len : remaining;
        status = fr16_setup_capture_bd(g_fr16_rx_ring, bd_cur, buf_addr, len);
        if (status != XST_SUCCESS) {
            (void)XAxiDma_BdRingUnAlloc(g_fr16_rx_ring,
                                        (int)bd_count, bd_set);
            return status;
        }
        remaining -= len;
        buf_addr += len;
        bd_cur = (XAxiDma_Bd *)XAxiDma_BdRingNext(g_fr16_rx_ring, bd_cur);
    }

    Xil_DCacheInvalidateRange((UINTPTR)FR16_RING_BASEADDR,
                              fr16_payload_rt());

    status = XAxiDma_BdRingToHw(g_fr16_rx_ring, (int)bd_count, bd_set);
    if (status != XST_SUCCESS) {
        (void)XAxiDma_BdRingUnAlloc(g_fr16_rx_ring, (int)bd_count, bd_set);
        return status;
    }

    g_capture_bd_count = bd_count;
    g_capture_bds_done = 0U;
    g_capture_actual_bytes = 0U;
    g_capture_wave_chunk = 0U;
    g_capture_total_chunks =
        (g_sample_count + WAVE_SAMPLES_PER_PKT - 1U) / WAVE_SAMPLES_PER_PKT;
    g_capture_sensor_chunk = 0U;
    g_capture_total_sensor_chunks = 0U;
    g_capture_sensor_record_count = 0U;
    g_capture_frame_addr = (UINTPTR)FR16_RING_BASEADDR;
    g_capture_validation_rc = 0;
    return XST_SUCCESS;
}

static int fr16_dma_init(void)
{
    XAxiDma_Config *cfg;
    XAxiDma_BdRing *rx_ring;
    XAxiDma_Bd bd_template;
    int status;
    int bd_count;

    /* M2 follows the handoff cache rules: keep DCache enabled, flush BDs before
     * DMA ownership, and invalidate completed BDs/frame buffers before CPU reads. */
    g_fr16_cache_disabled = 0;

    cfg = XAxiDma_LookupConfig(FR16_DMA_DEVICE_ID);
    if (cfg == NULL) {
        xil_printf("FR16 DMA: LookupConfig failed, device_id=%u\r\n",
                   (unsigned int)FR16_DMA_DEVICE_ID);
        return XST_FAILURE;
    }

    status = XAxiDma_CfgInitialize(&g_fr16_dma, cfg);
    if (status != XST_SUCCESS) {
        xil_printf("FR16 DMA: CfgInitialize failed=%d\r\n", status);
        return status;
    }

    if (!XAxiDma_HasSg(&g_fr16_dma)) {
        xil_printf("FR16 DMA: axi_dma_0 is not SG mode\r\n");
        return XST_FAILURE;
    }

    XAxiDma_Reset(&g_fr16_dma);
    while (!XAxiDma_ResetIsDone(&g_fr16_dma)) {
        /* wait for reset */
    }

    XAxiDma_IntrDisable(&g_fr16_dma, XAXIDMA_IRQ_ALL_MASK,
                        XAXIDMA_DEVICE_TO_DMA);

    rx_ring = XAxiDma_GetRxRing(&g_fr16_dma);
    g_fr16_rx_ring = rx_ring;

    bd_count = XAxiDma_BdRingCntCalc(XAXIDMA_BD_MINIMUM_ALIGNMENT,
                                     FR16_BD_SPACE_BYTES);
    if (bd_count < (int)FR16_CAPTURE_BD_MAX_COUNT) {
        xil_printf("FR16 DMA: BD space too small, count=%d\r\n", bd_count);
        return XST_FAILURE;
    }

    status = XAxiDma_BdRingCreate(rx_ring,
                                  (UINTPTR)FR16_BD_SPACE_BASEADDR,
                                  (UINTPTR)FR16_BD_SPACE_BASEADDR,
                                  XAXIDMA_BD_MINIMUM_ALIGNMENT,
                                  bd_count);
    if (status != XST_SUCCESS) {
        xil_printf("FR16 DMA: BdRingCreate failed=%d\r\n", status);
        return status;
    }

    XAxiDma_BdClear(&bd_template);
    status = XAxiDma_BdRingClone(rx_ring, &bd_template);
    if (status != XST_SUCCESS) {
        xil_printf("FR16 DMA: BdRingClone failed=%d\r\n", status);
        return status;
    }

    status = XAxiDma_BdRingStart(rx_ring);
    if (status != XST_SUCCESS) {
        xil_printf("FR16 DMA: BdRingStart failed=%d\r\n", status);
        return status;
    }

    g_fr16_dma_ready = 1;
    g_capture_state = CAPTURE_STATE_IDLE;
    xil_printf("FR16 DMA ready: long_frame_bytes=%u, bd_count=%u, max_bd_len=%u, frame_base=0x%08x\r\n",
               (unsigned int)FR16_FRAME_STRIDE_BYTES,
               (unsigned int)bd_count,
               (unsigned int)rx_ring->MaxTransferLen,
               (unsigned int)FR16_RING_BASEADDR);
    return XST_SUCCESS;
}

static int fr16_capture_start(void)
{
    int status;

    if (!g_fr16_dma_ready) {
        (void)udp_send_text("#ERR,dma_not_ready\r\n");
        return XST_FAILURE;
    }

    if (g_capture_state != CAPTURE_STATE_IDLE) {
        char line[96];
        int n = snprintf(line, sizeof(line), "#BUSY,state=%s\r\n",
                         capture_state_name(g_capture_state));
        if ((n > 0) && (n < (int)sizeof(line))) {
            (void)udp_send_text(line);
        }
        return XST_FAILURE;
    }

    status = fr16_prepare_capture_bds();
    if (status != XST_SUCCESS) {
        (void)udp_send_text("#ERR,capture_dma_arm_failed\r\n");
        return status;
    }

    g_capture_state = CAPTURE_STATE_DMA;
    g_capture_dma_start_ms = get_time_ms();
    write_u32(REG_CAPTURE_CTRL, CAPTURE_START_WORD);
    (void)udp_send_text("#CAPTURE,STARTED\r\n");
    return XST_SUCCESS;
}

static err_t fr16_send_wave_chunk(u32 chunk_idx)
{
    uint8_t pkt[WAVE_PACKET_BYTES];
    const uint8_t *wave;
    const fr16_frame_summary_t *sum =
        (const fr16_frame_summary_t *)(g_capture_frame_addr +
                                       fr16_summary_off_rt());
    u32 start;
    u32 count;
    u32 data_bytes;

    start = chunk_idx * WAVE_SAMPLES_PER_PKT;
    count = g_sample_count - start;
    if (count > WAVE_SAMPLES_PER_PKT) count = WAVE_SAMPLES_PER_PKT;
    data_bytes = count * 4U;

    memset(pkt, 0, sizeof(pkt));
    pkt[0] = 'W'; pkt[1] = 'V'; pkt[2] = '3'; pkt[3] = '2';
    pkt[4] = 1U;
    pkt[5] = WAVE_HEADER_BYTES;
    pkt[6] = 0x03U;
    pkt[7] = 0U;
    put_u32_le(&pkt[8], g_fr16_last_frame_id);
    put_u32_le(&pkt[12], chunk_idx);
    put_u32_le(&pkt[16], g_capture_total_chunks);
    put_u32_le(&pkt[20], start);
    put_u32_le(&pkt[24], count);
    put_u32_le(&pkt[28], g_sample_count);
    put_u32_le(&pkt[32], adc_code_to_mVpp(sum->adc_a_filt_pp));
    put_u32_le(&pkt[36], adc_code_to_mVpp(sum->adc_b_filt_pp));

    wave = (const uint8_t *)(g_capture_frame_addr + FR16_WAVE_OFFSET_BYTES +
                             start * 4U);
    memcpy(&pkt[WAVE_HEADER_BYTES], wave, data_bytes);
    return udp_send_bytes(pkt, (u16)(WAVE_HEADER_BYTES + data_bytes));
}

static err_t fr16_send_sensor_chunk(u32 chunk_idx)
{
    uint8_t pkt[LS32_PACKET_BYTES];
    const uint8_t *records;
    u32 start;
    u32 count;
    u32 data_bytes;

    start = chunk_idx * LS32_RECORDS_PER_PKT;
    count = g_capture_sensor_record_count - start;
    if (count > LS32_RECORDS_PER_PKT) count = LS32_RECORDS_PER_PKT;
    data_bytes = count * LS32_RECORD_BYTES;

    memset(pkt, 0, sizeof(pkt));
    pkt[0] = 'L'; pkt[1] = 'S'; pkt[2] = '3'; pkt[3] = '2';
    pkt[4] = 1U;
    pkt[5] = LS32_HEADER_BYTES;
    pkt[6] = LS32_RECORD_BYTES;
    pkt[7] = 0U;
    put_u32_le(&pkt[8], g_fr16_last_frame_id);
    put_u32_le(&pkt[12], chunk_idx);
    put_u32_le(&pkt[16], g_capture_total_sensor_chunks);
    put_u32_le(&pkt[20], start);
    put_u32_le(&pkt[24], count);
    put_u32_le(&pkt[28], g_capture_sensor_record_count);
    put_u32_le(&pkt[32], g_sample_count);
    put_u32_le(&pkt[36], 0U);

    records = (const uint8_t *)(g_capture_frame_addr +
                                fr16_timeline_off_rt() +
                                start * LS32_RECORD_BYTES);
    memcpy(&pkt[LS32_HEADER_BYTES], records, data_bytes);
    return udp_send_bytes(pkt, (u16)(LS32_HEADER_BYTES + data_bytes));
}

static err_t fr16_send_summary_csv(UINTPTR frame_addr)
{
    const fr16_frame_header_t *hdr = (const fr16_frame_header_t *)frame_addr;
    const fr16_frame_summary_t *sum =
        (const fr16_frame_summary_t *)(frame_addr + fr16_summary_off_rt());
    double a_corr_code;
    double b_corr_code;
    double me_2x_code;
    double sum_corr_code;
    s32 adc_a_corr_uVpp;
    s32 adc_b_corr_uVpp;
    s32 me_2x_uV;
    s32 me_norm_ppm;
    char line[512];
    int n;

    if (g_cal.valid) {
        a_corr_code = g_cal.gain_a * (double)sum->adc_a_filt_pp;
        b_corr_code = g_cal.gain_b * (double)sum->adc_b_filt_pp;
        adc_a_corr_uVpp = adc_code_double_to_uVpp(a_corr_code);
        adc_b_corr_uVpp = adc_code_double_to_uVpp(b_corr_code);
        me_2x_code = b_corr_code - a_corr_code;
        me_2x_uV = adc_code_double_to_uVpp(me_2x_code);
        sum_corr_code = b_corr_code + a_corr_code;
        me_norm_ppm = (sum_corr_code != 0.0) ?
            round_double_to_s32(me_2x_code / sum_corr_code * 1000000.0) : 0;
    } else {
        adc_a_corr_uVpp = 0;
        adc_b_corr_uVpp = 0;
        me_2x_uV = 0;
        me_norm_ppm = 0;
    }

    n = snprintf(line, sizeof(line),
        "%u,%u,%u,%u,%u,%u,%u,%d,%d,%d,%d,%d,%d,0x%08x,%u,"
        "%u,%d,%ld,%ld,%ld,%ld,%ld,%ld,%ld,%u,%u\r\n",
        (unsigned int)hdr->frame_id,
        (unsigned int)sum->adc_a_raw_pp,
        (unsigned int)sum->adc_b_raw_pp,
        (unsigned int)sum->adc_a_filt_pp,
        (unsigned int)sum->adc_b_filt_pp,
        (unsigned int)sum->adc_a_mVpp,
        (unsigned int)sum->adc_b_mVpp,
        (int)sum->l1_um, (int)sum->l2_um, (int)sum->l3_um,
        (int)sum->l4_um, (int)sum->l5_um, (int)sum->temp_x10,
        (unsigned int)sum->sensor_status,
        (unsigned int)g_fr16_missed,
        (unsigned int)g_cal.state,
        g_cal.valid,
        (long)gain_to_ppm(g_cal.gain_a),
        (long)gain_to_ppm(g_cal.gain_b),
        (long)adc_a_corr_uVpp,
        (long)adc_b_corr_uVpp,
        (long)me_2x_uV,
        (long)me_norm_ppm,
        (long)g_cal.verify_mean_uV,
        (unsigned int)sum->sensor_timeline_count,
        (unsigned int)sum->sensor_timeline_overflow);

    if ((n <= 0) || (n >= (int)sizeof(line))) {
        return ERR_BUF;
    }
    return udp_send_text(line);
}

static void fr16_dma_poll(void)
{
    XAxiDma_Bd *bd_set;
    XAxiDma_Bd *bd_cur;
    int bd_done;
    int i;
    const fr16_frame_summary_t *sum;

    if (!g_fr16_dma_ready || (g_fr16_rx_ring == NULL)) return;

    if (g_capture_state == CAPTURE_STATE_DMA) {
        u32 remaining_bds = g_capture_bd_count - g_capture_bds_done;
        if (remaining_bds == 0U) return;

        /* Watchdog: if BDs never complete (e.g. TLAST never arrives), fail
         * the capture so cap_state returns to IDLE and AUTO_STOP/CAPTURE
         * work again. Note: the still-armed BDs stay owned by hardware, so
         * later captures may fail to arm until the board is rebooted. */
        if ((int32_t)(get_time_ms() - g_capture_dma_start_ms) >
            (int32_t)FR16_DMA_TIMEOUT_MS) {
            g_fr16_dma_errors++;
            g_capture_state = CAPTURE_STATE_ERROR;
            (void)udp_send_text("#ERR,capture_dma_timeout,reboot_may_be_required\r\n");
            return;
        }

        bd_done = XAxiDma_BdRingFromHw(g_fr16_rx_ring,
                                       (int)remaining_bds,
                                       &bd_set);
        if (bd_done <= 0) return;

        bd_cur = bd_set;
        for (i = 0; i < bd_done; i++) {
            u32 bd_status = XAxiDma_BdGetSts(bd_cur);
            g_capture_actual_bytes +=
                XAxiDma_BdGetActualLength(bd_cur,
                                           g_fr16_rx_ring->MaxTransferLen);
            if ((bd_status & XAXIDMA_BD_STS_ALL_ERR_MASK) != 0U) {
                g_fr16_dma_errors++;
                g_capture_state = CAPTURE_STATE_ERROR;
                (void)udp_send_text("#ERR,capture_dma_bd_error\r\n");
            }
            bd_cur = (XAxiDma_Bd *)XAxiDma_BdRingNext(g_fr16_rx_ring, bd_cur);
        }

        (void)XAxiDma_BdRingFree(g_fr16_rx_ring, bd_done, bd_set);
        g_capture_bds_done += (u32)bd_done;

        if ((g_capture_state == CAPTURE_STATE_DMA) &&
            (g_capture_bds_done >= g_capture_bd_count)) {
            Xil_DCacheInvalidateRange(g_capture_frame_addr,
                                      fr16_payload_rt());
            if (g_capture_actual_bytes != fr16_payload_rt()) {
                g_fr16_dma_errors++;
                g_capture_state = CAPTURE_STATE_ERROR;
                (void)udp_send_text("#ERR,capture_length_mismatch\r\n");
            } else {
                g_capture_validation_rc =
                    fr16_validate_frame(g_capture_frame_addr);
                if (g_capture_validation_rc == 0) {
                    sum = (const fr16_frame_summary_t *)(g_capture_frame_addr +
                                                         fr16_summary_off_rt());
                    g_fr16_completed++;
                    g_capture_sensor_record_count = sum->sensor_timeline_count;
                    g_capture_total_sensor_chunks =
                        (g_capture_sensor_record_count + LS32_RECORDS_PER_PKT - 1U) /
                        LS32_RECORDS_PER_PKT;
                    g_capture_sensor_chunk = 0U;
                    g_capture_wave_chunk = 0U;
                    g_capture_state = CAPTURE_STATE_SEND_WAVE;
                } else {
                    g_capture_state = CAPTURE_STATE_ERROR;
                    (void)udp_send_text("#ERR,capture_frame_invalid\r\n");
                }
            }
        }
    }

    if (g_capture_state == CAPTURE_STATE_SEND_WAVE) {
        u32 budget = FR16_SEND_CHUNKS_PER_POLL;
        while ((budget > 0U) &&
               (g_capture_wave_chunk < g_capture_total_chunks)) {
            if (fr16_send_wave_chunk(g_capture_wave_chunk) != ERR_OK) {
                return;
            }
            g_capture_wave_chunk++;
            budget--;
        }
        if (g_capture_wave_chunk >= g_capture_total_chunks) {
            /* Auto mode sends summary + waveform only; skip the LS32 timeline
             * even if the (near-empty) short-frame timeline has records. */
            g_capture_state = ((g_capture_sensor_record_count > 0U) &&
                               !g_auto.active) ?
                CAPTURE_STATE_SEND_SENSOR : CAPTURE_STATE_SEND_SUMMARY;
        }
    }

    if (g_capture_state == CAPTURE_STATE_SEND_SENSOR) {
        u32 budget = FR16_SEND_SENSOR_CHUNKS_PER_POLL;
        while ((budget > 0U) &&
               (g_capture_sensor_chunk < g_capture_total_sensor_chunks)) {
            if (fr16_send_sensor_chunk(g_capture_sensor_chunk) != ERR_OK) {
                return;
            }
            g_capture_sensor_chunk++;
            budget--;
        }
        if (g_capture_sensor_chunk >= g_capture_total_sensor_chunks) {
            g_capture_state = CAPTURE_STATE_SEND_SUMMARY;
        }
    }

    if (g_capture_state == CAPTURE_STATE_SEND_SUMMARY) {
        if (fr16_send_summary_csv(g_capture_frame_addr) == ERR_OK) {
            g_capture_state = CAPTURE_STATE_IDLE;
        }
    } else if (g_capture_state == CAPTURE_STATE_ERROR) {
        g_capture_state = CAPTURE_STATE_IDLE;
    }
}

static void fr16_dma_send_status(void)
{
    char line[1024];
    int n;
    u32 pl_status = read_u32(REG_STATUS);
    u32 pl_frame = read_u32(REG_FRAME_ID);
    n = snprintf(line, sizeof(line),
        "#DMA,ready=%d,state=%s,frames=%u,last_frame=%u,missed=%u,bad_header=%u,bad_footer=%u,summary_bad=%u,checked=%u,dma_errors=%u,pl_overrun=%u,pl_backpressure=%u,pl_fifo_overrun=%u,stride=%u,bd_done=%u,bd_total=%u,wave_chunk=%u,wave_total=%u,ls_chunk=%u,ls_total=%u,ls_records=%u,pl_status=0x%08x,pl_frame=%u\r\n",
        g_fr16_dma_ready,
        capture_state_name(g_capture_state),
        (unsigned int)g_fr16_completed,
        (unsigned int)g_fr16_last_frame_id,
        (unsigned int)g_fr16_missed,
        (unsigned int)g_fr16_bad_header,
        (unsigned int)g_fr16_bad_footer,
        (unsigned int)g_fr16_summary_mismatch,
        (unsigned int)g_fr16_summary_checked,
        (unsigned int)g_fr16_dma_errors,
        (unsigned int)g_fr16_last_pl_overrun,
        (unsigned int)g_fr16_last_pl_backpressure,
        (unsigned int)g_fr16_last_pl_fifo_overflow,
        (unsigned int)FR16_FRAME_STRIDE_BYTES,
        (unsigned int)g_capture_bds_done,
        (unsigned int)g_capture_bd_count,
        (unsigned int)g_capture_wave_chunk,
        (unsigned int)g_capture_total_chunks,
        (unsigned int)g_capture_sensor_chunk,
        (unsigned int)g_capture_total_sensor_chunks,
        (unsigned int)g_capture_sensor_record_count,
        (unsigned int)pl_status,
        (unsigned int)pl_frame);
    if ((n > 0) && (n < (int)sizeof(line))) {
        (void)udp_send_text(line);
    }
}

static void fr16_dma_send_debug(void)
{
    char line[1024];
    int n;
    u32 dmacr = Xil_In32((UINTPTR)(FR16_DMA_BASEADDR + FR16_DMA_S2MM_DMACR_OFFSET));
    u32 dmasr = Xil_In32((UINTPTR)(FR16_DMA_BASEADDR + FR16_DMA_S2MM_DMASR_OFFSET));
    u32 curdesc = Xil_In32((UINTPTR)(FR16_DMA_BASEADDR + FR16_DMA_S2MM_CURDESC_OFFSET));
    u32 taildesc = Xil_In32((UINTPTR)(FR16_DMA_BASEADDR + FR16_DMA_S2MM_TAILDESC_OFFSET));
    u32 pl_magic = read_u32(REG_MAGIC);
    u32 pl_status = read_u32(REG_STATUS);
    u32 pl_frame = read_u32(REG_FRAME_ID);
    u32 pl_dbg0 = read_u32(REG_ADC_A_RAW_PP);
    u32 pl_dbg1 = read_u32(REG_ADC_B_RAW_PP);
    u32 pl_dbg2 = read_u32(REG_ADC_A_FILT_PP);
    u32 pl_dbg3 = read_u32(REG_ADC_B_FILT_PP);

    n = snprintf(line, sizeof(line),
        "#DDBG,ready=%d,state=%s,frames=%u,last_frame=%u,cache_off=%d,dmacr=0x%08x,dmasr=0x%08x,halted=%u,idle=%u,sgincld=%u,err=0x%03x,curdesc=0x%08x,taildesc=0x%08x,bd_done=%u,bd_total=%u,bytes=%u,ls_records=%u,pl_magic=0x%08x,pl_status=0x%08x,pl_frame=%u,pl_dbg0=%u,pl_dbg1=%u,pl_dbg2=%u,pl_dbg3=%u\r\n",
        g_fr16_dma_ready,
        capture_state_name(g_capture_state),
        (unsigned int)g_fr16_completed,
        (unsigned int)g_fr16_last_frame_id,
        g_fr16_cache_disabled,
        (unsigned int)dmacr,
        (unsigned int)dmasr,
        (unsigned int)((dmasr & FR16_DMASR_HALTED_MASK) ? 1U : 0U),
        (unsigned int)((dmasr & FR16_DMASR_IDLE_MASK) ? 1U : 0U),
        (unsigned int)((dmasr & FR16_DMASR_SGINCLD_MASK) ? 1U : 0U),
        (unsigned int)(dmasr & FR16_DMASR_ERR_MASK),
        (unsigned int)curdesc,
        (unsigned int)taildesc,
        (unsigned int)g_capture_bds_done,
        (unsigned int)g_capture_bd_count,
        (unsigned int)g_capture_actual_bytes,
        (unsigned int)g_capture_sensor_record_count,
        (unsigned int)pl_magic,
        (unsigned int)pl_status,
        (unsigned int)pl_frame,
        (unsigned int)pl_dbg0,
        (unsigned int)pl_dbg1,
        (unsigned int)pl_dbg2,
        (unsigned int)pl_dbg3);
    if ((n > 0) && (n < (int)sizeof(line))) {
        (void)udp_send_text(line);
    }
}


static void fr16_dma_send_peek(void)
{
    char line[768];
    int n;
    UINTPTR bd0 = (UINTPTR)FR16_BD_SPACE_BASEADDR;
    UINTPTR bd1 = (UINTPTR)(FR16_BD_SPACE_BASEADDR + XAXIDMA_BD_MINIMUM_ALIGNMENT);
    UINTPTR f0  = (UINTPTR)FR16_RING_BASEADDR;
    UINTPTR ft0 = (UINTPTR)(FR16_RING_BASEADDR + FR16_FRAME_STRIDE_BYTES - FR16_FOOTER_BYTES);

    /* Make sure CPU reads what DMA has really written, even if the BD has not
     * been returned by XAxiDma_BdRingFromHw yet. This is a debug-only command. */
    Xil_DCacheInvalidateRange(bd0, 2U * XAXIDMA_BD_MINIMUM_ALIGNMENT);
    Xil_DCacheInvalidateRange(f0, FR16_FRAME_STRIDE_BYTES);

    n = snprintf(line, sizeof(line),
        "#DPEEK,bd0_next=0x%08x,bd0_buf=0x%08x,bd0_ctrl=0x%08x,bd0_sts=0x%08x,"
        "bd1_ctrl=0x%08x,bd1_sts=0x%08x,"
        "f0_w0=0x%08x,f0_w1=0x%08x,f0_w2=0x%08x,f0_w3=0x%08x,f0_w4=0x%08x,"
        "ft0_w0=0x%08x,ft0_w1=0x%08x,ft0_w2=0x%08x,ft0_w3=0x%08x,ft0_w4=0x%08x,ft0_w5=0x%08x\r\n",
        (unsigned int)Xil_In32(bd0 + 0x00U),
        (unsigned int)Xil_In32(bd0 + 0x08U),
        (unsigned int)Xil_In32(bd0 + 0x18U),
        (unsigned int)Xil_In32(bd0 + 0x1CU),
        (unsigned int)Xil_In32(bd1 + 0x18U),
        (unsigned int)Xil_In32(bd1 + 0x1CU),
        (unsigned int)Xil_In32(f0 + 0x00U),
        (unsigned int)Xil_In32(f0 + 0x04U),
        (unsigned int)Xil_In32(f0 + 0x08U),
        (unsigned int)Xil_In32(f0 + 0x0CU),
        (unsigned int)Xil_In32(f0 + 0x10U),
        (unsigned int)Xil_In32(ft0 + 0x00U),
        (unsigned int)Xil_In32(ft0 + 0x04U),
        (unsigned int)Xil_In32(ft0 + 0x08U),
        (unsigned int)Xil_In32(ft0 + 0x0CU),
        (unsigned int)Xil_In32(ft0 + 0x10U),
        (unsigned int)Xil_In32(ft0 + 0x14U));
    if ((n > 0) && (n < (int)sizeof(line))) {
        (void)udp_send_text(line);
    }
}

static void fr16_dma_send_bdwords(void)
{
    char line[1200];
    int n;
    UINTPTR bd0 = (UINTPTR)FR16_BD_SPACE_BASEADDR;
    Xil_DCacheInvalidateRange(bd0, 4U * XAXIDMA_BD_MINIMUM_ALIGNMENT);
    n = snprintf(line, sizeof(line),
        "#BDW,"
        "b0=%08x,%08x,%08x,%08x,%08x,%08x,%08x,%08x,"
        "b1=%08x,%08x,%08x,%08x,%08x,%08x,%08x,%08x,"
        "b2=%08x,%08x,%08x,%08x,%08x,%08x,%08x,%08x,"
        "b3=%08x,%08x,%08x,%08x,%08x,%08x,%08x,%08x\r\n",
        (unsigned int)Xil_In32(bd0 + 0x00U), (unsigned int)Xil_In32(bd0 + 0x04U),
        (unsigned int)Xil_In32(bd0 + 0x08U), (unsigned int)Xil_In32(bd0 + 0x0CU),
        (unsigned int)Xil_In32(bd0 + 0x10U), (unsigned int)Xil_In32(bd0 + 0x14U),
        (unsigned int)Xil_In32(bd0 + 0x18U), (unsigned int)Xil_In32(bd0 + 0x1CU),
        (unsigned int)Xil_In32(bd0 + 0x40U), (unsigned int)Xil_In32(bd0 + 0x44U),
        (unsigned int)Xil_In32(bd0 + 0x48U), (unsigned int)Xil_In32(bd0 + 0x4CU),
        (unsigned int)Xil_In32(bd0 + 0x50U), (unsigned int)Xil_In32(bd0 + 0x54U),
        (unsigned int)Xil_In32(bd0 + 0x58U), (unsigned int)Xil_In32(bd0 + 0x5CU),
        (unsigned int)Xil_In32(bd0 + 0x80U), (unsigned int)Xil_In32(bd0 + 0x84U),
        (unsigned int)Xil_In32(bd0 + 0x88U), (unsigned int)Xil_In32(bd0 + 0x8CU),
        (unsigned int)Xil_In32(bd0 + 0x90U), (unsigned int)Xil_In32(bd0 + 0x94U),
        (unsigned int)Xil_In32(bd0 + 0x98U), (unsigned int)Xil_In32(bd0 + 0x9CU),
        (unsigned int)Xil_In32(bd0 + 0xC0U), (unsigned int)Xil_In32(bd0 + 0xC4U),
        (unsigned int)Xil_In32(bd0 + 0xC8U), (unsigned int)Xil_In32(bd0 + 0xCCU),
        (unsigned int)Xil_In32(bd0 + 0xD0U), (unsigned int)Xil_In32(bd0 + 0xD4U),
        (unsigned int)Xil_In32(bd0 + 0xD8U), (unsigned int)Xil_In32(bd0 + 0xDCU));
    if ((n > 0) && (n < (int)sizeof(line))) {
        (void)udp_send_text(line);
    }
}

static void fr16_dma_send_check(void)
{
    char line[512];
    const fr16_frame_header_t *hdr;
    const fr16_frame_summary_t *sum;
    u32 calc_a_pp = 0U;
    u32 calc_b_pp = 0U;
    int rc;
    int n;

    if (g_fr16_last_frame_addr == (UINTPTR)0U) {
        (void)udp_send_text("#FCHK,ready=0,reason=no_completed_frame\r\n");
        return;
    }

    Xil_DCacheInvalidateRange(g_fr16_last_frame_addr, FR16_FRAME_STRIDE_BYTES);
    hdr = (const fr16_frame_header_t *)g_fr16_last_frame_addr;
    sum = (const fr16_frame_summary_t *)(g_fr16_last_frame_addr + hdr->summary_offset);
    rc = fr16_compute_wave_pp(g_fr16_last_frame_addr, &calc_a_pp, &calc_b_pp);
    n = snprintf(line, sizeof(line),
        "#FCHK,ready=1,frame=%u,rc=%d,summary_a=%u,calc_a=%u,summary_b=%u,calc_b=%u,match=%u\r\n",
        (unsigned int)hdr->frame_id, rc,
        (unsigned int)sum->adc_a_raw_pp, (unsigned int)calc_a_pp,
        (unsigned int)sum->adc_b_raw_pp, (unsigned int)calc_b_pp,
        (unsigned int)((rc == XST_SUCCESS) &&
                       (sum->adc_a_raw_pp == calc_a_pp) &&
                       (sum->adc_b_raw_pp == calc_b_pp)));
    if ((n > 0) && (n < (int)sizeof(line)))
        (void)udp_send_text(line);
}

static void fr16_dma_send_dump(u32 slot, int use_latest)
{
    char line[512];
    UINTPTR addr = use_latest ? g_fr16_last_frame_addr : fr16_frame_addr(slot);
    const fr16_frame_header_t *hdr;
    const fr16_frame_summary_t *sum;
    const fr16_frame_footer_t *ftr;
    int n;

    if (addr == (UINTPTR)0U) {
        (void)udp_send_text("#FDUMP,ready=0,reason=no_completed_frame\r\n");
        return;
    }

    Xil_DCacheInvalidateRange(addr, FR16_FRAME_STRIDE_BYTES);
    hdr = (const fr16_frame_header_t *)addr;
    /* Self-describing layout: follow the offsets stored in the frame so the
     * dump works for both long (manual) and short (auto) frames. */
    sum = (const fr16_frame_summary_t *)(addr + hdr->summary_offset);
    ftr = (const fr16_frame_footer_t *)(addr + hdr->footer_offset);
    n = snprintf(line, sizeof(line),
        "#FDUMP,addr=0x%08x,frame=%u,flags=0x%08x,status=0x%08x,samples=%u,wave_off=%u,wave_bytes=%u,ls_off=%u,ls_bytes=%u,ls_count=%u,summary_off=%u,a_raw=%u,b_raw=%u,a_filt=%u,b_filt=%u,pl_overrun=%u,pl_backpressure=%u,pl_fifo_overrun=%u,footer=0x%08x,footer_frame=%u,words=%u\r\n",
        (unsigned int)addr, (unsigned int)hdr->frame_id,
        (unsigned int)hdr->flags, (unsigned int)hdr->status,
        (unsigned int)hdr->sample_count, (unsigned int)hdr->wave_offset,
        (unsigned int)hdr->wave_bytes,
        (unsigned int)hdr->sensor_timeline_offset,
        (unsigned int)hdr->sensor_timeline_bytes,
        (unsigned int)sum->sensor_timeline_count,
        (unsigned int)hdr->summary_offset,
        (unsigned int)sum->adc_a_raw_pp, (unsigned int)sum->adc_b_raw_pp,
        (unsigned int)sum->adc_a_filt_pp, (unsigned int)sum->adc_b_filt_pp,
        (unsigned int)hdr->ddr_overflow_count,
        (unsigned int)hdr->dma_backpressure_count,
        (unsigned int)hdr->axis_fifo_overflow_count,
        (unsigned int)ftr->magic, (unsigned int)ftr->frame_id,
        (unsigned int)ftr->frame_words);
    if ((n > 0) && (n < (int)sizeof(line)))
        (void)udp_send_text(line);
}
#else
static int fr16_capture_start(void)
{
    (void)udp_send_text("#ERR,dma_not_ready\r\n");
    return XST_FAILURE;
}

static int fr16_dma_init(void)
{
    xil_printf("FR16 DMA: axi_dma_0 not present in BSP yet; using legacy AXI-Lite path\r\n");
    return XST_FAILURE;
}

static void fr16_dma_poll(void)
{
}

static void fr16_dma_send_status(void)
{
    (void)udp_send_text("#DMA,ready=0,reason=axi_dma_0_not_present_in_bsp\r\n");
}

static void fr16_dma_send_debug(void)
{
    (void)udp_send_text("#DDBG,ready=0,reason=axi_dma_0_not_present_in_bsp\r\n");
}

static void fr16_dma_send_peek(void)
{
    (void)udp_send_text("#DPEEK,ready=0,reason=axi_dma_0_not_present_in_bsp\r\n");
}

static void fr16_dma_send_bdwords(void)
{
    (void)udp_send_text("#BDW,ready=0,reason=axi_dma_0_not_present_in_bsp\r\n");
}

static void fr16_dma_send_check(void)
{
    (void)udp_send_text("#FCHK,ready=0,reason=axi_dma_0_not_present_in_bsp\r\n");
}

static void fr16_dma_send_dump(u32 slot, int use_latest)
{
    (void)slot;
    (void)use_latest;
    (void)udp_send_text("#FDUMP,ready=0,reason=axi_dma_0_not_present_in_bsp\r\n");
}
#endif

static err_t udp_send_bytes(const void *data, u16 len)
{
    struct pbuf *p;
    err_t err;
    if (!g_udp_ready || (g_udp_pcb == NULL) ||
        (data == NULL) || (len == 0U)) return ERR_VAL;

    p = pbuf_alloc(PBUF_TRANSPORT, len, PBUF_RAM);
    if (p == NULL) {
        xil_printf("pbuf_alloc failed, len=%u\r\n", len);
        return ERR_MEM;
    }
    memcpy(p->payload, data, len);
    err = udp_send(g_udp_pcb, p);
    pbuf_free(p);
    return err;
}

static err_t udp_send_text(const char *text)
{
    if (text == NULL) return ERR_VAL;
    return udp_send_bytes(text, (u16)strlen(text));
}

static const char *cal_state_name(calibration_state_t state)
{
    switch (state) {
    case CAL_STATE_IDLE:    return "IDLE";
    case CAL_STATE_DISCARD: return "DISCARD";
    case CAL_STATE_COLLECT: return "COLLECT";
    case CAL_STATE_COMPUTE: return "COMPUTE";
    case CAL_STATE_VERIFY:  return "VERIFY";
    case CAL_STATE_READY:   return "READY";
    case CAL_STATE_FAILED:  return "FAILED";
    default:                return "UNKNOWN";
    }
}

static void calibration_send_status(const char *event)
{
    char line[320];
    u32 progress = 0U;
    u32 target = 0U;
    int n;

    if (g_cal.state == CAL_STATE_DISCARD) {
        progress = g_cal.discard_count;
        target = CAL_DISCARD_FRAMES;
    } else if (g_cal.state == CAL_STATE_COLLECT) {
        progress = g_cal.collect_a.count;
        target = CAL_COLLECT_FRAMES;
    } else if (g_cal.state == CAL_STATE_VERIFY) {
        progress = g_cal.verify_diff.count;
        target = CAL_VERIFY_FRAMES;
    }

    n = snprintf(line, sizeof(line),
        "#CAL,event=%s,state=%u,state_name=%s,valid=%d,"
        "attempt=%u,progress=%u,target=%u,invalid=%u,"
        "gain_a_ppm=%ld,gain_b_ppm=%ld,"
        "zero_a_uVpp=%ld,zero_b_uVpp=%ld,"
        "verify_mean_uV=%ld,verify_std_uV=%ld,verify_drift_uV=%ld\r\n",
        (event != NULL) ? event : "STATUS",
        (unsigned int)g_cal.state,
        cal_state_name(g_cal.state),
        g_cal.valid,
        (unsigned int)g_cal.attempt,
        (unsigned int)progress,
        (unsigned int)target,
        (unsigned int)g_cal.invalid_count,
        (long)gain_to_ppm(g_cal.gain_a),
        (long)gain_to_ppm(g_cal.gain_b),
        (long)adc_code_double_to_uVpp(g_cal.zero_mean_a_code),
        (long)adc_code_double_to_uVpp(g_cal.zero_mean_b_code),
        (long)g_cal.verify_mean_uV,
        (long)g_cal.verify_std_uV,
        (long)g_cal.verify_drift_uV);

    if ((n > 0) && (n < (int)sizeof(line))) {
        (void)udp_send_text(line);
    }
}

static void calibration_reset_statistics(void)
{
    stats_reset(&g_cal.collect_a);
    stats_reset(&g_cal.collect_b);
    stats_reset(&g_cal.collect_diff);
    stats_reset(&g_cal.verify_diff);
    stats_reset(&g_cal.verify_first_half);
    stats_reset(&g_cal.verify_second_half);
    g_cal.discard_count = 0U;
    g_cal.invalid_count = 0U;
    g_cal.verify_mean_uV = 0;
    g_cal.verify_std_uV = 0;
    g_cal.verify_drift_uV = 0;
}

static void calibration_init(void)
{
    memset(&g_cal, 0, sizeof(g_cal));
    g_cal.state = CAL_STATE_IDLE;
    g_cal.valid = 0;
    g_cal.gain_a = 1.0;
    g_cal.gain_b = 1.0;
    calibration_reset_statistics();
}

static void calibration_start_new(void)
{
    g_cal.state = CAL_STATE_DISCARD;
    g_cal.valid = 0;
    g_cal.attempt = 1U;
    g_cal.zero_mean_a_code = 0.0;
    g_cal.zero_mean_b_code = 0.0;
    g_cal.reference_code = 0.0;
    g_cal.gain_a = 1.0;
    g_cal.gain_b = 1.0;
    calibration_reset_statistics();
    xil_printf("CAL_START: unload torque and keep system stable\r\n");
    calibration_send_status("STARTED");
}

static void calibration_abort(void)
{
    g_cal.state = CAL_STATE_IDLE;
    g_cal.valid = 0;
    g_cal.gain_a = 1.0;
    g_cal.gain_b = 1.0;
    calibration_reset_statistics();
    xil_printf("Calibration aborted\r\n");
    calibration_send_status("ABORTED");
}

static void calibration_clear(void)
{
    calibration_init();
    xil_printf("Calibration parameters cleared\r\n");
    calibration_send_status("CLEARED");
}

static void calibration_begin_retry(const char *reason)
{
    if (g_cal.attempt < CAL_MAX_RETRIES) {
        g_cal.attempt++;
        g_cal.state = CAL_STATE_DISCARD;
        calibration_reset_statistics();
        xil_printf("Calibration retry %u/%u\r\n",
                   (unsigned int)g_cal.attempt,
                   (unsigned int)CAL_MAX_RETRIES);
        calibration_send_status((reason != NULL) ? reason : "RETRY");
    } else {
        g_cal.state = CAL_STATE_FAILED;
        g_cal.valid = 0;
        xil_printf("Calibration failed after %u attempts\r\n",
                   (unsigned int)CAL_MAX_RETRIES);
        calibration_send_status((reason != NULL) ? reason : "FAILED");
    }
}

static int calibration_sample_is_valid(u32 a_code, u32 b_code)
{
    if ((a_code < CAL_MIN_VALID_PP_CODE) ||
        (b_code < CAL_MIN_VALID_PP_CODE)) return 0;
    if ((a_code > CAL_MAX_VALID_PP_CODE) ||
        (b_code > CAL_MAX_VALID_PP_CODE)) return 0;
    return 1;
}

static void calibration_compute_gains(void)
{
    if ((g_cal.collect_a.count < CAL_COLLECT_FRAMES) ||
        (g_cal.collect_b.count < CAL_COLLECT_FRAMES) ||
        (g_cal.collect_a.mean <= 0.0) ||
        (g_cal.collect_b.mean <= 0.0)) {
        calibration_begin_retry("COMPUTE_INVALID");
        return;
    }

    g_cal.state = CAL_STATE_COMPUTE;
    g_cal.zero_mean_a_code = g_cal.collect_a.mean;
    g_cal.zero_mean_b_code = g_cal.collect_b.mean;
    g_cal.reference_code = 0.5 * (g_cal.zero_mean_a_code +
                                  g_cal.zero_mean_b_code);
    g_cal.gain_a = g_cal.reference_code / g_cal.zero_mean_a_code;
    g_cal.gain_b = g_cal.reference_code / g_cal.zero_mean_b_code;

    stats_reset(&g_cal.verify_diff);
    stats_reset(&g_cal.verify_first_half);
    stats_reset(&g_cal.verify_second_half);
    g_cal.state = CAL_STATE_VERIFY;

    xil_printf("Calibration gains computed: A=%ld ppm, B=%ld ppm\r\n",
               (long)gain_to_ppm(g_cal.gain_a),
               (long)gain_to_ppm(g_cal.gain_b));
    calibration_send_status("GAINS_COMPUTED");
}

static void calibration_finish_verification(void)
{
    double variance_code2 = stats_variance(&g_cal.verify_diff);
    double std_code = sqrt_local(variance_code2);
    double mean_uv_d = g_cal.verify_diff.mean *
                       ADC_MODULE_FS_UVPP_D / ADC_FULL_SCALE_CODES_D;
    double std_uv_d = std_code *
                      ADC_MODULE_FS_UVPP_D / ADC_FULL_SCALE_CODES_D;
    double drift_uv_d = (g_cal.verify_first_half.mean -
                         g_cal.verify_second_half.mean) *
                        ADC_MODULE_FS_UVPP_D / ADC_FULL_SCALE_CODES_D;
    int pass_mean;
    int pass_std;
    int pass_drift;

    g_cal.verify_mean_uV = round_double_to_s32(mean_uv_d);
    g_cal.verify_std_uV = round_double_to_s32(std_uv_d);
    g_cal.verify_drift_uV = round_double_to_s32(drift_uv_d);

    pass_mean = abs_double(mean_uv_d) <= (double)CAL_VERIFY_MEAN_LIMIT_UV;
    pass_std = std_uv_d <= (double)CAL_VERIFY_STD_LIMIT_UV;
    pass_drift = abs_double(drift_uv_d) <= (double)CAL_VERIFY_DRIFT_LIMIT_UV;

    if (pass_mean && pass_std && pass_drift) {
        g_cal.state = CAL_STATE_READY;
        g_cal.valid = 1;
        xil_printf("Calibration READY: mean=%ld uV, std=%ld uV, drift=%ld uV\r\n",
                   (long)g_cal.verify_mean_uV,
                   (long)g_cal.verify_std_uV,
                   (long)g_cal.verify_drift_uV);
        calibration_send_status("READY");
    } else {
        xil_printf("Calibration verify failed: mean=%ld uV, std=%ld uV, drift=%ld uV\r\n",
                   (long)g_cal.verify_mean_uV,
                   (long)g_cal.verify_std_uV,
                   (long)g_cal.verify_drift_uV);
        calibration_begin_retry("VERIFY_FAILED");
    }
}

static void calibration_on_sample(u32 a_code, u32 b_code)
{
    double a;
    double b;
    double corrected_diff;
    u32 verify_index;

    if ((g_cal.state == CAL_STATE_IDLE) ||
        (g_cal.state == CAL_STATE_READY) ||
        (g_cal.state == CAL_STATE_FAILED)) return;

    if (!calibration_sample_is_valid(a_code, b_code)) {
        g_cal.invalid_count++;
        if (g_cal.invalid_count >= CAL_MAX_INVALID_FRAMES) {
            calibration_begin_retry("TOO_MANY_INVALID");
        }
        return;
    }

    a = (double)a_code;
    b = (double)b_code;

    switch (g_cal.state) {
    case CAL_STATE_DISCARD:
        g_cal.discard_count++;
        if (g_cal.discard_count >= CAL_DISCARD_FRAMES) {
            stats_reset(&g_cal.collect_a);
            stats_reset(&g_cal.collect_b);
            stats_reset(&g_cal.collect_diff);
            g_cal.state = CAL_STATE_COLLECT;
            calibration_send_status("COLLECTING");
        }
        break;

    case CAL_STATE_COLLECT:
        stats_push(&g_cal.collect_a, a);
        stats_push(&g_cal.collect_b, b);
        stats_push(&g_cal.collect_diff, b - a);
        if (g_cal.collect_a.count >= CAL_COLLECT_FRAMES) {
            calibration_compute_gains();
        }
        break;

    case CAL_STATE_VERIFY:
        corrected_diff = g_cal.gain_b * b - g_cal.gain_a * a;
        stats_push(&g_cal.verify_diff, corrected_diff);
        verify_index = g_cal.verify_diff.count;
        if (verify_index <= (CAL_VERIFY_FRAMES / 2U)) {
            stats_push(&g_cal.verify_first_half, corrected_diff);
        } else {
            stats_push(&g_cal.verify_second_half, corrected_diff);
        }
        if (g_cal.verify_diff.count >= CAL_VERIFY_FRAMES) {
            calibration_finish_verification();
        }
        break;

    case CAL_STATE_COMPUTE:
    default:
        break;
    }
}

/* --------------------------------------------------------------------------
 * PL reset control retained from the current stable echo.c
 * -------------------------------------------------------------------------- */
static u32 get_time_ms(void)
{
    XTime t;
    XTime_GetTime(&t);
    return (u32)((t * 1000ULL) / COUNTS_PER_SECOND);
}

static void reset_frame_tracking(void)
{
    g_last_frame_id = 0xFFFFFFFFU;
    g_output_divider = 0U;
    g_wave_divider = 0U;
    g_missed_total = 0U;
#if HAVE_FR16_AXI_DMA
    g_fr16_missed = 0U;
    g_fr16_last_frame_id = 0U;
    g_fr16_last_frame_addr = (UINTPTR)0U;
    g_capture_state = CAPTURE_STATE_IDLE;
    g_capture_bds_done = 0U;
    g_capture_wave_chunk = 0U;
    g_capture_sensor_chunk = 0U;
    g_capture_sensor_record_count = 0U;
    g_capture_total_sensor_chunks = 0U;
#endif
}
static void delay_ms_blocking(u32 ms)
{
    XTime t0;
    XTime now;
    XTime ticks = ((XTime)ms * (XTime)COUNTS_PER_SECOND) / 1000ULL;

    XTime_GetTime(&t0);
    do {
        XTime_GetTime(&now);
    } while ((now - t0) < ticks);
}


void application_pre_network_init(void)
{
    /* Assert PL reset before lwIP/xemac_add() starts its blocking initial PHY
     * setup. This prevents the ADC/FR16 source from running before the SG ring
     * exists and removes the boot-only summary/overrun transient.
     */
    write_u32(REG_PL_RESET_CTRL, PL_RESET_ASSERT_WORD);
    g_pl_reset_active = 1;
    g_startup_capture_hold = 1;
    g_startup_dma_ready = 0;
    g_startup_link_up_since_ms = 0U;
    g_startup_link_wait_reported = 0;
    g_pl_reset_deadline_ms = 0U;
    reset_frame_tracking();
    xil_printf("M2 pre-network: real ADC capture held in reset\r\n");
}

static void pl_reset_assert_hold(void)
{
    write_u32(REG_PL_RESET_CTRL, PL_RESET_ASSERT_WORD);
    g_pl_reset_active = 1;
    g_pl_reset_deadline_ms = get_time_ms() + PL_RESET_KEEPALIVE_MS;
    reset_frame_tracking();

    /* An in-progress calibration cannot remain valid across an interrupted
     * sample sequence. A completed/frozen calibration is retained.
     */
    if ((g_cal.state == CAL_STATE_DISCARD) ||
        (g_cal.state == CAL_STATE_COLLECT) ||
        (g_cal.state == CAL_STATE_COMPUTE) ||
        (g_cal.state == CAL_STATE_VERIFY)) {
        g_cal.state = CAL_STATE_IDLE;
        g_cal.valid = 0;
        g_cal.gain_a = 1.0;
        g_cal.gain_b = 1.0;
        calibration_reset_statistics();
        calibration_send_status("ABORTED_BY_PL_RESET");
    }
}

static void pl_reset_release_hold(void)
{
    write_u32(REG_PL_RESET_CTRL, PL_RESET_RELEASE_WORD);
    g_pl_reset_active = 0;
    reset_frame_tracking();
}

static void pl_reset_poll_watchdog(void)
{
    u32 now;

    /* The startup hold is intentional and may last indefinitely when no cable
     * is connected. Only a user-issued PLRST,1 hold uses the 600 ms watchdog.
     */
    if (!g_pl_reset_active || g_startup_capture_hold) {
        return;
    }

    now = get_time_ms();
    if ((int32_t)(now - g_pl_reset_deadline_ms) >= 0) {
        /* If a release packet is lost, automatically release PL. While the
         * GUI button is held, repeated PLRST,1 packets extend this deadline.
         */
        pl_reset_release_hold();
    }
}


static void m2_startup_capture_poll(void)
{
    u32 now;

    if (!g_startup_capture_hold || !g_startup_dma_ready) {
        return;
    }

    if ((echo_netif == NULL) || !netif_is_link_up(echo_netif)) {
        g_startup_link_up_since_ms = 0U;
        if (!g_startup_link_wait_reported) {
            xil_printf("M2 startup: waiting for Ethernet link before capture release\r\n");
            g_startup_link_wait_reported = 1;
        }
        return;
    }

    now = get_time_ms();
    if (g_startup_link_up_since_ms == 0U) {
        g_startup_link_up_since_ms = now;
        xil_printf("M2 startup: Ethernet link up, stability timer started (%u ms)\r\n",
                   (unsigned int)M2_LINK_STABLE_MS);
        return;
    }

    if ((u32)(now - g_startup_link_up_since_ms) >= M2_LINK_STABLE_MS) {
        g_startup_capture_hold = 0;
        g_startup_dma_ready = 0;
        pl_reset_release_hold();
        xil_printf("M2 startup: link stable, DMA ring ready, real ADC capture released\r\n");
    }
}


/* --------------------------------------------------------------------------
 * Auto acquisition mode
 *
 * Trigger model (keyphasor-like): t_idle counts up continuously. Once
 * t_idle > t_speed_ms the detection window is open (t_speed = shaft period
 * from rpm minus AUTO_T_SPEED_MARGIN_MS, so the window opens ~5 ms before the
 * marker comes around). The first L2_um sample below l_threshold_um inside
 * the window fires one short capture and resets t_idle. L2 only dips near the
 * marker, so no separate edge detector is needed.
 *
 * Auto mode uses the runtime short frame (g_auto.sample_count points) and
 * sends only WV32 waveform + summary CSV (LS32 timeline is skipped in
 * fr16_dma_poll). Manual CAPTURE is rejected while auto mode is active;
 * AUTO_STOP is the only way back to manual mode. Requires calibration READY.
 * -------------------------------------------------------------------------- */
#if HAVE_FR16_AXI_DMA
static void auto_mode_init(void)
{
    /* Preset defaults; AUTO_START without arguments and AUTO_CFG while
     * inactive both start from these. */
    g_auto.active = 0;
    g_auto.l_threshold_um = AUTO_DEFAULT_L_THRESHOLD_UM;
    g_auto.rpm = AUTO_DEFAULT_RPM;
    g_auto.t_speed_ms = 60000U / AUTO_DEFAULT_RPM - AUTO_T_SPEED_MARGIN_MS;
    g_auto.sample_count = AUTO_DEFAULT_POINTS;
    g_auto.t_idle_ms = 0U;
    g_auto.last_tick_ms = 0U;
    g_auto.last_l2_um = 0;
    g_auto.trigger_count = 0U;
}

static int auto_compute_t_speed(u32 rpm, u32 *t_speed_ms)
{
    u32 period_ms;

    if ((rpm == 0U) || (rpm > 60000U / (AUTO_T_SPEED_MARGIN_MS + 1U))) {
        return XST_FAILURE;
    }
    /* Integer ms per revolution (< 1 ms truncation error, acceptable here). */
    period_ms = 60000U / rpm;
    if (period_ms <= AUTO_T_SPEED_MARGIN_MS) {
        return XST_FAILURE;
    }
    if ((period_ms - AUTO_T_SPEED_MARGIN_MS) < AUTO_MIN_T_SPEED_MS) {
        return XST_FAILURE;
    }
    *t_speed_ms = period_ms - AUTO_T_SPEED_MARGIN_MS;
    return XST_SUCCESS;
}

/* Parse up to max_fields comma-separated u32 values from str (which may be
 * NULL/empty for "use defaults"). Modifies str in place. Returns field count. */
static int auto_parse_u32_fields(char *str, u32 *out, int max_fields)
{
    int n = 0;
    char *p = str;
    char *comma;

    while ((n < max_fields) && (p != NULL) && (*p != '\0')) {
        comma = strchr(p, ',');
        if (comma != NULL) *comma = '\0';
        out[n++] = (u32)strtoul(p, NULL, 0);
        p = (comma != NULL) ? (comma + 1) : NULL;
    }
    return n;
}

static void auto_mode_stop(void)
{
    g_auto.active = 0;
    /* Restore the manual-mode long frame. Caller must ensure capture IDLE. */
    (void)fr16_set_sample_count(ADC_SAMPLE_COUNT);
}

static void auto_mode_cmd_start(char *args)
{
    u32 fields[3];
    int n;
    u32 rpm = g_auto.rpm;
    s32 thr = g_auto.l_threshold_um;
    u32 points = g_auto.sample_count;
    u32 t_speed;
    char line[160];

    if (!g_fr16_dma_ready) {
        (void)udp_send_text("#ERR,dma_not_ready\r\n");
        return;
    }
    if (g_startup_capture_hold) {
        (void)udp_send_text("#ERR,startup_wait_link\r\n");
        return;
    }
    if (g_pl_reset_active) {
        (void)udp_send_text("#ERR,pl_reset_active\r\n");
        return;
    }
    if (g_auto.active) {
        (void)udp_send_text("#ERR,auto_already_active\r\n");
        return;
    }
    if (g_capture_state != CAPTURE_STATE_IDLE) {
        (void)udp_send_text("#BUSY,capture_active\r\n");
        return;
    }
    if ((g_cal.state != CAL_STATE_READY) || !g_cal.valid) {
        (void)udp_send_text("#ERR,not_calibrated\r\n");
        return;
    }

    if ((args != NULL) && (*args != '\0')) {
        n = auto_parse_u32_fields(args, fields, 3);
        if (n >= 1) rpm = fields[0];
        if (n >= 2) thr = (s32)fields[1];
        if (n >= 3) points = fields[2];
    }

    if (auto_compute_t_speed(rpm, &t_speed) != XST_SUCCESS) {
        (void)udp_send_text("#ERR,bad_rpm\r\n");
        return;
    }
    if (fr16_set_sample_count(points) != XST_SUCCESS) {
        (void)udp_send_text("#ERR,bad_points\r\n");
        return;
    }

    g_auto.l_threshold_um = thr;
    g_auto.rpm = rpm;
    g_auto.t_speed_ms = t_speed;
    g_auto.sample_count = points;
    g_auto.t_idle_ms = 0U;
    g_auto.last_tick_ms = get_time_ms();
    g_auto.last_l2_um = 0;
    g_auto.trigger_count = 0U;
    g_auto.active = 1;

    (void)snprintf(line, sizeof(line),
        "#AUTO,STARTED,rpm=%u,t_speed_ms=%u,thr_um=%ld,points=%u\r\n",
        (unsigned int)rpm, (unsigned int)t_speed, (long)thr,
        (unsigned int)points);
    (void)udp_send_text(line);
}

static void auto_mode_cmd_stop(const char *reason)
{
    char line[128];

    if (!g_auto.active) {
        (void)udp_send_text("#ERR,auto_not_active\r\n");
        return;
    }
    if (g_capture_state != CAPTURE_STATE_IDLE) {
        /* g_sample_count follows the PL register immediately; changing it
         * mid-frame would corrupt parsing of the in-flight frame. */
        (void)udp_send_text("#BUSY,capture_active\r\n");
        return;
    }
    (void)snprintf(line, sizeof(line), "#AUTO,STOPPED,reason=%s,triggers=%u\r\n",
                   reason, (unsigned int)g_auto.trigger_count);
    auto_mode_stop();
    (void)udp_send_text(line);
}

static void auto_mode_cmd_cfg(char *args)
{
    u32 fields[3];
    int n;
    u32 rpm;
    s32 thr;
    u32 points;
    u32 t_speed;
    char line[160];

    n = auto_parse_u32_fields(args, fields, 3);
    if (n < 1) {
        (void)udp_send_text("#ERR,bad_cfg\r\n");
        return;
    }

    rpm = (n >= 1) ? fields[0] : g_auto.rpm;
    thr = (n >= 2) ? (s32)fields[1] : g_auto.l_threshold_um;
    points = (n >= 3) ? fields[2] : g_auto.sample_count;

    if (auto_compute_t_speed(rpm, &t_speed) != XST_SUCCESS) {
        (void)udp_send_text("#ERR,bad_rpm\r\n");
        return;
    }
    if ((points < ADC_SAMPLE_COUNT_MIN) || (points > ADC_SAMPLE_COUNT)) {
        (void)udp_send_text("#ERR,bad_points\r\n");
        return;
    }
    if (g_auto.active && (points != g_auto.sample_count) &&
        (g_capture_state != CAPTURE_STATE_IDLE)) {
        (void)udp_send_text("#BUSY,capture_active\r\n");
        return;
    }

    if (g_auto.active && (points != g_auto.sample_count)) {
        (void)fr16_set_sample_count(points);
    }
    /* Inactive: fields become the preset for the next AUTO_START. */
    g_auto.sample_count = points;
    g_auto.rpm = rpm;
    g_auto.l_threshold_um = thr;
    g_auto.t_speed_ms = t_speed;

    (void)snprintf(line, sizeof(line),
        "#AUTO,CFG_OK,active=%d,rpm=%u,t_speed_ms=%u,thr_um=%ld,points=%u\r\n",
        g_auto.active, (unsigned int)rpm, (unsigned int)t_speed, (long)thr,
        (unsigned int)points);
    (void)udp_send_text(line);
}

static void auto_mode_send_status(void)
{
    char line[224];

    (void)snprintf(line, sizeof(line),
        "#AUTO,active=%d,rpm=%u,t_speed_ms=%u,thr_um=%ld,points=%u,"
        "t_idle_ms=%u,last_l2_um=%ld,triggers=%u,cal_state=%u,cal_valid=%d,"
        "cap_state=%s\r\n",
        g_auto.active,
        (unsigned int)g_auto.rpm,
        (unsigned int)g_auto.t_speed_ms,
        (long)g_auto.l_threshold_um,
        (unsigned int)g_auto.sample_count,
        (unsigned int)g_auto.t_idle_ms,
        (long)g_auto.last_l2_um,
        (unsigned int)g_auto.trigger_count,
        (unsigned int)g_cal.state,
        g_cal.valid,
        capture_state_name(g_capture_state));
    (void)udp_send_text(line);
}

static void auto_mode_poll(void)
{
    u32 now;
    s32 l2;

    if (!g_auto.active) return;

    now = get_time_ms();
    if (now != g_auto.last_tick_ms) {
        g_auto.t_idle_ms += (now - g_auto.last_tick_ms);
        g_auto.last_tick_ms = now;
    }

    l2 = read_s32(REG_LASER2_UM);
    g_auto.last_l2_um = l2;

    if ((g_auto.t_idle_ms > g_auto.t_speed_ms) &&
        (l2 < g_auto.l_threshold_um) &&
        (g_capture_state == CAPTURE_STATE_IDLE)) {
        g_auto.t_idle_ms = 0U;
        g_auto.trigger_count++;
        (void)fr16_capture_start();
    }
}

#else /* !HAVE_FR16_AXI_DMA: auto mode needs the DMA capture path */
static void auto_mode_init(void) { g_auto.active = 0; }
static void auto_mode_stop(void) { g_auto.active = 0; }
static void auto_mode_poll(void) { }
static void auto_mode_cmd_start(char *args)
{
    (void)args;
    (void)udp_send_text("#ERR,dma_not_ready\r\n");
}
static void auto_mode_cmd_stop(const char *reason)
{
    (void)reason;
    (void)udp_send_text("#ERR,dma_not_ready\r\n");
}
static void auto_mode_cmd_cfg(char *args)
{
    (void)args;
    (void)udp_send_text("#ERR,dma_not_ready\r\n");
}
static void auto_mode_send_status(void)
{
    (void)udp_send_text("#AUTO,active=0,reason=dma_not_ready\r\n");
}
#endif




/* --------------------------------------------------------------------------
 * Unified UDP command receiver
 *
 * Keep the const callback signature used by the user's current SDK project.
 * -------------------------------------------------------------------------- */
static void udp_command_recv(void *arg,
                             struct udp_pcb *pcb,
                             struct pbuf *p,
                             const ip_addr_t *addr,
                             u16_t port)
{
    char cmd[64];
    u16_t len;
    u16_t copied;

    (void)arg;
    (void)pcb;
    (void)addr;
    (void)port;

    if (p == NULL) {
        return;
    }

    len = p->tot_len;
    if (len >= (u16_t)sizeof(cmd)) {
        len = (u16_t)(sizeof(cmd) - 1U);
    }

    copied = pbuf_copy_partial(p, cmd, len, 0U);
    cmd[copied] = '\0';
    pbuf_free(p);

    while ((copied > 0U) &&
           ((cmd[copied - 1U] == '\r') ||
            (cmd[copied - 1U] == '\n') ||
            (cmd[copied - 1U] == ' ') ||
            (cmd[copied - 1U] == '\t'))) {
        copied--;
        cmd[copied] = '\0';
    }

    if ((strcmp(cmd, "PLRST,1") == 0) ||
        (strcmp(cmd, "PL_RESET_ASSERT") == 0)) {
#if HAVE_FR16_AXI_DMA
        if (g_capture_state != CAPTURE_STATE_IDLE) {
            (void)udp_send_text("#BUSY,pl_reset_rejected\r\n");
        } else
#endif
        {
            /* A PL reset would silently drop auto triggers; leave auto mode
             * first and restore the long-frame length. */
            if (g_auto.active) {
                auto_mode_stop();
                (void)udp_send_text("#AUTO,STOPPED,reason=pl_reset\r\n");
            }
            pl_reset_assert_hold();
        }

    } else if ((strcmp(cmd, "PLRST,0") == 0) ||
               (strcmp(cmd, "PL_RESET_RELEASE") == 0)) {
#if HAVE_FR16_AXI_DMA
        if (g_capture_state != CAPTURE_STATE_IDLE) {
            (void)udp_send_text("#BUSY,pl_reset_rejected\r\n");
        } else
#endif
        if (g_startup_capture_hold) {
            (void)udp_send_text("#ERR,startup_wait_link\r\n");
        } else {
            pl_reset_release_hold();
        }

    } else if ((strcmp(cmd, "CAPTURE") == 0) ||
               (strcmp(cmd, "CAP_START") == 0)) {
        if (g_startup_capture_hold) {
            (void)udp_send_text("#ERR,startup_wait_link\r\n");
        } else if (g_pl_reset_active) {
            (void)udp_send_text("#ERR,pl_reset_active\r\n");
        } else if (g_auto.active) {
            /* Manual trigger is rejected while auto mode runs; AUTO_STOP
             * is the only way back to manual mode. */
            (void)udp_send_text("#ERR,auto_active\r\n");
        } else {
            (void)fr16_capture_start();
        }

    } else if (strcmp(cmd, "CAL_START") == 0) {
        if (g_pl_reset_active) {
            (void)udp_send_text("#ERR,pl_reset_active\r\n");
        } else if (g_auto.active) {
            /* Calibration needs manual long frames. */
            (void)udp_send_text("#ERR,auto_active\r\n");
        } else {
            calibration_start_new();
        }

    } else if ((strcmp(cmd, "AUTO_START") == 0) ||
               (strncmp(cmd, "AUTO_START,", 11U) == 0)) {
        auto_mode_cmd_start((cmd[10] == ',') ? (cmd + 11) : NULL);

    } else if (strcmp(cmd, "AUTO_STOP") == 0) {
        auto_mode_cmd_stop("host");

    } else if (strncmp(cmd, "AUTO_CFG,", 9U) == 0) {
        auto_mode_cmd_cfg(cmd + 9);

    } else if (strcmp(cmd, "AUTO_STATUS") == 0) {
        auto_mode_send_status();

    } else if (strcmp(cmd, "CAL_ABORT") == 0) {
        calibration_abort();

    } else if (strcmp(cmd, "CAL_CLEAR") == 0) {
        /* Clearing calibration invalidates the auto-mode entry condition;
         * stop auto mode so it must be re-entered after a fresh calibration. */
        if (g_auto.active) {
            if (g_capture_state != CAPTURE_STATE_IDLE) {
                (void)udp_send_text("#BUSY,capture_active\r\n");
                return;
            } else {
                auto_mode_stop();
                (void)udp_send_text("#AUTO,STOPPED,reason=cal_clear\r\n");
            }
        }
        calibration_clear();

    } else if (strcmp(cmd, "CAL_STATUS") == 0) {
        calibration_send_status("STATUS");

    } else if (strcmp(cmd, "PING") == 0) {
        (void)udp_send_text("#PONG\r\n");

    } else if ((strcmp(cmd, "CFG?") == 0) ||
               (strcmp(cmd, "DMA_STATUS") == 0)) {
        fr16_dma_send_status();

    } else if ((strcmp(cmd, "DMA_DEBUG") == 0) ||
               (strcmp(cmd, "DDBG") == 0)) {
        fr16_dma_send_debug();

    } else if ((strcmp(cmd, "DMA_PEEK") == 0) ||
               (strcmp(cmd, "DPEEK") == 0)) {
        fr16_dma_send_peek();
    } else if ((strcmp(cmd, "DMA_BDUMP") == 0) ||
               (strcmp(cmd, "BDUMP") == 0)) {
        fr16_dma_send_bdwords();

    } else if (strcmp(cmd, "FR16_CHECK") == 0) {
        fr16_dma_send_check();

    } else if (strcmp(cmd, "FR16_DUMP") == 0) {
        fr16_dma_send_dump(0U, 1);

    } else if (strncmp(cmd, "FR16_DUMP,", 10U) == 0) {
        char *endp = NULL;
        unsigned long slot = strtoul(cmd + 10, &endp, 0);
        if ((endp == (cmd + 10)) || (*endp != '\0') ||
            (slot >= FR16_RING_DEPTH)) {
            (void)udp_send_text("#ERR,bad_ring_slot\r\n");
        } else {
            fr16_dma_send_dump((u32)slot, 0);
        }

    } else {
        (void)udp_send_text("#ERR,unknown_command\r\n");
    }
}

static u32 read_adc_sample_pair(u32 index)
{
    u32 status;
    u32 timeout;
    write_u32(REG_ADC_SAMPLE_INDEX, index & ADC_SAMPLE_INDEX_MASK);
    for (timeout = 0U; timeout < 1000U; timeout++) {
        status = read_u32(REG_ADC_SAMPLE_INDEX);
        if (((status & ADC_SAMPLE_READY_MASK) != 0U) &&
            ((status & ADC_SAMPLE_INDEX_MASK) ==
             (index & ADC_SAMPLE_INDEX_MASK))) break;
    }
    return read_u32(REG_ADC_SAMPLE_DATA);
}

static err_t send_waveform_frame(u32 frame_id,
                                 u32 adc_a_mVpp,
                                 u32 adc_b_mVpp)
{
    uint8_t pkt[WAVE_PACKET_BYTES];
    u32 chunk_idx;
    u32 total_chunks;
    u32 start;
    u32 count;
    u32 i;
    u32 pair;
    u16 payload_len;
    err_t err;

    total_chunks = (ADC_SAMPLE_COUNT + WAVE_SAMPLES_PER_PKT - 1U) /
                   WAVE_SAMPLES_PER_PKT;

    for (chunk_idx = 0U; chunk_idx < total_chunks; chunk_idx++) {
        start = chunk_idx * WAVE_SAMPLES_PER_PKT;
        count = ADC_SAMPLE_COUNT - start;
        if (count > WAVE_SAMPLES_PER_PKT) count = WAVE_SAMPLES_PER_PKT;
        memset(pkt, 0, sizeof(pkt));

        pkt[0] = 'W'; pkt[1] = 'V'; pkt[2] = '1'; pkt[3] = '6';
        pkt[4] = 1U;
        pkt[5] = WAVE_HEADER_BYTES;
        pkt[6] = 0x03U;
        pkt[7] = 0U;
        put_u32_le(&pkt[8], frame_id);
        put_u16_le(&pkt[12], (u16)chunk_idx);
        put_u16_le(&pkt[14], (u16)total_chunks);
        put_u16_le(&pkt[16], (u16)start);
        put_u16_le(&pkt[18], (u16)count);
        put_u16_le(&pkt[20], (u16)ADC_SAMPLE_COUNT);
        put_u16_le(&pkt[22], 0U);
        put_u32_le(&pkt[24], adc_a_mVpp);
        put_u32_le(&pkt[28], adc_b_mVpp);

        for (i = 0U; i < count; i++) {
            pair = read_adc_sample_pair(start + i);
            put_u16_le(&pkt[WAVE_HEADER_BYTES + i * 4U + 0U],
                       (u16)(pair & 0xFFFFU));
            put_u16_le(&pkt[WAVE_HEADER_BYTES + i * 4U + 2U],
                       (u16)((pair >> 16) & 0xFFFFU));
        }

        payload_len = (u16)(WAVE_HEADER_BYTES + count * 4U);
        err = udp_send_bytes(pkt, payload_len);
        if (err != ERR_OK) {
            xil_printf("wave udp_send failed, frame=%u chunk=%u err=%d\r\n",
                       (unsigned int)frame_id,
                       (unsigned int)chunk_idx,
                       err);
            return err;
        }
    }
    return ERR_OK;
}

void print_app_header(void)
{
    xil_printf("\r\n----- AD9268 host-triggered long capture + UDP WV32 ------\r\n");
    xil_printf("UDP target: %d.%d.%d.%d:%u\r\n",
               PC_IP0, PC_IP1, PC_IP2, PC_IP3, UDP_REMOTE_PORT);
    xil_printf("Command port on board: %u\r\n", UDP_LOCAL_PORT);
    xil_printf("AXI base: 0x%08x\r\n", (unsigned int)LASER_REG_BASE);
}

int start_application(void)
{
    err_t err;
    u32 magic;
    u32 sample_count_reg;

    calibration_init();
    auto_mode_init();
    IP4_ADDR(&g_pc_ipaddr, PC_IP0, PC_IP1, PC_IP2, PC_IP3);

    g_udp_pcb = udp_new();
    if (g_udp_pcb == NULL) {
        xil_printf("udp_new failed\r\n");
        return -1;
    }

    err = udp_bind(g_udp_pcb, IP_ADDR_ANY, UDP_LOCAL_PORT);
    if (err != ERR_OK) {
        xil_printf("udp_bind failed, err=%d\r\n", err);
        udp_remove(g_udp_pcb);
        g_udp_pcb = NULL;
        return -2;
    }

    /* Commands must originate from PC_IP:UDP_REMOTE_PORT. */
    err = udp_connect(g_udp_pcb, &g_pc_ipaddr, UDP_REMOTE_PORT);
    if (err != ERR_OK) {
        xil_printf("udp_connect failed, err=%d\r\n", err);
        udp_remove(g_udp_pcb);
        g_udp_pcb = NULL;
        return -3;
    }

    udp_recv(g_udp_pcb, udp_command_recv, NULL);

    /* M2 startup ordering:
     * 1) application_pre_network_init() has already held the real ADC/packer
     *    before the blocking initial PHY setup.
     * 2) Configure AXI DMA S2MM SG. Per-capture BDs are submitted by CAPTURE.
     * 3) Keep PL held until the Ethernet link has remained up continuously for
     *    M2_LINK_STABLE_MS. m2_startup_capture_poll() performs the release.
     */
#if HAVE_FR16_AXI_DMA
    if (!g_startup_capture_hold) {
        application_pre_network_init();
    }
    delay_ms_blocking(5U);
    if (fr16_dma_init() == XST_SUCCESS) {
        g_startup_dma_ready = 1;
        xil_printf("M2 startup: DMA SG ready; capture remains held for stable Ethernet link\r\n");
    } else {
        xil_printf("M2 startup: DMA init failed; PL remains held in reset\r\n");
    }
#else
    g_startup_capture_hold = 0;
    pl_reset_release_hold();
    (void)fr16_dma_init();
#endif

    magic = read_u32(REG_MAGIC);
    sample_count_reg = read_u32(REG_SAMPLE_COUNT);
    xil_printf("UDP application started\r\n");
    xil_printf("local_port=%u, remote=%d.%d.%d.%d:%u\r\n",
               UDP_LOCAL_PORT, PC_IP0, PC_IP1, PC_IP2, PC_IP3,
               UDP_REMOTE_PORT);
    xil_printf("magic=0x%08x\r\n", (unsigned int)magic);
    xil_printf("SAMPLE_COUNT_REG=%u\r\n", (unsigned int)sample_count_reg);
    xil_printf("ADC waveform: %u samples/ch, %u samples/UDP packet\r\n",
               (unsigned int)ADC_SAMPLE_COUNT,
               (unsigned int)WAVE_SAMPLES_PER_PKT);
    xil_printf("Sensor timeline: capacity=%u, record_bytes=%u, records/UDP packet=%u\r\n",
               (unsigned int)FR16_SENSOR_TIMELINE_CAPACITY,
               (unsigned int)FR16_SENSOR_TIMELINE_ENTRY_BYTES,
               (unsigned int)LS32_RECORDS_PER_PKT);
    xil_printf("Capture command: CAPTURE or CAP_START\r\n");
    xil_printf("Auto mode: AUTO_START[,rpm[,thr_um[,points]]] / AUTO_STOP / AUTO_CFG / AUTO_STATUS\r\n");
    xil_printf("PL reset control: PLRST,1 / PLRST,0, watchdog=%u ms\r\n",
               (unsigned int)PL_RESET_KEEPALIVE_MS);
    xil_printf("Calibration frames: discard=%u collect=%u verify=%u\r\n",
               (unsigned int)CAL_DISCARD_FRAMES,
               (unsigned int)CAL_COLLECT_FRAMES,
               (unsigned int)CAL_VERIFY_FRAMES);

    if (magic != EXPECTED_MAGIC) {
        xil_printf("WARNING: magic mismatch. Check bitstream/AXI map.\r\n");
    }

    g_udp_ready = 1;
    (void)udp_send_text(
        "frame_id,adc_a_raw_pp,adc_b_raw_pp,adc_a_filt_pp,adc_b_filt_pp,"
        "adc_a_mVpp,adc_b_mVpp,l1_um,l2_um,l3_um,l4_um,l5_um,temp_x10,"
        "status,missed_total,cal_state,cal_valid,gain_a_ppm,gain_b_ppm,"
        "adc_a_corr_uVpp,adc_b_corr_uVpp,me_2x_uV,me_norm_ppm,"
        "cal_zero_residual_uV,ls_count,ls_overflow\r\n");
    calibration_send_status("BOOT");
    return 0;
}

int transfer_data(void)
{
    u32 id_before;
    u32 id_after;
    u32 status;
    u32 adc_a_raw_pp;
    u32 adc_b_raw_pp;
    u32 adc_a_filt_pp;
    u32 adc_b_filt_pp;
    u32 adc_a_mVpp;
    u32 adc_b_mVpp;
    int32_t l1;
    int32_t l2;
    int32_t l3;
    int32_t l4;
    int32_t l5;
    int32_t temp;
    double a_corr_code;
    double b_corr_code;
    double me_2x_code;
    double sum_corr_code;
    s32 adc_a_corr_uVpp;
    s32 adc_b_corr_uVpp;
    s32 me_2x_uV;
    s32 me_norm_ppm;
    char line[512];
    int n;
    err_t err;

    if (!g_udp_ready) return 0;

    m2_startup_capture_poll();
    if (g_startup_capture_hold) {
        return 0;
    }

    pl_reset_poll_watchdog();
    if (g_pl_reset_active) {
        return 0;
    }

#if HAVE_FR16_AXI_DMA
    if (g_fr16_dma_ready) {
        auto_mode_poll();
        fr16_dma_poll();
        return 0;
    }
#endif

    id_before = read_u32(REG_FRAME_ID);
    if (id_before == g_last_frame_id) return 0;

    do {
        id_before = read_u32(REG_FRAME_ID);
        adc_a_raw_pp = read_u32(REG_ADC_A_RAW_PP);
        adc_b_raw_pp = read_u32(REG_ADC_B_RAW_PP);
        adc_a_filt_pp = read_u32(REG_ADC_A_FILT_PP);
        adc_b_filt_pp = read_u32(REG_ADC_B_FILT_PP);
        l1 = read_s32(REG_LASER1_UM);
        l2 = read_s32(REG_LASER2_UM);
        l3 = read_s32(REG_LASER3_UM);
        l4 = read_s32(REG_LASER4_UM);
        l5 = read_s32(REG_LASER5_UM);
        temp = read_s32(REG_TEMP_X10);
        status = read_u32(REG_STATUS);
        id_after = read_u32(REG_FRAME_ID);
    } while (id_before != id_after);

    if (g_last_frame_id != 0xFFFFFFFFU) {
        u32 delta = id_before - g_last_frame_id;
        if (delta > 1U) g_missed_total += delta - 1U;
    }
    g_last_frame_id = id_before;

    adc_a_mVpp = adc_code_to_mVpp(adc_a_filt_pp);
    adc_b_mVpp = adc_code_to_mVpp(adc_b_filt_pp);
    calibration_on_sample(adc_a_filt_pp, adc_b_filt_pp);

    if (g_cal.valid) {
        a_corr_code = g_cal.gain_a * (double)adc_a_filt_pp;
        b_corr_code = g_cal.gain_b * (double)adc_b_filt_pp;
        adc_a_corr_uVpp = adc_code_double_to_uVpp(a_corr_code);
        adc_b_corr_uVpp = adc_code_double_to_uVpp(b_corr_code);
        me_2x_code = b_corr_code - a_corr_code;
        me_2x_uV = adc_code_double_to_uVpp(me_2x_code);
        sum_corr_code = b_corr_code + a_corr_code;
        me_norm_ppm = (sum_corr_code != 0.0) ?
            round_double_to_s32(me_2x_code / sum_corr_code * 1000000.0) : 0;
    } else {
        adc_a_corr_uVpp = 0;
        adc_b_corr_uVpp = 0;
        me_2x_uV = 0;
        me_norm_ppm = 0;
    }

    g_output_divider++;
    if (g_output_divider >= OUTPUT_EVERY_N_FRAMES) {
        g_output_divider = 0U;
        n = snprintf(line, sizeof(line),
            "%u,%u,%u,%u,%u,%u,%u,%d,%d,%d,%d,%d,%d,0x%08x,%u,"
            "%u,%d,%ld,%ld,%ld,%ld,%ld,%ld,%ld,%u,%u\r\n",
            (unsigned int)id_before,
            (unsigned int)adc_a_raw_pp,
            (unsigned int)adc_b_raw_pp,
            (unsigned int)adc_a_filt_pp,
            (unsigned int)adc_b_filt_pp,
            (unsigned int)adc_a_mVpp,
            (unsigned int)adc_b_mVpp,
            (int)l1, (int)l2, (int)l3, (int)l4, (int)l5, (int)temp,
            (unsigned int)status,
            (unsigned int)g_missed_total,
            (unsigned int)g_cal.state,
            g_cal.valid,
            (long)gain_to_ppm(g_cal.gain_a),
            (long)gain_to_ppm(g_cal.gain_b),
            (long)adc_a_corr_uVpp,
            (long)adc_b_corr_uVpp,
            (long)me_2x_uV,
            (long)me_norm_ppm,
            (long)g_cal.verify_mean_uV,
            0U,
            0U);

        if ((n <= 0) || (n >= (int)sizeof(line))) {
            xil_printf("CSV line buffer too small\r\n");
            return -1;
        }
        err = udp_send_text(line);
        if (err != ERR_OK) {
            xil_printf("summary udp_send failed, err=%d\r\n", err);
        }
    }

#if SEND_WAVEFORM_ENABLE
    g_wave_divider++;
    if (g_wave_divider >= SEND_WAVEFORM_EVERY_N_FRAMES) {
        g_wave_divider = 0U;
        err = send_waveform_frame(id_before, adc_a_mVpp, adc_b_mVpp);
        if (err != ERR_OK) return -2;
    }
#endif

    return 0;
}
