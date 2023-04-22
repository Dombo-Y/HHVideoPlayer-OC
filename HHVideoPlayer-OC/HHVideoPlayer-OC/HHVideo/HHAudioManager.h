//
//  HHAudioManager.h
//  HHVideoPlayer-OC
//
//  Created by 尹东博 on 2023/4/19.
//

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>


NS_ASSUME_NONNULL_BEGIN

typedef void (^HhAudioManagerOutputBlock)(float *data, UInt32 numFrames, UInt32 numChannels);

@protocol HHAudioManager <NSObject>

@property (readonly) UInt32             numOutputChannels;
@property (readonly) Float64            samplingRate;
@property (readonly) UInt32             numBytesPerSample;
@property (readonly) Float32            outputVolume;
@property (readonly) BOOL               playing;
@property (readonly, strong) NSString   *audioRoute;

@property (readwrite, copy) HhAudioManagerOutputBlock outputBlock;

- (BOOL) activateAudioSession;
- (void) deactivateAudioSession;
- (BOOL) play;
- (void) pause;

- (void)playMethod;
@end

@interface HHAudioManager : NSObject

+ (id<HHAudioManager>) audioManager;
@end

NS_ASSUME_NONNULL_END
