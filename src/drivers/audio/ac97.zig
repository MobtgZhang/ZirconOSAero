//! AC’97 audio miniport (NT6: portcls + AC97 miniport stack, IOCTL surface)
//! Intel-compatible NAM/NABM programming: PCM, mixer, reset.
//! Registers `\\Driver\\AC97` / `\\Device\\Audio0`. See Intel AC’97 spec Rev 2.3.

const builtin = @import("builtin");
const io = @import("../../io/io.zig");
const klog = @import("../../rtl/klog.zig");
const portio = if (builtin.target.cpu.arch == .x86_64)
    @import("../../hal/x86_64/portio.zig")
else
    struct {
        pub fn outb(_: u16, _: u8) void {}
        pub fn outw(_: u16, _: u16) void {}
        pub fn outl(_: u16, _: u32) void {}
        pub fn inb(_: u16) u8 { return 0; }
        pub fn inw(_: u16) u16 { return 0; }
        pub fn inl(_: u16) u32 { return 0; }
        pub fn ioWait() void {}
    };

pub const AC97_VENDOR_ID: u16 = 0x8086;
pub const AC97_DEVICE_ID: u16 = 0x2415;

pub const AC97_NAM_RESET: u16 = 0x00;
pub const AC97_NAM_MASTER_VOL: u16 = 0x02;
pub const AC97_NAM_AUX_OUT_VOL: u16 = 0x04;
pub const AC97_NAM_MONO_VOL: u16 = 0x06;
pub const AC97_NAM_MASTER_TONE: u16 = 0x08;
pub const AC97_NAM_PC_BEEP: u16 = 0x0A;
pub const AC97_NAM_PHONE_VOL: u16 = 0x0C;
pub const AC97_NAM_MIC_VOL: u16 = 0x0E;
pub const AC97_NAM_LINE_IN_VOL: u16 = 0x10;
pub const AC97_NAM_CD_VOL: u16 = 0x12;
pub const AC97_NAM_VIDEO_VOL: u16 = 0x14;
pub const AC97_NAM_AUX_IN_VOL: u16 = 0x16;
pub const AC97_NAM_PCM_OUT_VOL: u16 = 0x18;
pub const AC97_NAM_RECORD_SEL: u16 = 0x1A;
pub const AC97_NAM_RECORD_GAIN: u16 = 0x1C;
pub const AC97_NAM_GP: u16 = 0x20;
pub const AC97_NAM_POWERDOWN: u16 = 0x26;
pub const AC97_NAM_EXT_AUDIO_ID: u16 = 0x28;
pub const AC97_NAM_EXT_AUDIO_CTRL: u16 = 0x2A;
pub const AC97_NAM_SAMPLE_RATE: u16 = 0x2C;
pub const AC97_NAM_VENDOR_ID1: u16 = 0x7C;
pub const AC97_NAM_VENDOR_ID2: u16 = 0x7E;

pub const AC97_NABM_PCM_OUT_BDBAR: u16 = 0x10;
pub const AC97_NABM_PCM_OUT_CIV: u16 = 0x14;
pub const AC97_NABM_PCM_OUT_LVI: u16 = 0x15;
pub const AC97_NABM_PCM_OUT_SR: u16 = 0x16;
pub const AC97_NABM_PCM_OUT_CR: u16 = 0x1B;
pub const AC97_NABM_GLOBAL_CR: u16 = 0x2C;
pub const AC97_NABM_GLOBAL_SR: u16 = 0x30;

pub const SampleRate = enum(u32) {
    rate_8000 = 8000,
    rate_11025 = 11025,
    rate_16000 = 16000,
    rate_22050 = 22050,
    rate_44100 = 44100,
    rate_48000 = 48000,
};

pub const SampleFormat = enum(u8) {
    pcm_8bit_mono = 0,
    pcm_8bit_stereo = 1,
    pcm_16bit_mono = 2,
    pcm_16bit_stereo = 3,
};

pub const BufferDescriptor = struct {
    address: u32 = 0,
    length: u16 = 0,
    flags: u16 = 0,
};

const MAX_BUFFER_DESCRIPTORS: usize = 32;

pub const AC97State = struct {
    nam_base: u16 = 0,
    nabm_base: u16 = 0,
    initialized: bool = false,
    playing: bool = false,
    sample_rate: u32 = 48000,
    format: SampleFormat = .pcm_16bit_stereo,
    master_volume: u8 = 80,
    pcm_volume: u8 = 80,
    muted: bool = false,
    vra_supported: bool = false,
    vendor_id: u32 = 0,
};

var state: AC97State = .{};
var buffer_descriptors: [MAX_BUFFER_DESCRIPTORS]BufferDescriptor = [_]BufferDescriptor{.{}} ** MAX_BUFFER_DESCRIPTORS;
var descriptor_count: usize = 0;

var driver_idx: u32 = 0;
var device_idx: u32 = 0;

pub const IOCTL_AC97_GET_STATE: u32 = 0x000C0000;
pub const IOCTL_AC97_SET_VOLUME: u32 = 0x000C0004;
pub const IOCTL_AC97_SET_SAMPLE_RATE: u32 = 0x000C0008;
pub const IOCTL_AC97_START_PLAYBACK: u32 = 0x000C000C;
pub const IOCTL_AC97_STOP_PLAYBACK: u32 = 0x000C0010;
pub const IOCTL_AC97_SET_MUTE: u32 = 0x000C0014;
pub const IOCTL_AC97_RESET: u32 = 0x000C0018;

fn namRead(reg: u16) u16 {
    if (state.nam_base == 0) return 0;
    return portio.inw(state.nam_base + reg);
}

fn namWrite(reg: u16, value: u16) void {
    if (state.nam_base == 0) return;
    portio.outw(state.nam_base + reg, value);
}

fn nabmRead8(reg: u16) u8 {
    if (state.nabm_base == 0) return 0;
    return portio.inb(state.nabm_base + reg);
}

fn nabmWrite8(reg: u16, value: u8) void {
    if (state.nabm_base == 0) return;
    portio.outb(state.nabm_base + reg, value);
}

fn volumeToReg(vol: u8) u16 {
    if (vol == 0) return 0x8000;
    const atten: u16 = @intCast(63 - @min(@as(u16, vol) * 63 / 100, 63));
    return (atten << 8) | atten;
}

pub fn setMasterVolume(vol: u8) void {
    state.master_volume = @min(vol, 100);
    if (!state.muted) {
        namWrite(AC97_NAM_MASTER_VOL, volumeToReg(state.master_volume));
    }
}

pub fn setPcmVolume(vol: u8) void {
    state.pcm_volume = @min(vol, 100);
    if (!state.muted) {
        namWrite(AC97_NAM_PCM_OUT_VOL, volumeToReg(state.pcm_volume));
    }
}

pub fn setMute(muted: bool) void {
    state.muted = muted;
    if (muted) {
        namWrite(AC97_NAM_MASTER_VOL, 0x8000);
        namWrite(AC97_NAM_PCM_OUT_VOL, 0x8000);
    } else {
        namWrite(AC97_NAM_MASTER_VOL, volumeToReg(state.master_volume));
        namWrite(AC97_NAM_PCM_OUT_VOL, volumeToReg(state.pcm_volume));
    }
}

pub fn setSampleRate(rate: u32) bool {
    if (!state.vra_supported) {
        return rate == 48000;
    }
    const clamped: u16 = @intCast(@min(@max(rate, 8000), 48000));
    namWrite(AC97_NAM_SAMPLE_RATE, clamped);
    portio.ioWait();
    const actual = namRead(AC97_NAM_SAMPLE_RATE);
    state.sample_rate = actual;
    return actual == clamped;
}

pub fn startPlayback() void {
    nabmWrite8(AC97_NABM_PCM_OUT_CR, 0x01);
    state.playing = true;
}

pub fn stopPlayback() void {
    nabmWrite8(AC97_NABM_PCM_OUT_CR, 0x00);
    state.playing = false;
}

pub fn resetController() void {
    nabmWrite8(AC97_NABM_GLOBAL_CR, 0x02);
    portio.ioWait();
    portio.ioWait();
    nabmWrite8(AC97_NABM_GLOBAL_CR, 0x00);
    portio.ioWait();

    namWrite(AC97_NAM_RESET, 0);
    portio.ioWait();
}

pub fn isPlaying() bool {
    return state.playing;
}

pub fn getMasterVolume() u8 {
    return state.master_volume;
}

pub fn getPcmVolume() u8 {
    return state.pcm_volume;
}

pub fn isMuted() bool {
    return state.muted;
}

pub fn getSampleRate() u32 {
    return state.sample_rate;
}

pub fn isInitialized() bool {
    return state.initialized;
}

fn ac97Dispatch(irp: *io.Irp) io.IoStatus {
    switch (irp.major_function) {
        .create, .close => {
            irp.complete(.success, 0);
            return .success;
        },
        .ioctl => return handleIoctl(irp),
        else => {
            irp.complete(.not_implemented, 0);
            return .not_implemented;
        },
    }
}

fn handleIoctl(irp: *io.Irp) io.IoStatus {
    switch (irp.ioctl_code) {
        IOCTL_AC97_GET_STATE => {
            irp.buffer_ptr = @as(u64, state.sample_rate);
            irp.bytes_transferred = state.master_volume;
            irp.complete(.success, if (state.playing) @as(usize, 1) else 0);
            return .success;
        },
        IOCTL_AC97_SET_VOLUME => {
            const vol: u8 = @truncate(irp.buffer_ptr & 0xFF);
            setMasterVolume(vol);
            setPcmVolume(vol);
            irp.complete(.success, 0);
            return .success;
        },
        IOCTL_AC97_SET_SAMPLE_RATE => {
            const rate: u32 = @truncate(irp.buffer_ptr & 0xFFFFFFFF);
            const ok = setSampleRate(rate);
            irp.complete(if (ok) .success else .not_implemented, 0);
            return .success;
        },
        IOCTL_AC97_START_PLAYBACK => {
            startPlayback();
            irp.complete(.success, 0);
            return .success;
        },
        IOCTL_AC97_STOP_PLAYBACK => {
            stopPlayback();
            irp.complete(.success, 0);
            return .success;
        },
        IOCTL_AC97_SET_MUTE => {
            setMute(irp.buffer_ptr != 0);
            irp.complete(.success, 0);
            return .success;
        },
        IOCTL_AC97_RESET => {
            resetController();
            irp.complete(.success, 0);
            return .success;
        },
        else => {
            irp.complete(.not_implemented, 0);
            return .not_implemented;
        },
    }
}

pub fn probeHardware(nam_base: u16, nabm_base: u16) bool {
    state.nam_base = nam_base;
    state.nabm_base = nabm_base;

    resetController();

    const vid1 = namRead(AC97_NAM_VENDOR_ID1);
    const vid2 = namRead(AC97_NAM_VENDOR_ID2);
    state.vendor_id = (@as(u32, vid1) << 16) | vid2;

    if (vid1 == 0xFFFF and vid2 == 0xFFFF) return false;

    const ext_id = namRead(AC97_NAM_EXT_AUDIO_ID);
    state.vra_supported = (ext_id & 0x0001) != 0;

    if (state.vra_supported) {
        const ext_ctrl = namRead(AC97_NAM_EXT_AUDIO_CTRL);
        namWrite(AC97_NAM_EXT_AUDIO_CTRL, ext_ctrl | 0x0001);
    }

    setMasterVolume(80);
    setPcmVolume(80);

    state.sample_rate = 48000;

    return true;
}

pub fn init() void {
    const probed = probeHardware(0, 0);

    driver_idx = io.registerDriver("\\Driver\\AC97", ac97Dispatch) orelse {
        klog.err("AC97: Failed to register driver", .{});
        return;
    };

    device_idx = io.createDevice("\\Device\\Audio0", .audio, driver_idx) orelse {
        klog.err("AC97: Failed to create device", .{});
        return;
    };

    state.initialized = true;

    if (probed and state.vendor_id != 0) {
        klog.info("AC97 Driver: Hardware detected (vendor=0x%x, VRA=%s)", .{
            state.vendor_id,
            if (state.vra_supported) "yes" else "no",
        });
    } else {
        klog.info("AC97 Driver: initialized (no hardware detected, virtual mode)", .{});
    }
}
