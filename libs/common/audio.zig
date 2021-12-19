const std = @import("std");
const win32 = @import("win32");
const w = win32.base;
const xaudio2 = win32.xaudio2;
const mf = win32.mf;
const wasapi = win32.wasapi;
const assert = std.debug.assert;
const lib = @import("library.zig");
const tracy = @import("tracy.zig");
const hrPanic = lib.hrPanic;
const hrPanicOnFail = lib.hrPanicOnFail;
const L = std.unicode.utf8ToUtf16LeStringLiteral;

const enable_dx_debug = @import("build_options").enable_dx_debug;

pub const AudioContext = struct {
    device: *xaudio2.IXAudio2,
    master_voice: *xaudio2.IMasteringVoice,

    pub fn init() AudioContext {
        const device = blk: {
            var device: ?*xaudio2.IXAudio2 = null;
            hrPanicOnFail(xaudio2.create(&device, if (enable_dx_debug) xaudio2.DEBUG_ENGINE else 0, 0));
            break :blk device.?;
        };

        if (enable_dx_debug) {
            device.SetDebugConfiguration(&.{
                .TraceMask = xaudio2.LOG_ERRORS | xaudio2.LOG_WARNINGS | xaudio2.LOG_INFO,
                .BreakMask = 0,
                .LogThreadID = w.TRUE,
                .LogFileline = w.FALSE,
                .LogFunctionName = w.FALSE,
                .LogTiming = w.FALSE,
            }, null);
        }

        const master_voice = blk: {
            var voice: ?*xaudio2.IMasteringVoice = null;
            hrPanicOnFail(device.CreateMasteringVoice(
                &voice,
                xaudio2.DEFAULT_CHANNELS,
                xaudio2.DEFAULT_SAMPLERATE,
                0,
                null,
                null,
                .GameEffects,
            ));
            break :blk voice.?;
        };

        return .{
            .device = device,
            .master_voice = master_voice,
        };
    }

    pub fn deinit(audio: *AudioContext) void {
        audio.device.StopEngine();
        audio.master_voice.DestroyVoice();
        _ = audio.device.Release();
        audio.* = undefined;
    }
};

pub const Stream = struct {
    critical_section: w.CRITICAL_SECTION,
    allocator: std.mem.Allocator,
    voice: *xaudio2.ISourceVoice,
    voice_cb: *VoiceCallback,
    reader: *mf.ISourceReader,
    reader_cb: *SourceReaderCallback,

    pub fn create(allocator: std.mem.Allocator, device: *xaudio2.IXAudio2, file_path: [:0]const u16) *Stream {
        const voice_cb = blk: {
            var cb = allocator.create(VoiceCallback) catch unreachable;
            cb.* = VoiceCallback.init();
            break :blk cb;
        };

        var cs: w.CRITICAL_SECTION = undefined;
        w.kernel32.InitializeCriticalSection(&cs);

        const source_reader_cb = blk: {
            var cb = allocator.create(SourceReaderCallback) catch unreachable;
            cb.* = SourceReaderCallback.init(allocator);
            break :blk cb;
        };

        var sample_rate: u32 = 0;
        const source_reader = blk: {
            var attribs: *mf.IAttributes = undefined;
            hrPanicOnFail(mf.MFCreateAttributes(&attribs, 1));
            defer _ = attribs.Release();

            hrPanicOnFail(attribs.SetUnknown(
                &mf.SOURCE_READER_ASYNC_CALLBACK,
                @ptrCast(*w.IUnknown, source_reader_cb),
            ));

            var source_reader: *mf.ISourceReader = undefined;
            hrPanicOnFail(mf.MFCreateSourceReaderFromURL(file_path, attribs, &source_reader));

            var media_type: *mf.IMediaType = undefined;
            hrPanicOnFail(source_reader.GetNativeMediaType(mf.SOURCE_READER_FIRST_AUDIO_STREAM, 0, &media_type));
            defer _ = media_type.Release();

            hrPanicOnFail(media_type.GetUINT32(&mf.MT_AUDIO_SAMPLES_PER_SECOND, &sample_rate));

            hrPanicOnFail(media_type.SetGUID(&mf.MT_MAJOR_TYPE, &mf.MediaType_Audio));
            hrPanicOnFail(media_type.SetGUID(&mf.MT_SUBTYPE, &mf.AudioFormat_PCM));
            hrPanicOnFail(media_type.SetUINT32(&mf.MT_AUDIO_NUM_CHANNELS, 2));
            hrPanicOnFail(media_type.SetUINT32(&mf.MT_AUDIO_SAMPLES_PER_SECOND, sample_rate));
            hrPanicOnFail(media_type.SetUINT32(&mf.MT_AUDIO_BITS_PER_SAMPLE, 16));
            hrPanicOnFail(media_type.SetUINT32(&mf.MT_AUDIO_BLOCK_ALIGNMENT, 4));
            hrPanicOnFail(media_type.SetUINT32(&mf.MT_AUDIO_AVG_BYTES_PER_SECOND, 4 * sample_rate));
            hrPanicOnFail(media_type.SetUINT32(&mf.MT_ALL_SAMPLES_INDEPENDENT, w.TRUE));
            hrPanicOnFail(source_reader.SetCurrentMediaType(mf.SOURCE_READER_FIRST_AUDIO_STREAM, null, media_type));

            break :blk source_reader;
        };
        assert(sample_rate != 0);

        const voice = blk: {
            var voice: ?*xaudio2.ISourceVoice = null;
            hrPanicOnFail(device.CreateSourceVoice(&voice, &.{
                .wFormatTag = wasapi.WAVE_FORMAT_PCM,
                .nChannels = 2,
                .nSamplesPerSec = sample_rate,
                .nAvgBytesPerSec = 4 * sample_rate,
                .nBlockAlign = 4,
                .wBitsPerSample = 16,
                .cbSize = @sizeOf(wasapi.WAVEFORMATEX),
            }, 0, xaudio2.DEFAULT_FREQ_RATIO, @ptrCast(*xaudio2.IVoiceCallback, voice_cb), null, null));
            break :blk voice.?;
        };

        var stream = allocator.create(Stream) catch unreachable;
        stream.* = .{
            .critical_section = cs,
            .allocator = allocator,
            .voice = voice,
            .voice_cb = voice_cb,
            .reader = source_reader,
            .reader_cb = source_reader_cb,
        };

        voice_cb.stream = stream;
        source_reader_cb.stream = stream;

        hrPanicOnFail(source_reader.ReadSample(mf.SOURCE_READER_FIRST_AUDIO_STREAM, 0, null, null, null, null));
        hrPanicOnFail(source_reader.ReadSample(mf.SOURCE_READER_FIRST_AUDIO_STREAM, 0, null, null, null, null));
        hrPanicOnFail(source_reader.ReadSample(mf.SOURCE_READER_FIRST_AUDIO_STREAM, 0, null, null, null, null));

        return stream;
    }

    pub fn destroy(stream: *Stream) void {
        {
            const refcount = stream.reader.Release();
            assert(refcount == 0);
        }
        {
            const refcount = stream.reader_cb.Release();
            assert(refcount == 0);
        }
        w.kernel32.DeleteCriticalSection(&stream.critical_section);
        stream.voice.DestroyVoice();
        stream.allocator.destroy(stream.voice_cb);
        stream.allocator.destroy(stream);
    }

    fn onBufferEnd(stream: *Stream, buffer: *mf.IMediaBuffer) void {
        w.kernel32.EnterCriticalSection(&stream.critical_section);
        defer w.kernel32.LeaveCriticalSection(&stream.critical_section);

        hrPanicOnFail(buffer.Unlock());
        const refcount = buffer.Release();
        assert(refcount == 0);

        // Request new audio buffer
        hrPanicOnFail(stream.reader.ReadSample(mf.SOURCE_READER_FIRST_AUDIO_STREAM, 0, null, null, null, null));
    }

    fn onReadSample(
        stream: *Stream,
        status: w.HRESULT,
        _: w.DWORD,
        stream_flags: w.DWORD,
        _: w.LONGLONG,
        sample: ?*mf.ISample,
    ) void {
        w.kernel32.EnterCriticalSection(&stream.critical_section);
        defer w.kernel32.LeaveCriticalSection(&stream.critical_section);

        if ((stream_flags & mf.SOURCE_READERF_ENDOFSTREAM) != 0) {
            const pos = w.PROPVARIANT{ .vt = w.VT_I8, .u = .{ .hVal = 0 } };
            hrPanicOnFail(stream.reader.SetCurrentPosition(&w.GUID_NULL, &pos));
            hrPanicOnFail(stream.reader.ReadSample(
                mf.SOURCE_READER_FIRST_AUDIO_STREAM,
                0,
                null,
                null,
                null,
                null,
            ));
            return;
        }
        if (status != w.S_OK or sample == null) {
            return;
        }

        var buffer: *mf.IMediaBuffer = undefined;
        hrPanicOnFail(sample.?.ConvertToContiguousBuffer(&buffer));

        var data_ptr: [*]u8 = undefined;
        var data_len: u32 = 0;
        hrPanicOnFail(buffer.Lock(&data_ptr, null, &data_len));

        // Submit decoded buffer
        hrPanicOnFail(stream.voice.SubmitSourceBuffer(&.{
            .Flags = 0,
            .AudioBytes = data_len,
            .pAudioData = data_ptr,
            .PlayBegin = 0,
            .PlayLength = 0,
            .LoopBegin = 0,
            .LoopLength = 0,
            .LoopCount = 0,
            .pContext = buffer, // Store pointer to the buffer so that we can release it in onBufferEnd()
        }, null));
    }

    const VoiceCallback = struct {
        vtable: *const xaudio2.IVoiceCallbackVTable(VoiceCallback) = &vtable_voice_cb,
        stream: ?*Stream,

        fn init() VoiceCallback {
            return .{ .stream = null };
        }

        fn OnBufferEnd(voice_cb: *VoiceCallback, context: ?*anyopaque) callconv(w.WINAPI) void {
            voice_cb.stream.?.onBufferEnd(@ptrCast(*mf.IMediaBuffer, @alignCast(8, context)));
        }

        const vtable_voice_cb = xaudio2.IVoiceCallbackVTable(VoiceCallback){
            .vcb = .{
                .OnVoiceProcessingPassStart = VoiceCallback.OnVoiceProcessingPassStart,
                .OnVoiceProcessingPassEnd = OnVoiceProcessingPassEnd,
                .OnStreamEnd = VoiceCallback.OnStreamEnd,
                .OnBufferStart = VoiceCallback.OnBufferStart,
                .OnBufferEnd = VoiceCallback.OnBufferEnd,
                .OnLoopEnd = VoiceCallback.OnLoopEnd,
                .OnVoiceError = VoiceCallback.OnVoiceError,
            },
        };

        fn OnVoiceProcessingPassStart(_: *VoiceCallback, _: w.UINT32) callconv(w.WINAPI) void {}
        fn OnVoiceProcessingPassEnd(_: *VoiceCallback) callconv(w.WINAPI) void {}
        fn OnStreamEnd(_: *VoiceCallback) callconv(w.WINAPI) void {}
        fn OnBufferStart(_: *VoiceCallback, _: ?*anyopaque) callconv(w.WINAPI) void {}
        fn OnLoopEnd(_: *VoiceCallback, _: ?*anyopaque) callconv(w.WINAPI) void {}
        fn OnVoiceError(_: *VoiceCallback, _: ?*anyopaque, _: w.HRESULT) callconv(w.WINAPI) void {}
    };

    const SourceReaderCallback = struct {
        vtable: *const mf.ISourceReaderCallbackVTable(SourceReaderCallback) = &vtable_source_reader_cb,
        refcount: u32 = 1,
        allocator: std.mem.Allocator,
        stream: ?*Stream,

        fn init(allocator: std.mem.Allocator) SourceReaderCallback {
            return .{
                .allocator = allocator,
                .stream = null,
            };
        }

        const vtable_source_reader_cb = mf.ISourceReaderCallbackVTable(SourceReaderCallback){
            .unknown = .{
                .QueryInterface = SourceReaderCallback.QueryInterface,
                .AddRef = SourceReaderCallback.AddRef,
                .Release = SourceReaderCallback.Release,
            },
            .cb = .{
                .OnReadSample = SourceReaderCallback.OnReadSample,
                .OnFlush = SourceReaderCallback.OnFlush,
                .OnEvent = SourceReaderCallback.OnEvent,
            },
        };

        fn QueryInterface(
            source_reader_cb: *SourceReaderCallback,
            guid: *const w.GUID,
            outobj: ?*?*anyopaque,
        ) callconv(w.WINAPI) w.HRESULT {
            assert(outobj != null);

            if (std.mem.eql(u8, std.mem.asBytes(guid), std.mem.asBytes(&w.IID_IUnknown))) {
                outobj.?.* = source_reader_cb;
                _ = source_reader_cb.AddRef();
                return w.S_OK;
            } else if (std.mem.eql(u8, std.mem.asBytes(guid), std.mem.asBytes(&mf.IID_ISourceReaderCallback))) {
                outobj.?.* = source_reader_cb;
                _ = source_reader_cb.AddRef();
                return w.S_OK;
            }

            outobj.?.* = null;
            return w.E_NOINTERFACE;
        }

        fn AddRef(source_reader_cb: *SourceReaderCallback) callconv(w.WINAPI) w.ULONG {
            const prev_refcount = @atomicRmw(u32, &source_reader_cb.refcount, .Add, 1, .Monotonic);
            return prev_refcount + 1;
        }

        fn Release(source_reader_cb: *SourceReaderCallback) callconv(w.WINAPI) w.ULONG {
            const prev_refcount = @atomicRmw(u32, &source_reader_cb.refcount, .Sub, 1, .Monotonic);
            assert(prev_refcount > 0);
            if (prev_refcount == 1) {
                source_reader_cb.allocator.destroy(source_reader_cb);
            }
            return prev_refcount - 1;
        }

        fn OnReadSample(
            source_reader_cb: *SourceReaderCallback,
            status: w.HRESULT,
            stream_index: w.DWORD,
            stream_flags: w.DWORD,
            timestamp: w.LONGLONG,
            sample: ?*mf.ISample,
        ) callconv(w.WINAPI) w.HRESULT {
            source_reader_cb.stream.?.onReadSample(status, stream_index, stream_flags, timestamp, sample);
            return w.S_OK;
        }

        fn OnFlush(_: *SourceReaderCallback, _: w.DWORD) callconv(w.WINAPI) w.HRESULT {
            return w.S_OK;
        }

        fn OnEvent(_: *SourceReaderCallback, _: w.DWORD, _: *mf.IMediaEvent) callconv(w.WINAPI) w.HRESULT {
            return w.S_OK;
        }
    };
};

pub fn loadSamples(allocator: std.mem.Allocator, audio_file_path: [:0]const u16) std.ArrayList(u8) {
    const tracy_zone = tracy.zone(@src(), 1);
    defer tracy_zone.end();

    var source_reader: *mf.ISourceReader = undefined;
    hrPanicOnFail(mf.MFCreateSourceReaderFromURL(audio_file_path, null, &source_reader));
    defer _ = source_reader.Release();

    var media_type: *mf.IMediaType = undefined;
    hrPanicOnFail(source_reader.GetNativeMediaType(mf.SOURCE_READER_FIRST_AUDIO_STREAM, 0, &media_type));
    defer _ = media_type.Release();

    const sample_rate = 48_000;
    hrPanicOnFail(media_type.SetGUID(&mf.MT_MAJOR_TYPE, &mf.MediaType_Audio));
    hrPanicOnFail(media_type.SetGUID(&mf.MT_SUBTYPE, &mf.AudioFormat_PCM));
    hrPanicOnFail(media_type.SetUINT32(&mf.MT_AUDIO_NUM_CHANNELS, 1));
    hrPanicOnFail(media_type.SetUINT32(&mf.MT_AUDIO_SAMPLES_PER_SECOND, sample_rate));
    hrPanicOnFail(media_type.SetUINT32(&mf.MT_AUDIO_BITS_PER_SAMPLE, 16));
    hrPanicOnFail(media_type.SetUINT32(&mf.MT_AUDIO_BLOCK_ALIGNMENT, 2));
    hrPanicOnFail(media_type.SetUINT32(&mf.MT_AUDIO_AVG_BYTES_PER_SECOND, 2 * sample_rate));
    hrPanicOnFail(media_type.SetUINT32(&mf.MT_ALL_SAMPLES_INDEPENDENT, w.TRUE));
    hrPanicOnFail(source_reader.SetCurrentMediaType(mf.SOURCE_READER_FIRST_AUDIO_STREAM, null, media_type));

    var samples = std.ArrayList(u8).init(allocator);
    while (true) {
        var flags: w.DWORD = 0;
        var sample: ?*mf.ISample = null;
        defer {
            if (sample) |s| _ = s.Release();
        }
        hrPanicOnFail(source_reader.ReadSample(mf.SOURCE_READER_FIRST_AUDIO_STREAM, 0, null, &flags, null, &sample));
        if ((flags & mf.SOURCE_READERF_ENDOFSTREAM) != 0) {
            break;
        }

        var buffer: *mf.IMediaBuffer = undefined;
        hrPanicOnFail(sample.?.ConvertToContiguousBuffer(&buffer));
        defer _ = buffer.Release();

        var data_ptr: [*]u8 = undefined;
        var data_len: u32 = 0;
        hrPanicOnFail(buffer.Lock(&data_ptr, null, &data_len));
        samples.appendSlice(data_ptr[0..data_len]) catch unreachable;
        hrPanicOnFail(buffer.Unlock());
    }
    return samples;
}