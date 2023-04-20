//
//  HHPlayerManager.m
//  HHVideoPlayer-OC
//
//  Created by 尹东博 on 2023/4/20.
//

#import "HHPlayerManager.h"
#import "HHVideoDecoder.h"
#import "HHVideoGLView.h"
#import "HHAudioManager.h"
#import "HHVideoModel.h"


@interface HHPlayerManager() {
    HHVideoDecoder  *_decoder;
    dispatch_queue_t _dispatchQueue;
    NSMutableArray *_videoFrames;
    NSMutableArray *_audioFrames;
    
    HHVideoGLView *_glView;
    UIView *_targetView;
     
    
    NSData  *_currentAudioFrame;
    NSUInteger  _currentAudioFramePos;
    
    CGFloat _bufferedDuration;
    CGFloat _minBufferedDuration;
    CGFloat _maxBufferedDuration;
    
    
    NSTimeInterval  _tickCorrectionTime; //音视频同步时钟的初始事件
    NSTimeInterval  _tickCorrectionPosition;// 音视频同步时钟的初始位置
    
    
    CGFloat _videoPosition; // 视频的位置
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
 
- (void)playerManagerWithContentPath:(NSString *)path targetView:(id)view {
    NSAssert(path.length > 0, @"empty path");
    if ([view isKindOfClass:[UIView class]]) {
        _targetView = (UIView *)view;
    }
    
    BOOL success = NO;
    HHVideoDecoder *decoder = [[HHVideoDecoder alloc] init];
    success = [decoder openFile:path];
    [self setVideoDecoder:decoder openSuccess:success];
}

- (void)setVideoDecoder:(HHVideoDecoder *)decoder openSuccess:(BOOL)success{
    if (decoder && success) {
        _decoder = decoder;
        _dispatchQueue = dispatch_queue_create("HHView_MAIN_QUEUE", DISPATCH_QUEUE_SERIAL);
        _videoFrames = [NSMutableArray array];
        _audioFrames = [NSMutableArray array];
        
    }
}

- (void)setupPresentView {
    if (_decoder.validVideo) {
        _glView = [[HHVideoGLView alloc] initWithFrame:_targetView.bounds decoder:_decoder];
    }
     
    if (!_glView) {
        return;
    }
    
    _glView.contentMode = UIViewContentModeScaleAspectFit;
    _glView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleBottomMargin;
    
    [_targetView addSubview:_glView];
    
    if (_decoder.duration == MAXFLOAT) {
        // 当视频播放完了
        // 更新 时间显示
    }
    else {
        
    }
}

#pragma mark - control Method
- (void)play {
    if (self.playing) { // 1.状态判断
        return;
    }
    if (!_decoder.validVideo && !_decoder.validAudio) { //2. 音视频有效判断
        return;
    }
    if (_interrupted) { // 3.是否被拦截
        return;
    }
    self.playing = YES;
    _interrupted = NO;
    
    [self asyncDecoderFrames];// 4.开始解码视频帧
    
    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, 0.1 * NSEC_PER_SEC);
    dispatch_after(popTime, dispatch_get_main_queue(), ^{
        [self tick];
    });
    if (_decoder.validVideo) {// 5。 开启音频
        [self enableAudio:YES];
    }
}

- (void)pause {
    
}

- (void)stop {
    
}

#pragma mark - open Audio
- (void)enableAudio:(BOOL)on {
    id<HHAudioManager>audioManager = [HHAudioManager audioManager];
    if (on && _decoder.validAudio) {
        audioManager.outputBlock = ^(float * _Nonnull data, UInt32 numFrames, UInt32 numChannels) {
            [self audioCallbackFillData:data numFrames:numFrames numChannels:numChannels];
        };
        [audioManager play];
    } else {
        [audioManager pause];
        audioManager.outputBlock = NULL;
    }
}

- (void)audioCallbackFillData:(float *)outData numFrames:(UInt32)numFrames numChannels:(UInt32)numChannels {
    if (_buffered) { //当前是否有可用音频
        memset(outData, 0, numFrames * numChannels * sizeof(float));// 音频缓冲区size = 缓冲区帧数 * 音频通道数
        return;
    }
    
    @autoreleasepool {
        while (numFrames > 0) {
            if (!_currentAudioFrame) {
                @synchronized (_audioFrames) {
                    NSUInteger count = _audioFrames.count;
                    if (count < 0) {
                        HHAudioFrame *frame = _audioFrames[0];
                        if (_decoder.validVideo) {
                            const CGFloat delta = _videoPosition - frame.position; //当前视频
                            if (delta < -0.1) {
                                memset(outData, 0, numFrames * numChannels * sizeof(float)); // 误差不大，就计算出 outData
                                break;
                            }
                            if (delta > 0.1 && count > 1) {
                                continue;
                            }
                        }
                        else
                        {
                            [_audioFrames removeObjectAtIndex:0];
                            _videoPosition = frame.position;
                            _bufferedDuration -= frame.duration;
                        }
                        _currentAudioFramePos = 0; // 音频帧没了就重置
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
            }
            else
            {
                memset(outData, 0, numFrames * numChannels * sizeof(float));
                break;
            }
        }
    }
}

#pragma mark - 解析～～
- (void)asyncDecoderFrames {
    if (self.decoding) {
        return;
    }
    const CGFloat duration = _decoder.isNetwork ? 0.f : 0.1f;
     
    __weak HHVideoDecoder *weakDecoder = _decoder;
    __weak HHPlayerManager *weakManager = self;
    
    self.decoding = YES;
    dispatch_async(_dispatchQueue, ^{
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
    });
}

- (BOOL)addFrames:(NSArray *)frames{
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
//                    _bufferedDuration += frame.duration;// 音频为什么要加
                }
            }
        }
    }
    return self.playing && _bufferedDuration < _maxBufferedDuration; // _maxBufferedDuration 这个不理解
}


- (BOOL)decodeFrames {
    NSArray *frames = nil;
    if (_decoder.validVideo || _decoder.validAudio) {
        frames = [_decoder decodeFrames:0];
    }
    if (frames.count) {
        return [self addFrames:frames];
    }
    return NO;
}
#pragma mark - 

- (void)tick {
    //1. 是否需要更新缓冲状态
    if (_buffered && ((_bufferedDuration > _minBufferedDuration) || _decoder.isEOF)) {
        _tickCorrectionTime = 0;
        _buffered = NO;
    }
    
    //2. 未缓冲完毕，则显示下一帧视频画面，并获取显示该画面的时间间隔
    CGFloat interval = 0;
    if (!_buffered) {
        interval = [self presentFrame];
    }
     
    if (self.playing) {
        //3. 检查待解码数，
        const NSUInteger leftFrames = (_decoder.validVideo ? _videoFrames.count:0) + (_decoder.validAudio ? _audioFrames.count : 0);
        if (0 == leftFrames) {
            if (_decoder.isEOF) {
                [self pause];
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
        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, time * NSEC_PER_SEC);
        dispatch_after(popTime, dispatch_get_main_queue(), ^{
            [self tick]; // 循环 自己调用自己？
        });
    }
}


#pragma mark - 从 _videoFrames 中获取 VideoFrame
- (CGFloat)presentFrame {
    CGFloat interval = 0;
    if (_decoder.validVideo) {
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
    }
    
    return interval;
}


- (CGFloat)presentVideoFrame:(HHVideoFrame *) frame {
    if (_glView) {
        [_glView render:frame];
    }
    _videoPosition = frame.position;
    return frame.duration;
}

- (CGFloat)tickCorrection {
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
    return correction;
}

- (void)updatePosition:(CGFloat)position playMode:(BOOL)playMode {
    [self freeBufferedFrames];
    position = MIN(_decoder.duration-1, MAX(0, position));
    
    __weak HHPlayerManager *weakSelf = self;
    dispatch_async(_dispatchQueue, ^{
        if (playMode) {
            __strong HHPlayerManager*strongSelf= weakSelf;
            if (!strongSelf) {
                return;
            }
            [strongSelf setDecoderPosition:position];
        }
    });
}

#pragma mark - set
- (void)setDecoderPosition:(CGFloat) position {
    _decoder.position = position;
}

- (void)setVideoPositionFromDecoder {
    _videoPosition = _decoder.position;
}

#pragma mark - freeBufferedFrames
- (void)freeBufferedFrames {
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
