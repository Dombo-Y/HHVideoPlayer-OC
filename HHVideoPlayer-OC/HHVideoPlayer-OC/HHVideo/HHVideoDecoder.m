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

@interface HHVideoDecoder() {
    AVFormatContext *_formatCtx;
    AVCodecContext *_videoCodecCtx;
    AVCodecContext *_audioCodecCtx;
    AVFrame *_videoFrame;
    AVFrame *_audioFrame;
    NSInteger _videoStream;
    NSInteger _audioStream;
    AVPicture _picture;
    BOOL    _pictureValid;
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
    return YES;
}

- (BOOL) setupScaler {
    [self closeScaler];
    _pictureValid = avpicture_alloc(&_picture, AV_PIX_FMT_RGB24, _videoCodecCtx->width, _videoCodecCtx->height) == 0;
    if (!_pictureValid) {
        return NO;
    }
    _swsContext = sws_getCachedContext(_swsContext, _videoCodecCtx->width, _videoCodecCtx->height, _videoCodecCtx->pix_fmt, _videoCodecCtx->width, _videoCodecCtx->height, AV_PIX_FMT_RGB24, SWS_FAST_BILINEAR, NULL, NULL, NULL);
    
    return _swsContext != NULL;
}

#pragma mark - 外部方法
+ (id)videoDecoderWithContentPath:(NSString *)path {
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
    _isNetwork = isNetworkPath(path);
    
    static BOOL needNetworkInit = YES;
    if (needNetworkInit && _isNetwork) {
        needNetworkInit = NO;
        avformat_network_init();// 加载网络模块
    }
    
    _path = path;
    int errCode = [self openInput:path];
    
    if (errCode >= 0) {
        int videoError = [self openVideoStream];
        int audioError = [self openAudioStream];
        
        if (videoError < 0 ||
            audioError < 0) {
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

- (BOOL)validAudio {
    return _audioStream != -1;
}

- (BOOL)validVideo {
    return _videoStream != -1;
}

- (NSUInteger) frameWidth {
    return _videoCodecCtx ? _videoCodecCtx->width : 0;
}

- (NSUInteger) frameHeight {
    return _videoCodecCtx ? _videoCodecCtx->height : 0;
}


#pragma mark - path  解析
- (int)openInput: (NSString *) path {
    AVFormatContext *formatCtx = NULL;
    if (_interruptCallback) {
        formatCtx = avformat_alloc_context();
        if (!formatCtx) {
            NSLog(@" Open file  Error");
            return -1;
        }
        AVIOInterruptCB cb = {interrupt_callback, (__bridge void *)(self)};
        formatCtx->interrupt_callback = cb;
    }
    
    if (avformat_open_input(&formatCtx, [path cStringUsingEncoding:NSUTF8StringEncoding], NULL, NULL) < 0) {
        if (formatCtx) {
            avformat_free_context(formatCtx);
            NSLog(@" Open file  Error");
            return -1;
        }
    }
    
    if (avformat_find_stream_info(formatCtx, NULL) < 0) {
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
    int error = 0;
    _videoStream = -1;
    _videoStreams = collectStreams(_formatCtx, AVMEDIA_TYPE_VIDEO);
    for (NSNumber *n in _videoStreams) {
        const NSUInteger iStream = n.integerValue;
        if (0 == (_formatCtx->streams[iStream]->disposition & AV_DISPOSITION_ATTACHED_PIC)) {
            error = [self openVideoStream:iStream];
            if (error < 0) {
                break;
            }
        }
    }
    return error;
}

- (int)openVideoStream:(NSInteger)videoStream {
    AVCodecParameters *codecPara = _formatCtx->streams[videoStream]->codecpar;
    AVCodec *codec = avcodec_find_decoder(codecPara->codec_id);
    AVCodecContext *codecCtx = avcodec_alloc_context3(codec);
    if (!codec) {
        NSLog(@" decoder  not found ");
        return -1;
    }
    
    if (avcodec_open2(codecCtx, codec, NULL) < 0) {
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
    int errCode = -1;
    _audioStream = -1;
    _audioStreams = collectStreams(_formatCtx, AVMEDIA_TYPE_AUDIO);
    for (NSNumber *n in _audioStreams) {
        errCode = [self openAudioStream:n.integerValue];
        if (errCode < 0) {
            break;
        }
    }
    return errCode;
}

- (int)openAudioStream:(NSInteger) audioStream {
    AVCodecParameters *codecPara = _formatCtx->streams[audioStream]->codecpar;
    AVCodec *codec = avcodec_find_decoder(codecPara->codec_id);
    AVCodecContext *codecCtx = avcodec_alloc_context3(codec);
    
    SwrContext *swrContext = NULL;
    
    if (!codec) {
        return -1;
    }
    if (avcodec_open2(codecCtx, codec, NULL) < 0) {
        return -1;
    }
    if (!audioCodecIsSupported(codecCtx)) {
        
    }
    _audioFrame = av_frame_alloc();
    
    if (!_audioFrame) {
        if (_swrContext) {
            
            id<HHAudioManager> audioManager = [HHAudioManager audioManager];
            swrContext = swr_alloc_set_opts(NULL, av_get_default_channel_layout(audioManager.numOutputChannels), AV_SAMPLE_FMT_S16, audioManager.samplingRate,av_get_default_channel_layout(codecCtx->channels),codecCtx->sample_fmt,codecCtx->sample_rate,
                                            0, NULL);
            swr_init(swrContext);
            
            if (!swrContext) {
                if (swrContext) {
                    swr_free(&swrContext);
                    avcodec_close(codecCtx);
                    NSLog(@" 音频重采样失败 ");
                    return -1;
                }
            }
            
            _audioFrame = av_frame_alloc();
            if (!_audioFrame) { //
                if (swrContext) {
                    swr_free(&swrContext);
                }
                avcodec_close(codecCtx);
                NSLog(@"初始化 audioFrame 失败，内存不够了");
                return -1;
            }
            
            _audioStream = audioStream;
            _audioCodecCtx = codecCtx;
            _swrContext = swrContext;
            
            AVStream *st = _formatCtx->streams[_audioStream];
            avStreamFPSTimeBase(st, 0.025, 0, &_audioTimeBase);
        }
    }
    return 1;
}

#pragma mark - close VideoStream & AudioStream & closeScale
- (void) closeVideoStream {
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

- (void) closeAudioStream{
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

- (void) closeScaler {
    if (_swsContext) {
        sws_freeContext(_swsContext);
        _swsContext = NULL;
    }
    if (_pictureValid) {
        avpicture_free(&_picture);
        _pictureValid = NO;
    }
}

- (void)closeFile {
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

#pragma mark - decodeFrames
- (NSArray *)decodeFrames:(CGFloat)minDuration {
    if (_videoStream == -1 &&
        _audioStream == -1) {
        return nil;
    }
    NSMutableArray *result = [NSMutableArray array];
    AVPacket packet;
    
    CGFloat decodedDuration = 0;
    BOOL finished = NO;
    
    while (!finished) {
        if (av_read_frame(_formatCtx, &packet) < 0) {
            _isEOF = YES;
            break;
        }
        if (packet.stream_index == _videoStream) {
            int pktSize = packet.size;
            while (pktSize > 0) {
                int gotframe = 0;
                int len = avcodec_decode_video2(_videoCodecCtx, _videoFrame, &gotframe, &packet);
                if (len < 0) {
                    break;
                }
                
                if (gotframe) {
                    HHVideoFrame *frame  = [self handleVideoFrame];
                    if (frame) {
                        [result addObject:frame];
                        _postion = frame.position;
                        decodedDuration += frame.duration;
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
        }  else if (packet.stream_index == _audioStream) {
            int pktSize = packet.size;
            while (pktSize > 0) {
                int gotframe = 0;
                int len = avcodec_decode_audio4(_audioCodecCtx, _audioFrame, &gotframe, &packet);
                if (len < 0) {
                    break;
                }
                if (gotframe) {
                    HHAudioFrame *frame = [self handleAudioFrame];
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
        av_free_packet(&packet);
    }
    return result;
}

- (HHVideoFrame *) handleVideoFrame {
    
    if (!_videoFrame->data[0]) {
        return nil;
    }
    HHVideoFrame *frame;
    if (_videoFrameFormat == HHVideoFrameFormatYUV) {
        HHVideoFrameYUV *yuvFrame = [[HHVideoFrameYUV alloc] init];
        yuvFrame.luma = copyFrameData(_videoFrame->data[0], _videoFrame->linesize[0], _videoCodecCtx->width, _videoCodecCtx->height);
        yuvFrame.chromaB = copyFrameData(_videoFrame->data[1], _videoFrame->linesize[1], _videoCodecCtx->width/2, _videoCodecCtx->height/2);
        yuvFrame.chromaR = copyFrameData(_videoFrame->data[2], _videoFrame->linesize[2], _videoCodecCtx->width/2, _videoCodecCtx->height/2);
        frame = yuvFrame;
    }else {
        if (!_swsContext && ![self setupScaler]) {
            return nil;
        }
        sws_scale(_swsContext, (const uint8_t **)_videoFrame->data, _videoFrame->linesize, 0, _videoCodecCtx->height, _picture.data, _picture.linesize);

        HHVideoFrameRGB *rgbFrame = [[HHVideoFrameRGB alloc] init];
        rgbFrame.linesize = _picture.linesize[0];
        rgbFrame.rgb = [NSData dataWithBytes:_picture.data[0] length:rgbFrame.linesize * _videoCodecCtx->height];
        frame = rgbFrame;
    }
    
    frame.width = _videoCodecCtx->width;
    frame.height = _videoCodecCtx->height;
    frame.position = av_frame_get_best_effort_timestamp(_videoFrame) * _videoTimeBase;

    const int64_t frameDuration = av_frame_get_pkt_duration(_videoFrame);
    if (frameDuration) {
        frame.duration = frameDuration * _videoTimeBase;
        frame.duration += _videoFrame->repeat_pict * _videoTimeBase *0.5;
    }else {
        frame.duration = 1.0 / _fps;
    }
    
    return frame;
}

- (HHAudioFrame *) handleAudioFrame {
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
        
        const int bufSize = av_samples_get_buffer_size(NULL,audioManager.numOutputChannels, _audioFrame->nb_samples * ratio, AV_SAMPLE_FMT_S16,1);
        if (!_swrBuffer || _swrBufferSize < bufSize) {
            _swrBufferSize = bufSize;
            _swrBuffer = realloc(_swrBuffer, _swrBufferSize);
        }
        
        Byte *outbuf[2] = { _swrBuffer, 0 };

        numFrames = swr_convert(_swrContext, outbuf,  _audioFrame->nb_samples * ratio, (const uint8_t **)_audioFrame->data, _audioFrame->nb_samples);
        
        if (numFrames < 0) {
//            LoggerAudio(0, @"fail resample audio");
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
    frame.position = av_frame_get_best_effort_timestamp(_audioFrame) * _audioTimeBase;
    frame.duration = av_frame_get_pkt_duration(_audioFrame) * _audioTimeBase;
    frame.samples = data;

    if (frame.duration == 0) {
        frame.duration = frame.samples.length / (sizeof(float) * numChannels * audioManager.samplingRate);
    }
    
    return nil;
}



#pragma mark - C Method
static BOOL audioCodecIsSupported(AVCodecContext *audio) {
    if (audio->sample_fmt == AV_SAMPLE_FMT_S16) {
        id<HHAudioManager> audioManager = [HHAudioManager audioManager];
        return  (int)audioManager.samplingRate == audio->sample_rate &&
                audioManager.numOutputChannels == audio->channels;
    }
    
    return NO;
}
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
@end
