//
//  HHAudioManagerProtocol.h
//  HHVideoPlayer-OC
//
//  Created by 尹东博 on 2023/4/19.
//

#import <Foundation/Foundation.h>

typedef void (^HhAudioManagerOutputBlock)(float *data, UInt32 numFrames, UInt32 numChannels);

@protocol HHAudioManagerProtocol <NSObject>

@property (nonatomic, readonly) UInt32 numOutpuChannels;
@property (nonatomic, readonly) Float64 samplingRate;
@property (nonatomic, readonly) UInt32 numBytesPerSample;
@property (nonatomic, readonly) Float32 outputVolume;
@property (nonatomic, readonly) BOOL playing;
@property (nonatomic, readonly, strong) NSString * audioRoute;

@property (readwrite, copy) HhAudioManagerOutputBlock outputBlock;

- (BOOL)activateAudioSession;
- (void)deactivateAudioSession;
- (BOOL)play;
- (void)pause;

@end
