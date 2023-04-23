//
//  HHVideoDecoder.m
//  HHVideoPlayer-OC
//
//  Created by 尹东博 on 2023/4/19.
//

#import "HHVideoDecoder.h"
#import <Accelerate/Accelerate.h>

#include "libavformat/avformat.h"
#include "libswscale/swscale.h"
#include "libswresample/swresample.h"
#include "libavutil/pixdesc.h"

#import "HHVideoModel.h"
#import "HHAudioManager.h"
 
static BOOL DEBUG_NSLOG_TAG = NO;

@interface HHVideoDecoder() {
    AVFormatContext *_formatCtx;
    AVCodecContext *_videoCodecCtx;
    AVCodecContext *_audioCodecCtx;
    AVFrame *_videoFrame;
    AVFrame *_audioFrame;
    NSInteger _videoStream;
    NSInteger _audioStream;
    struct SwsContext *_swsContext;
    CGFloat _videoTimeBase;
    CGFloat _audioTimeBase;
    CGFloat _postion;
    NSArray *_videoStreams;
    NSArray *_audioStreams;
    SwrContext  *_swrContext;
    void    *_swrBuffer;
    NSInteger   _swrBufferSize;
    NSDictionary *_info;
    HHVideoFrameFormat _videoFrameFormat;
}

@end


@implementation HHVideoDecoder

+ (void)initialize {
    av_register_all();
    avformat_network_init();
}

- (BOOL)setupVideoFrameFormat:(HHVideoFrameFormat)format {
    if (format == HHVideoFrameFormatYUV && _videoCodecCtx && (_videoCodecCtx->pix_fmt == AV_PIX_FMT_YUV420P || _videoCodecCtx->pix_fmt == AV_PIX_FMT_YUVJ420P)) {
        _videoFrameFormat = HHVideoFrameFormatYUV;
        return YES;
    }
    _videoFrameFormat = HHVideoFrameFormatRGB;
    return _videoFrameFormat == format;
}
 
#pragma mark - 外部方法
+ (id)videoDecoderWithContentPath:(NSString *)path {
    if (DEBUG_NSLOG_TAG) {
        NSLog(@"Method: %s", __FUNCTION__);
    }
    HHVideoDecoder *mp = [[HHVideoDecoder alloc] init];
    if (mp) {
        [mp openFile:path];
    }
    return mp;
}

- (BOOL)openFile:(NSString *)path {
    if (path.length ==0) {
        NSLog(@"nil  path");
        return NO;
    }
    if (DEBUG_NSLOG_TAG) {
        NSLog(@"Method: %s", __FUNCTION__);
    }
    _isNetwork = isNetworkPath(path);
    
    static BOOL needNetworkInit = YES;
    if (needNetworkInit && _isNetwork) {
        needNetworkInit = NO;
        avformat_network_init();// 加载网络模块
    }
    
    _path = path;
    int errCode = [self openInput:path];
    
    if (errCode >= 0) {
        int videoError = [self openVideoStream]; // 初始化 Video的 AVCodec
        int audioError = [self openAudioStream]; // 初始化Audio 的AVCodec
        
        if (videoError < 0 || audioError < 0) {
            NSLog(@" 音视频流读取失败 ");
            return NO;
        }
    }
    
    if (errCode < 0) {
        [self closeFile];
        return NO;
    }
    
    return YES;
}

#pragma mark - set
- (BOOL)validAudio {
    return _audioStream != -1;
}

- (BOOL)validVideo {
    return  _videoStream != -1;
}

- (NSUInteger)frameWidth {
    return _videoCodecCtx ? _videoCodecCtx->width : 0;
}

- (NSUInteger)frameHeight {
    return _videoCodecCtx ? _videoCodecCtx->height : 0;
}

- (CGFloat)sampleRate {
    return _audioCodecCtx ? _audioCodecCtx->sample_rate : 0;
}

- (CGFloat)duration {
    if (!_formatCtx)
        return 0;
    if (_formatCtx->duration == AV_NOPTS_VALUE)
        return MAXFLOAT;
    return (CGFloat)_formatCtx->duration / AV_TIME_BASE;
}

- (CGFloat)position {
    return  _postion;
}
 
- (NSUInteger)audioStreamsCount {
    return [_audioStreams count];
}

- (NSInteger)selectedAudioStream {
    if (_audioStream == -1)
        return -1;
    NSNumber *n = [NSNumber numberWithInteger:_audioStream];
    return [_audioStreams indexOfObject:n];
}

- (void) setSelectedAudioStream:(NSInteger)selectedAudioStream {
    NSInteger audioStream = [_audioStreams[selectedAudioStream] integerValue];
    [self closeAudioStream];
    int errCode = [self openAudioStream: audioStream];
    if (errCode < 0) {
        NSLog(@" errCode ");
    }
}
  
- (CGFloat)startTime {
    if (_videoStream != -1) {
        AVStream *st = _formatCtx->streams[_videoStream];
        if (AV_NOPTS_VALUE != st->start_time)
            return st->start_time * _videoTimeBase;
        return 0;
    }
    
    if (_audioStream != -1) {
        AVStream *st = _formatCtx->streams[_audioStream];
        if (AV_NOPTS_VALUE != st->start_time)
            return st->start_time * _audioTimeBase;
        return 0;
    }
    return 0;
}

- (void) dealloc {
    [self closeFile];
}

#pragma mark - path  解析
- (int)openInput: (NSString *) path {
    if (DEBUG_NSLOG_TAG) {
        NSLog(@"Method: %s", __FUNCTION__);
    }
    int ret = 0;
    AVFormatContext *formatCtx = NULL;
//    if (_interruptCallback) {
//        formatCtx = avformat_alloc_context();
//        if (!formatCtx) {
//            NSLog(@" Open file  Error");
//            return -1;
//        }
//        AVIOInterruptCB cb = {interrupt_callback, (__bridge void *)(self)};
//        formatCtx->interrupt_callback = cb;
//    }
    ret = avformat_open_input(&formatCtx, [path cStringUsingEncoding:NSUTF8StringEncoding], NULL, NULL);
    if (ret < 0) {
        if (formatCtx) {
            avformat_free_context(formatCtx);
            NSLog(@" Open file  Error");
            return -1;
        }
    }
    ret = avformat_find_stream_info(formatCtx, NULL);
    if ( ret < 0) {
        avformat_close_input(&formatCtx);
        NSLog(@"Stream Info Not Found");
        return - 1;
    }
    av_dump_format(formatCtx, 0, [path.lastPathComponent cStringUsingEncoding:NSUTF8StringEncoding], false);
    
    _formatCtx = formatCtx;
    return 1;
}

#pragma mark - oepn Audio & Video Stream
- (int)openVideoStream {
    if (DEBUG_NSLOG_TAG) {
        NSLog(@"Method: %s", __FUNCTION__);
    }
    int error = 0;
    _videoStream = -1;
    _videoStreams = collectStreams(_formatCtx, AVMEDIA_TYPE_VIDEO);
    for (NSNumber *n in _videoStreams) {
        const NSUInteger iStream = n.integerValue;
        if (0 == (_formatCtx->streams[iStream]->disposition & AV_DISPOSITION_ATTACHED_PIC)) {
            error = [self openVideoStream:iStream];
            if (error < 0) {
                NSLog(@"openVideoStream error %d", error);
                break;
            }
        }
    }
    return error;
}

- (int)openVideoStream:(NSInteger)videoStream {
    if (DEBUG_NSLOG_TAG) {
        NSLog(@"Method: %s", __FUNCTION__);
    }
    int ret = 0;
    AVCodecParameters *codecPara = _formatCtx->streams[videoStream]->codecpar;
    AVCodec *codec = avcodec_find_decoder(codecPara->codec_id);
    AVCodecContext *codecCtx = avcodec_alloc_context3(codec);
    ret = avcodec_parameters_to_context(codecCtx, codecPara); //将Parameters 中的参数给到codecCtx
      
    if (!codec) {
        NSLog(@" decoder  not found ");
        return -1;
    }
    ret = avcodec_open2(codecCtx, codec, NULL);
    if (ret < 0) {
        NSLog(@" open codec error ");
        return -1;
    }
    _videoFrame = av_frame_alloc();
    if (!_videoFrame) {
        avcodec_close(codecCtx);
    }
    
    _videoStream = videoStream;
    _videoCodecCtx = codecCtx;
    
    AVStream *st = _formatCtx->streams[_videoStream];
    avStreamFPSTimeBase(st, 0.04, &_fps, &_videoTimeBase);
    return 1;
}

- (int)openAudioStream {
    if (DEBUG_NSLOG_TAG) {
        NSLog(@"Method: %s", __FUNCTION__);
    }
    int errCode = -1;
    _audioStream = -1;
    _audioStreams = collectStreams(_formatCtx, AVMEDIA_TYPE_AUDIO);
    for (NSNumber *n in _audioStreams) {
        errCode = [self openAudioStream:n.integerValue];
        if (errCode < 0) {
            NSLog(@"openAudioStream error %d", errCode);
            break;
        }
    }
    return errCode;
}

- (int)openAudioStream:(NSInteger) audioStream {
    if (DEBUG_NSLOG_TAG) {
        NSLog(@"Method: %s", __FUNCTION__);
    }
    int  ret = 0;
    AVCodecParameters *codecPara = _formatCtx->streams[audioStream]->codecpar;
    AVCodec *codec = avcodec_find_decoder(codecPara->codec_id);
    AVCodecContext *codecCtx = avcodec_alloc_context3(codec);
    ret = avcodec_parameters_to_context(codecCtx, codecPara);
    SwrContext *swrContext = NULL;
    if (!codec) {
        return -1;
    }
    ret = avcodec_open2(codecCtx, codec, NULL);
    if (ret < 0) {
        return -1;
    }
    
    id<HHAudioManager> audioManager = [HHAudioManager audioManager]; 
    
    int64_t num_out_channels = av_get_default_channel_layout(audioManager.numOutputChannels);
    int64_t channels = av_get_default_channel_layout(codecCtx->channels);
    
    NSLog(@"音视频流参数------------------");
    NSLog(@"音频通道数量:%lld , 音频采样格式:%lld, 音频采样率:%d",channels,codecCtx->sample_fmt,codecCtx->sample_rate);
    NSLog(@"设备音视频参数:%d, 设备音视频采样率:%.3f", num_out_channels, audioManager.samplingRate);
    NSLog(@"---------------");
    // 默认直接 重采样
    swrContext = swr_alloc_set_opts(NULL, av_get_default_channel_layout(audioManager.numOutputChannels), AV_SAMPLE_FMT_S16, audioManager.samplingRate,av_get_default_channel_layout(codecCtx->channels),codecCtx->sample_fmt,codecCtx->sample_rate,0, NULL);
    if (!swrContext || swr_init(swrContext)) {
        if (swrContext) {
            swr_free(&swrContext);
        }
        avcodec_close(codecCtx);
        return -1;
    }
    
    _audioFrame = av_frame_alloc();
    if (!_audioFrame) {
        if (swrContext) {
            swr_free(&swrContext);
        }
        avcodec_close(codecCtx);
        return -1;
    }
    
    _audioStream = audioStream;
    _audioCodecCtx = codecCtx;
    _swrContext = swrContext;
    
    AVStream *st = _formatCtx->streams[_audioStream];
    avStreamFPSTimeBase(st, 0.025, 0, &_audioTimeBase);

    return 1;
}

-(void)closeFile {
    if (DEBUG_NSLOG_TAG) {
        NSLog(@"Method: %s", __FUNCTION__);
    }
    [self closeAudioStream];
    [self closeVideoStream];
    
    _videoStreams = nil;
    _audioStreams = nil;
    
    if (_formatCtx) {
        _formatCtx->interrupt_callback.opaque = NULL;
        _formatCtx->interrupt_callback.callback = NULL;
        
        avformat_close_input(&_formatCtx);
        _formatCtx = NULL;
    }
}
 
#pragma mark - close VideoStream & AudioStream & closeScale
- (void)closeVideoStream {
    if (DEBUG_NSLOG_TAG) {
        NSLog(@"Method: %s", __FUNCTION__);
    }
    _videoStream = -1;
    [self closeScaler];
    if (_videoFrame) {
        av_free(_videoFrame);
        _videoFrame = NULL;
    }
    
    if (_videoCodecCtx) {
        avcodec_close(_videoCodecCtx);
        _videoCodecCtx = NULL;
    }
}

- (void)closeAudioStream{
    if (DEBUG_NSLOG_TAG) {
        NSLog(@"Method: %s", __FUNCTION__);
    }
    _audioStream = -1;
    if (_swrBuffer) {
        free(_swrBuffer);
        _swrBuffer = NULL;
        _swrBufferSize = 0;
    }
    if (_swrContext) {
        swr_free(&_swrContext);
        _swrContext = NULL;
    }
    if (_audioFrame) {
        av_free(_audioFrame);
        _audioFrame = NULL;
    }
    if (_audioCodecCtx) {
        avcodec_close(_audioCodecCtx);
        _audioCodecCtx = NULL;
    }
}

- (void)closeScaler {
    if (DEBUG_NSLOG_TAG) {
        NSLog(@"Method: %s", __FUNCTION__);
    }
    if (_swsContext) {
        sws_freeContext(_swsContext);
        _swsContext = NULL;
    }
}
 
- (HHVideoFrame *) handleVideoFrame:(AVPacket)packet {
    if (DEBUG_NSLOG_TAG) {
        NSLog(@"Method: %s", __FUNCTION__);
    }
    if (!_videoFrame->data[0]) {
        return nil;
    }
    HHVideoFrame *frame;
    if (_videoFrameFormat == HHVideoFrameFormatYUV) {
        HHVideoFrameYUV *yuvFrame = [[HHVideoFrameYUV alloc] init];
        yuvFrame.luma = copyFrameData(_videoFrame->data[0], _videoFrame->linesize[0], _videoCodecCtx->width, _videoCodecCtx->height);
        yuvFrame.chromaB = copyFrameData(_videoFrame->data[1], _videoFrame->linesize[1], _videoCodecCtx->width/2, _videoCodecCtx->height/2);
        yuvFrame.chromaR = copyFrameData(_videoFrame->data[2], _videoFrame->linesize[2], _videoCodecCtx->width/2, _videoCodecCtx->height/2);
        yuvFrame.type = HhMovieFrameTypeVideo;
        frame = yuvFrame;
    }
    frame.width = _videoCodecCtx->width;
    frame.height = _videoCodecCtx->height;
    int64_t best_time = packet.pts;// dts解码 时间戳、 pts 显示时间戳，pts 一定大于 dts
    int64_t get_pk_duration = packet.duration;
    frame.position = best_time * _videoTimeBase;
    const int64_t frameDuration = get_pk_duration;
    if (frameDuration) {
        frame.duration = frameDuration * _videoTimeBase;
        frame.duration += _videoFrame->repeat_pict * _videoTimeBase *0.5;
    }else {
        frame.duration = 1.0 / _fps;
    }
    
    return frame;
}

- (HHAudioFrame *)handleAudioFrame:(AVPacket)packet {
    if (DEBUG_NSLOG_TAG) {
        NSLog(@"Method: %s", __FUNCTION__);
    }
    if (!_audioFrame->data[0]) {
        return nil;
    }
    id<HHAudioManager> audioManager = [HHAudioManager audioManager];
    const NSUInteger numChannels = audioManager.numOutputChannels;
    NSInteger numFrames;
    
    void *audioData;
    if (_swrContext) {
        const NSUInteger ratio = MAX(1, audioManager.samplingRate / _audioCodecCtx->sample_rate) *
                                 MAX(1, audioManager.numOutputChannels / _audioCodecCtx->channels) * 2;
        int nb_samples = _audioFrame->nb_samples * ratio;
        const int bufSize = av_samples_get_buffer_size(NULL,audioManager.numOutputChannels, nb_samples, AV_SAMPLE_FMT_S16,1);
        if (!_swrBuffer || _swrBufferSize < bufSize) {
            _swrBufferSize = bufSize;
            _swrBuffer = realloc(_swrBuffer, _swrBufferSize);
        }
        
        Byte *outbuf[2] = { _swrBuffer, 0 };

        numFrames = swr_convert(_swrContext, outbuf,  _audioFrame->nb_samples * ratio, (const uint8_t **)_audioFrame->data, _audioFrame->nb_samples);
        
        if (numFrames < 0) {
            return nil;
        }
        audioData = _swrBuffer;
    }else {
        if (_audioCodecCtx->sample_fmt != AV_SAMPLE_FMT_S16) {
            NSAssert(false, @"bucheck, audio format is invalid");
            return nil;
        }
        
        audioData = _audioFrame->data[0];
        numFrames = _audioFrame->nb_samples;
    }
     
    const NSUInteger numElements = numFrames * numChannels;
    NSMutableData *data = [NSMutableData dataWithLength:numElements * sizeof(float)];

    float scale = 1.0 / (float)INT16_MAX ;
    vDSP_vflt16((SInt16 *)audioData, 1, data.mutableBytes, 1, numElements);
    vDSP_vsmul(data.mutableBytes, 1, &scale, data.mutableBytes, 1, numElements);

    
    HHAudioFrame *frame = [[HHAudioFrame alloc] init];
     
    int64_t best_time = packet.pts;
    int64_t get_pk_duration = packet.duration;
    frame.position = best_time * _audioTimeBase;
    frame.duration = get_pk_duration * _audioTimeBase;
    frame.samples = data;

    if (frame.duration == 0) {
        frame.duration = frame.samples.length / (sizeof(float) * numChannels * audioManager.samplingRate);
    }
    return frame;
}

#pragma mark - decodeFrames
- (NSArray *)decodeFrames:(CGFloat)minDuration {
    if (DEBUG_NSLOG_TAG) {
        NSLog(@"Method: %s", __FUNCTION__);
    }
    if (_videoStream == -1 &&
        _audioStream == -1) {
        return nil;
    }
    NSMutableArray *result = [NSMutableArray array];
    AVPacket packet;
    
    CGFloat decodedDuration = 0;
    BOOL finished = NO;
    int video_count = 0;
    int audio_count = 0;
    while (!finished) {
        if (av_read_frame(_formatCtx, &packet) < 0) {
            _isEOF = YES;
            break;
        }
        
        if (packet.stream_index == _videoStream) {
            video_count ++;
            int pktSize = packet.size;
            while (pktSize > 0) {
                int gotframe = 0;
                int len = avcodec_decode_video2(_videoCodecCtx, _videoFrame, &gotframe, &packet);
                // packet->pts = 0;  packet->duration = 768
            
                if (len < 0) {
                    break;
                }
//                NSLog(@"gotframe == %d , len == %d, pktSize == %d", gotframe, len, pktSize);
                if (gotframe) {
                    HHVideoFrame *frame  = [self handleVideoFrame:packet];
                    if (frame) {
                        [result addObject:frame];
                        _postion = frame.position;
                        decodedDuration += frame.duration;
//                        NSLog(@"result.cout:%lu, decodedDuration = %f", (unsigned long)result.count, decodedDuration);
                        if (decodedDuration > minDuration) {
                            finished = YES;
                        }
                    }
                    if (0 == len) {
                        break;
                    }
                    pktSize -= len;
                }
            }
        }
        else if (packet.stream_index == _audioStream) {
            audio_count ++;
            int pktSize = packet.size;
            while (pktSize > 0) {
                int gotframe = 0;
                int len = avcodec_decode_audio4(_audioCodecCtx, _audioFrame, &gotframe, &packet);
                // packet->pts = -1024 \ packet->duration = 1024
                if (len < 0) {
                    break;
                }
                if (gotframe) {
                    HHAudioFrame *frame = [self handleAudioFrame:packet];
                    if (frame) {
                        [result addObject:frame];
                        if (_videoStream == -1) {
                            _postion = frame.position;
                            decodedDuration += frame.duration;
                            if (decodedDuration > minDuration) {
                                finished = YES;
                            }
                        }
                    }
                }
                if (0 == len) {
                    break;
                }
                pktSize -= len;
            }
        }
//        NSLog(@"video_count = %d , audio_count = %d , stream_index:%d", video_count, audio_count , packet.stream_index);
        av_free_packet(&packet);
    }
    return result;
}

#pragma mark - C Method
static void avStreamFPSTimeBase(AVStream *st, CGFloat defaultTimeBase, CGFloat *pFPS, CGFloat *pTimeBase) {
    CGFloat fps, timebase;
    if (st->time_base.den && st->time_base.num) {
        timebase = av_q2d(st->time_base);
    }else if (st->time_base.den && st->time_base.num) {
        timebase = av_q2d(st->time_base);
    }else {
        timebase = defaultTimeBase;
    }
    if (st->avg_frame_rate.den && st->avg_frame_rate.num) {
        fps = av_q2d(st->avg_frame_rate);
    }else if (st->r_frame_rate.den && st->r_frame_rate.num) {
        fps = av_q2d(st->r_frame_rate);
    }else {
        fps = 1.0 / timebase;
    }
    if (pFPS) {
        *pFPS = fps;
    }
    if (pTimeBase) {
        *pTimeBase = timebase;
    }
}

static NSArray *collectStreams(AVFormatContext *formatCtx, enum AVMediaType codecType) {
    NSMutableArray *ma = [NSMutableArray array];// 把媒体流中包含的 type 取出来，存起来
    for (NSInteger i = 0; i< formatCtx->nb_streams; ++i) {
        if (codecType == formatCtx->streams[i]->codecpar->codec_type) {
            [ma addObject:[NSNumber numberWithInteger:i]];
        }
    }
    return [ma copy];
}

static NSData * copyFrameData(UInt8 *src, int linesize, int width, int height) {
    width = MIN(linesize, width);
    NSMutableData *md = [NSMutableData dataWithLength: width * height];
    Byte *dst = md.mutableBytes;
    for (NSUInteger i = 0; i < height; ++i) {
        memcpy(dst, src, width);
        dst += width;
        src += linesize;
    }
    return md;
}

#pragma mark -----
static int interrupt_callback(void *ctx) {
    if (!ctx)
        return 0;
    __unsafe_unretained HHVideoDecoder *p = (__bridge HHVideoDecoder *)ctx;
    const BOOL r = [p interruptDecoder];
    return r;
}

- (BOOL) interruptDecoder {
    if (_interruptCallback)
        return _interruptCallback();
    return NO;
}

#pragma mark -----
static BOOL isNetworkPath (NSString *path) {
    NSRange r = [path rangeOfString:@":"];
    if (r.location == NSNotFound)
        return NO;
    NSString *scheme = [path substringToIndex:r.length];
    if ([scheme isEqualToString:@"file"])
        return NO;
    return YES;
}

- (void)rePlayer {
    if (_isEOF) { 
        avformat_seek_file(_formatCtx, -1, 0, 0, 0, 0);
        avcodec_flush_buffers(_videoCodecCtx);
    }
}
@end
