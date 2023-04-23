//
//  HHPlayerManager.m
//  HHVideoPlayer-OC
//
//  Created by 尹东博 on 2023/4/20.
//

/* 播放器设计思路：
 1.传进来一个URL Path(本地地址 or  网络地址)
 2. 在OpenFile 流程中 对 Decoder 中进行一些处理【 对 URL Path 进行判断，如何合法 就用 avformat_open_input 进行 formatCtx，这里可以获取到视频文件的参数信息】
 3. 在SetVideoDecoder 流程中 创建AudioArray & VideoArray & DispatchQueue，将GLView 题add到 TargetView 上，然后Play
 4. 从Decoder 中获取 Frame，将每个取出来的Frame的时间进行累加，达到一定时间后finish，然后返回array，这里包含视频帧与音频帧是混合的
 5. 返回出来以后对 混合音视频帧的Array 进行解析，区分为Video 和Audio，分别加入VideoArray 和 AudioArray
 6. 进行tick 循环
 7.打开Audio 播放器
 
 */

#import "HHPlayerManager.h"
#import "HHVideoDecoder.h"
#import "HHVideoGLView.h"
#import "HHAudioManager.h"
#import "HHVideoModel.h"
  
static BOOL DEBUG_NSLOG_TAG = NO;
 
#define LOCAL_MIN_BUFFERED_DURATION   0.2
#define LOCAL_MAX_BUFFERED_DURATION   0.4
#define NETWORK_MIN_BUFFERED_DURATION 2.0
#define NETWORK_MAX_BUFFERED_DURATION 4.0

@interface HHPlayerManager() {
    HHVideoDecoder  *_decoder;
    dispatch_queue_t _dispatchQueue;
    NSMutableArray *_videoFrames;
    NSMutableArray *_audioFrames;
    
    HHVideoGLView *_glView;
    UIView *_targetView;
      
    NSData  *_currentAudioFrame; // 存储当前音视频帧的NSData 对象
    NSUInteger  _currentAudioFramePos; // 表示当前音频帧的位置，即已经播放了多少个字节
    CGFloat _videoPosition; // 视频的位置
    CGFloat _audioPostion;// 音频位置
    CGFloat _bufferedDuration; // 表示当前已经缓冲的视频时长，单位为秒。
    CGFloat _minBufferedDuration; // 表示最小的视频缓冲时长，单位为秒，如果当前已经缓冲的时长小于最小缓冲时长，就会开始缓冲视频。
    CGFloat _maxBufferedDuration; // 表示最大的视频缓冲时长，单位为秒。如果当前已经缓冲的时长超过最大缓冲时长，就会停止缓冲视频。
     
    NSTimeInterval  _tickCorrectionTime; //音视频同步时钟的初始时间
    NSTimeInterval  _tickCorrectionPosition;// 音视频同步时钟的初始位置
    NSUInteger _tickCounter; //  一个计数器，用于统计每秒的帧数，以便计算播放速度偏差。
      
}

@property (nonatomic, assign) BOOL playing; //是否在播放中
@property (nonatomic, assign) BOOL interrupted; // 是否需要中断
@property (nonatomic, assign) BOOL decoding;
@property (nonatomic, assign) BOOL buffered;
@end

@implementation HHPlayerManager
 
+ (instancetype)sharedInstance {
    static HHPlayerManager *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (void)setupAudioConfig {
    id<HHAudioManager> audioManager = [HHAudioManager audioManager];
    [audioManager activateAudioSession]; 
}
 
#pragma mark -
- (void)playerManagerWithContentPath:(NSString *)path targetView:(id)view {
    NSAssert(path.length > 0, @"empty path");
    if (DEBUG_NSLOG_TAG) {
        NSLog(@"Method: %s", __FUNCTION__);
    }
    [self setupAudioConfig];
    if ([view isKindOfClass:[UIView class]]) {
        _targetView = (UIView *)view;
    }
    
    HHVideoDecoder *decoder = [[HHVideoDecoder alloc] init];
    _videoPosition = 0;
    __weak HHPlayerManager *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        BOOL success = NO;
        success = [decoder openFile:path]; // init  FFmpeg
         
        __strong HHPlayerManager *strongSelf = weakSelf;
        dispatch_sync(dispatch_get_main_queue(), ^{
            [strongSelf setVideoDecoder:decoder openSuccess:success];
        });
    });
}
 
- (void)destroy {
    [self pause];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (_dispatchQueue) {
        _dispatchQueue = NULL;
    }
}

- (void)setVideoDecoder:(HHVideoDecoder *)decoder openSuccess:(BOOL)success{ // 3
    if (DEBUG_NSLOG_TAG) {
        NSLog(@"Method: %s", __FUNCTION__);
    }
    if (decoder && success) {
        _decoder = decoder;
        _dispatchQueue = dispatch_queue_create("HHView_MAIN_QUEUE", DISPATCH_QUEUE_SERIAL);
        _videoFrames = [NSMutableArray array];
        _audioFrames = [NSMutableArray array];
        
        if (_decoder.isNetwork) {
            _minBufferedDuration = NETWORK_MIN_BUFFERED_DURATION;
            _maxBufferedDuration = NETWORK_MAX_BUFFERED_DURATION;
            
        } else {
            _minBufferedDuration = LOCAL_MIN_BUFFERED_DURATION;
            _maxBufferedDuration = LOCAL_MAX_BUFFERED_DURATION;
        }
        
        if (!_decoder.validVideo)
            _minBufferedDuration *= 10.0; // increase for audio
        
        [self setupPresentView];
        
        if (_decoder.validAudio) {// 开启音频  调用一次
            [self enableAudio:YES];
        }
    }
     
    [self play];  // play
}

- (void)setupPresentView {
    if (DEBUG_NSLOG_TAG) {
        NSLog(@"Method: %s", __FUNCTION__);
    }
    if (_decoder.validVideo) {
        _glView = [[HHVideoGLView alloc] initWithFrame:_targetView.bounds decoder:_decoder];
    }
     
    if (!_glView) {
        NSLog(@" 没有 HHVideoGLView  ");
        return;
    }
     
    [_targetView addSubview:_glView];
    _glView.contentMode = UIViewContentModeScaleAspectFit;
    _glView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleBottomMargin;
     
    _targetView.backgroundColor = [UIColor clearColor];
}

#pragma mark - control Method
- (void)play {
    if (DEBUG_NSLOG_TAG) {
        NSLog(@"Method: %s", __FUNCTION__);
    }
    if (self.playing) { // 1.状态判断
        return;
    }
    if (!_decoder.validVideo && !_decoder.validAudio) { //2. 音视频有效判断
        return;
    }
    if (_interrupted) { // 3.是否被拦截
        return;
    }
    
//    if (_decoder.isEOF) { // 是否EOF，重播就seek
//        [_decoder rePlayer];
//    }
    
    self.playing = YES;
    _interrupted = NO;
    _tickCorrectionTime = 0;
    _tickCounter = 0;
    _buffered = YES;
      
    [self asyncDecoderFrames];// 4.开始解码视频帧
     
    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, 0.1 * NSEC_PER_SEC);
    dispatch_after(popTime, dispatch_get_main_queue(), ^{
        [self tick];
    });
}

- (void)pause {
    if (!self.playing) {
        return;
    }
    self.playing = NO;
    [self enableAudio:NO];
//    []; 更新UI
}

#pragma mark - open Audio  outputBlock 循环
- (void)enableAudio:(BOOL)on {
    if (DEBUG_NSLOG_TAG) {
        NSLog(@"Method: %s", __FUNCTION__);
    }
     
    id<HHAudioManager>audioManager = [HHAudioManager audioManager];
    if (on && _decoder.validAudio) {
        audioManager.outputBlock = ^(float * _Nonnull data, UInt32 numFrames, UInt32 numChannels) {
            [self audioCallbackFillData:data numFrames:numFrames numChannels:numChannels];
        };
        [audioManager play];
    }else {
        [audioManager pause];
        audioManager.outputBlock = NULL;
    }
     
}

- (void)audioCallbackFillData:(float *)outData numFrames:(UInt32)numFrames numChannels:(UInt32)numChannels {
    if (DEBUG_NSLOG_TAG) {
        NSLog(@"Method: %s", __FUNCTION__);
    }
    if (_buffered) {
        memset(outData, 0, numFrames * numChannels * sizeof(float));
        return;
    }
//    NSLog(@"audioCallbackFillData == %f",_audioPostion);
    @autoreleasepool {
        while (numFrames > 0) {
            if (!_currentAudioFrame) {
                @synchronized(_audioFrames) {
                    NSUInteger count = _audioFrames.count;
                    if (count > 0) {
                        HHAudioFrame *frame = _audioFrames[0];
                        if (_decoder.validVideo) {
                            const CGFloat delta = _videoPosition - frame.position;
                            _audioPostion = frame.position; 
                            if (delta < -0.1) {
                                memset(outData, 0, numFrames * numChannels * sizeof(float));
                                break;
                            }
                            [_audioFrames removeObjectAtIndex:0];
                            if (delta > 0.1 && count > 1) {
                                continue;
                            }
                             
                        } else {
                            [_audioFrames removeObjectAtIndex:0];
                            _videoPosition = frame.position;
                            _bufferedDuration -= frame.duration;
                        }
                        _currentAudioFramePos = 0;
                        _currentAudioFrame = frame.samples;
                    }
                }
            }
            
            if (_currentAudioFrame) {
                const void *bytes = (Byte *)_currentAudioFrame.bytes + _currentAudioFramePos;
                const NSUInteger bytesLeft = (_currentAudioFrame.length - _currentAudioFramePos);
                const NSUInteger frameSizeOf = numChannels * sizeof(float);
                const NSUInteger bytesToCopy = MIN(numFrames * frameSizeOf, bytesLeft);
                const NSUInteger framesToCopy = bytesToCopy / frameSizeOf;
                memcpy(outData, bytes, bytesToCopy);
                numFrames -= framesToCopy;
                outData += framesToCopy * numChannels;
                if (bytesToCopy < bytesLeft)
                    _currentAudioFramePos += bytesToCopy;
                else
                    _currentAudioFrame = nil;
            } else {
                memset(outData, 0, numFrames * numChannels * sizeof(float));
                break;
            }
        }
    }
}

#pragma mark - 解析～～ 循环
- (void)asyncDecoderFrames {
    if (DEBUG_NSLOG_TAG) {
        NSLog(@"Method: %s", __FUNCTION__);
    }
    if (self.decoding) {
        return;
    }
    const CGFloat duration = _decoder.isNetwork ? 0.f : 0.1f;
     
    __weak HHVideoDecoder *weakDecoder = _decoder;
    __weak HHPlayerManager *weakManager = self;
    
    self.decoding = YES;
    dispatch_async(_dispatchQueue, ^{
        {
            __strong HHPlayerManager *strongSelf = weakManager;
            if (!strongSelf.playing)
                return;
        }
        
        BOOL good = YES;
        while (good) {
            good = NO;
            @autoreleasepool {
                __strong HHVideoDecoder *decoder = weakDecoder;
                if (decoder && (decoder.validVideo || decoder.validAudio)) {
                    NSArray *frames = [decoder decodeFrames:duration];
                    if (frames.count) {
                        __strong HHPlayerManager *strongSelf = weakManager;
                        if (strongSelf) {
                            good = [strongSelf addFrames:frames];
                        }
                    }
                }
            }
        }
        {
            __strong HHPlayerManager *strongSelf = weakManager;
            if (strongSelf) {
                strongSelf.decoding = NO;
            }
        }
    });
}

- (BOOL)addFrames:(NSArray *)frames{
    if (DEBUG_NSLOG_TAG) {
        NSLog(@"Method: %s", __FUNCTION__);
    }
    if (_decoder.validVideo) {
        @synchronized (_videoFrames) {
            for (HHBaseFrame *frame in frames) {
                if (frame.type == HhMovieFrameTypeVideo) {
                    [_videoFrames addObject:frame];
                    _bufferedDuration += frame.duration;
                }
            }
        }
    }
    
    if (_decoder.validAudio) {
        @synchronized (_audioFrames) {
            for (HHBaseFrame *frame in frames) {
                if (frame.type == HhMovieFrameTypeAudio) {
                    [_audioFrames addObject:frame];
                    _bufferedDuration += frame.duration;
                }
            }
        }
    }
//    NSLog(@"playing = %d,  _bufferedDuration = %f , _maxBufferedDuration = %f",self.playing,_bufferedDuration, _maxBufferedDuration);
    return self.playing && _bufferedDuration < _maxBufferedDuration; // _maxBufferedDuration 这个不理解
}
 
#pragma mark -  loop Method 自调用循环  核心哦～～～
- (void)tick {
    if (DEBUG_NSLOG_TAG) {
        NSLog(@"Method: %s", __FUNCTION__);
    }
    //1. 是否需要更新缓冲状态
    if (_buffered && ((_bufferedDuration > _minBufferedDuration) || _decoder.isEOF)) {
        _tickCorrectionTime = 0;
        _buffered = NO;
    }
    
    //2. 未缓冲完毕，则显示下一帧视频画面，并获取显示该画面的时间间隔
    CGFloat interval = 0;
    if (!_buffered) {
        interval = [self presentFrame];
    }else {
        NSLog(@"tick_bufferedDuration == %f", _bufferedDuration);
    }
     
    if (self.playing) { //3. 检查待解码数，
        const NSUInteger leftFrames = (_decoder.validVideo ? _videoFrames.count:0) + (_decoder.validAudio ? _audioFrames.count : 0);
        NSLog(@"leftFrames == %lu", (unsigned long)leftFrames);
        if (0 == leftFrames) {
            if (_decoder.isEOF) {
                [self pause];
                return;
            }
            
            if (_minBufferedDuration > 0 && !_buffered) {
                _buffered = YES;
            }
        }
        if (!leftFrames || !(_bufferedDuration > _minBufferedDuration)) { // 没有未解码Frame了 + 已缓冲时长
            [self asyncDecoderFrames];
        }
        
        const NSTimeInterval correction = [self tickCorrection];
        const NSTimeInterval time = MAX(interval + correction, 0.01);
//        NSLog(@"time ======   %f", time);
        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, time * NSEC_PER_SEC);
        dispatch_after(popTime, dispatch_get_main_queue(), ^{
            [self tick];
        });
    }
}
 
#pragma mark - 从 _videoFrames 中获取 VideoFrame
- (CGFloat)presentFrame {
    if (DEBUG_NSLOG_TAG) {
        NSLog(@"Method: %s", __FUNCTION__);
    }
    CGFloat interval = 0;
    if (_decoder.validVideo) {
        NSLog(@"presentFrame 读取视频帧");
        HHVideoFrame *frame;
        @synchronized (_videoFrames) {
            if (_videoFrames.count > 0) {
                frame = _videoFrames[0];
                [_videoFrames removeObjectAtIndex:0];
                _bufferedDuration -= frame.duration;
            }
        }
        if (frame) {
            interval = [self presentVideoFrame:frame];
        }
    } else if (_decoder.validAudio) {
        // 这里干啥的，不懂
        NSLog(@"presentFrame 读取音频帧");
    }
    return interval;
}
 
- (CGFloat)presentVideoFrame:(HHVideoFrame *) frame {
    if (DEBUG_NSLOG_TAG) {
        NSLog(@"Method: %s", __FUNCTION__);
    }
    if (_glView) {
        [_glView render:frame];
    }
    _videoPosition = frame.position;
    return frame.duration;
}

- (CGFloat)tickCorrection {
    if (DEBUG_NSLOG_TAG) {
        NSLog(@"Method: %s", __FUNCTION__);
    }
    if (_buffered) {
        return 0;
    }
    const NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    
    if (!_tickCorrectionTime) {
        _tickCorrectionTime = now;
        _tickCorrectionPosition = _videoPosition;
        return 0;
    }
    
    NSTimeInterval dPosition = _videoPosition - _tickCorrectionPosition;
    NSTimeInterval dTime = now - _tickCorrectionTime;
    NSTimeInterval correction = dPosition - dTime;
    if (correction > 1.f || correction < -1.f) {
        correction = 0;
        _tickCorrectionTime = 0;
    }
//    NSLog(@"correction == %f", correction);
//    NSLog(@"_moviePosition = %f, dPosition = %f，dTime = %f,correction = %f, _tickCorrectionTime = %f",_videoPosition,dPosition,dTime,correction,_tickCorrectionTime);
    return correction;
}

#pragma mark - freeBufferedFrames
- (void)freeBufferedFrames {
    if (DEBUG_NSLOG_TAG) {
        NSLog(@"Method: %s", __FUNCTION__);
    }
    @synchronized (_videoFrames) {
        [_videoFrames removeAllObjects];
    }
    @synchronized (_audioFrames) {
        [_audioFrames removeAllObjects];
    }
    _bufferedDuration = 0;
}

#pragma mark - get Method
- (BOOL)interruptDecoder {
    return _interrupted;
}
@end
