//
//  HHAudioManager.m
//  HHVideoPlayer-OC
//
//  Created by 尹东博 on 2023/4/19.
//

#import "HHAudioManager.h"
#import "TargetConditionals.h"
#import <AudioToolbox/AudioToolbox.h>
#import <Accelerate/Accelerate.h>


#define MAX_FRAME_SIZE 4096
#define MAX_CHAN       2

#define MAX_SAMPLE_DUMPED 5

static BOOL checkError(OSStatus error, const char *operation);
static void sessionPropertyListener(void *inClientData, AudioSessionPropertyID inID, UInt32 inDataSize, const void *inData);
static void sessionInterruptionListener(void *inClientData, UInt32 inInterruption);
static OSStatus renderCallback (void *inRefCon, AudioUnitRenderActionFlags    *ioActionFlags, const AudioTimeStamp * inTimeStamp, UInt32 inOutputBusNumber, UInt32 inNumberFrames, AudioBufferList* ioData);

@interface HhAudioManagerImpl : HHAudioManager<HHAudioManager> {
    BOOL                        _initialized;
    BOOL                        _activated;
    float                       *_outData;
    AudioUnit                   _audioUnit;
    AudioStreamBasicDescription _outputFormat;
}

@property (readonly) UInt32             numOutputChannels;
@property (readonly) Float64            samplingRate;
@property (readonly) UInt32             numBytesPerSample;
@property (readwrite) Float32           outputVolume;
@property (readonly) BOOL               playing;
@property (readonly, strong) NSString   *audioRoute;

@property (readwrite, copy) HhAudioManagerOutputBlock outputBlock;
@property (readwrite) BOOL playAfterSessionEndInterruption;

- (BOOL) activateAudioSession;
- (void) deactivateAudioSession;
- (BOOL) play;
- (void) pause;

- (BOOL) checkAudioRoute;
- (BOOL) setupAudio;
- (BOOL) checkSessionProperties;
- (BOOL) renderFrames: (UInt32) numFrames
               ioData: (AudioBufferList *) ioData;
@end
 
@implementation HHAudioManager

+ (id<HHAudioManager>) audioManager
{
    static HhAudioManagerImpl *audioManager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        audioManager = [[HhAudioManagerImpl alloc] init];
    });
    return audioManager;
}
 
@end

@implementation HhAudioManagerImpl

- (id)init {
    self = [super init];
    if (self) {
        _outData = (float *)calloc(MAX_FRAME_SIZE*MAX_CHAN, sizeof(float));
        _outputVolume = 0.5;
    }
    return self;
}

- (void)dealloc {
    if (_outData) {
        free(_outData);
        _outData = NULL;
    }
}

- (BOOL) checkAudioRoute {
    UInt32 propertySize = sizeof(CFStringRef);
    CFStringRef route;
    if (checkError(AudioSessionGetProperty(kAudioSessionProperty_AudioRoute,
                                           &propertySize,
                                           &route),
                   "Couldn't check the audio route"))
        return NO;

    _audioRoute = CFBridgingRelease(route);
    return YES;
}

- (BOOL) setupAudio {

    UInt32 sessionCategory = kAudioSessionCategory_MediaPlayback;
    if (checkError(AudioSessionSetProperty(kAudioSessionProperty_AudioCategory,
                                           sizeof(sessionCategory),
                                           &sessionCategory),
                   "Couldn't set audio category"))
        return NO;

    if (checkError(AudioSessionAddPropertyListener(kAudioSessionProperty_AudioRouteChange,
                                                   sessionPropertyListener,
                                                   (__bridge void *)(self)),
                   "Couldn't add audio session property listener")) {
    }

    if (checkError(AudioSessionAddPropertyListener(kAudioSessionProperty_CurrentHardwareOutputVolume,
                                                   sessionPropertyListener,
                                                   (__bridge void *)(self)),
                   "Couldn't add audio session property listener"))  { }

#if !TARGET_IPHONE_SIMULATOR
    Float32 preferredBufferSize = 0.0232;
    if (checkError(AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareIOBufferDuration,
                                            sizeof(preferredBufferSize),
                                            &preferredBufferSize),
                    "Couldn't set the preferred buffer duration")) { }
#endif

    if (checkError(AudioSessionSetActive(YES),
                   "Couldn't activate the audio session"))
        return NO;

    [self checkSessionProperties];

    AudioComponentDescription description = {0};
    description.componentType = kAudioUnitType_Output;
    description.componentSubType = kAudioUnitSubType_RemoteIO;
    description.componentManufacturer = kAudioUnitManufacturer_Apple;

    // Get component
    AudioComponent component = AudioComponentFindNext(NULL, &description);
    if (checkError(AudioComponentInstanceNew(component, &_audioUnit),
                   "Couldn't create the output audio unit"))
        return NO;

    UInt32 size;

    size = sizeof(AudioStreamBasicDescription);
    if (checkError(AudioUnitGetProperty(_audioUnit,
                                        kAudioUnitProperty_StreamFormat,
                                        kAudioUnitScope_Input,
                                        0,
                                        &_outputFormat,
                                        &size),
                   "Couldn't get the hardware output stream format"))
        return NO;


    _outputFormat.mSampleRate = _samplingRate;
    if (checkError(AudioUnitSetProperty(_audioUnit,
                                        kAudioUnitProperty_StreamFormat,
                                        kAudioUnitScope_Input,
                                        0,
                                        &_outputFormat,
                                        size),
                   "Couldn't set the hardware output stream format")) {

        // just warning
    }

    _numBytesPerSample = _outputFormat.mBitsPerChannel / 8;
    _numOutputChannels = _outputFormat.mChannelsPerFrame;

    // Slap a render callback on the unit
    AURenderCallbackStruct callbackStruct;
    callbackStruct.inputProc = renderCallback;
    callbackStruct.inputProcRefCon = (__bridge void *)(self);

    if (checkError(AudioUnitSetProperty(_audioUnit,
                                        kAudioUnitProperty_SetRenderCallback,
                                        kAudioUnitScope_Input,
                                        0,
                                        &callbackStruct,
                                        sizeof(callbackStruct)),
                   "Couldn't set the render callback on the audio unit"))
        return NO;

    if (checkError(AudioUnitInitialize(_audioUnit),
                   "Couldn't initialize the audio unit"))
        return NO;

    return YES;
}

- (BOOL) checkSessionProperties {
    [self checkAudioRoute];

    UInt32 newNumChannels;
    UInt32 size = sizeof(newNumChannels);
    if (checkError(AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareOutputNumberChannels,
                                           &size,
                                           &newNumChannels),
                   "Checking number of output channels"))
        return NO;

    size = sizeof(_samplingRate);
    if (checkError(AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareSampleRate,
                                           &size,
                                           &_samplingRate),
                   "Checking hardware sampling rate"))

        return NO;

    size = sizeof(_outputVolume);
    if (checkError(AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareOutputVolume,
                                           &size,
                                           &_outputVolume),
                   "Checking current hardware output volume"))
        return NO;

    return YES;
}

- (BOOL) renderFrames: (UInt32) numFrames
               ioData: (AudioBufferList *) ioData
{
    for (int iBuffer=0; iBuffer < ioData->mNumberBuffers; ++iBuffer) {
        memset(ioData->mBuffers[iBuffer].mData, 0, ioData->mBuffers[iBuffer].mDataByteSize);
    }
    
    if (_playing && _outputBlock ) {
    
        // Collect data to render from the callbacks
        _outputBlock(_outData, numFrames, _numOutputChannels);
        
        // Put the rendered data into the output buffer
        if (_numBytesPerSample == 4) // then we've already got floats
        {
            float zero = 0.0;
            
            for (int iBuffer=0; iBuffer < ioData->mNumberBuffers; ++iBuffer) {
                
                int thisNumChannels = ioData->mBuffers[iBuffer].mNumberChannels;
                
                for (int iChannel = 0; iChannel < thisNumChannels; ++iChannel) {
                    vDSP_vsadd(_outData+iChannel, _numOutputChannels, &zero, (float *)ioData->mBuffers[iBuffer].mData, thisNumChannels, numFrames);
                }
            }
        }
        else if (_numBytesPerSample == 2) // then we need to convert SInt16 -> Float (and also scale)
        {
//            dumpAudioSamples(@"Audio frames decoded by FFmpeg:\n",
//                             _outData, @"% 12.4f ", numFrames, _numOutputChannels);

            float scale = (float)INT16_MAX;
            vDSP_vsmul(_outData, 1, &scale, _outData, 1, numFrames*_numOutputChannels);
            
#ifdef DUMP_AUDIO_DATA
//            LoggerAudio(2, @"Buffer %u - Output Channels %u - Samples %u",
//                          (uint)ioData->mNumberBuffers, (uint)ioData->mBuffers[0].mNumberChannels, (uint)numFrames);
#endif

            for (int iBuffer=0; iBuffer < ioData->mNumberBuffers; ++iBuffer) {
                
                int thisNumChannels = ioData->mBuffers[iBuffer].mNumberChannels;
                
                for (int iChannel = 0; iChannel < thisNumChannels; ++iChannel) {
                    vDSP_vfix16(_outData+iChannel, _numOutputChannels, (SInt16 *)ioData->mBuffers[iBuffer].mData+iChannel, thisNumChannels, numFrames);
                }
#ifdef DUMP_AUDIO_DATA
                dumpAudioSamples(@"Audio frames decoded by FFmpeg and reformatted:\n",
                                 ((SInt16 *)ioData->mBuffers[iBuffer].mData),
                                 @"% 8d ", numFrames, thisNumChannels);
#endif
            }
            
        }
    }

    return noErr;
}

#pragma mark - public

- (BOOL) activateAudioSession
{
    if (!_activated) {
        
        if (!_initialized) {
            
            if (checkError(AudioSessionInitialize(NULL,
                                                  kCFRunLoopDefaultMode,
                                                  sessionInterruptionListener,
                                                  (__bridge void *)(self)),
                           "Couldn't initialize audio session"))
                return NO;
            
            _initialized = YES;
        }
        
        if ([self checkAudioRoute] &&
            [self setupAudio]) {
            
            _activated = YES;
        }
    }
    
    return _activated;
}

- (void) deactivateAudioSession
{
    if (_activated) {
     
        [self pause];
                
        checkError(AudioUnitUninitialize(_audioUnit),
                   "Couldn't uninitialize the audio unit");
        
        /*
        fails with error (-10851) ?
         
        checkError(AudioUnitSetProperty(_audioUnit,
                                        kAudioUnitProperty_SetRenderCallback,
                                        kAudioUnitScope_Input,
                                        0,
                                        NULL,
                                        0),
                   "Couldn't clear the render callback on the audio unit");
        */
                
        checkError(AudioComponentInstanceDispose(_audioUnit),
                   "Couldn't dispose the output audio unit");
                
        checkError(AudioSessionSetActive(NO),
                   "Couldn't deactivate the audio session");
        
        checkError(AudioSessionRemovePropertyListenerWithUserData(kAudioSessionProperty_AudioRouteChange,
                                                                  sessionPropertyListener,
                                                                  (__bridge void *)(self)),
                   "Couldn't remove audio session property listener");
        
        checkError(AudioSessionRemovePropertyListenerWithUserData(kAudioSessionProperty_CurrentHardwareOutputVolume,
                                                                  sessionPropertyListener,
                                                                  (__bridge void *)(self)),
                   "Couldn't remove audio session property listener");
        
        _activated = NO;
    }
}

- (void) pause
{
    if (_playing) {
        
        _playing = checkError(AudioOutputUnitStop(_audioUnit),
                             "Couldn't stop the output unit");
    }
}

- (BOOL) play
{
    if (!_playing) {
        
        if ([self activateAudioSession]) {
            
            _playing = !checkError(AudioOutputUnitStart(_audioUnit),
                                   "Couldn't start the output unit");
        }
    }
    
    return _playing;
}

@end

#pragma mark - callbacks
static void sessionPropertyListener(void *                  inClientData,
                                    AudioSessionPropertyID  inID,
                                    UInt32                  inDataSize,
                                    const void *            inData)
{
    HhAudioManagerImpl *sm = (__bridge HhAudioManagerImpl *)inClientData;
    
    if (inID == kAudioSessionProperty_AudioRouteChange) {
        
        if ([sm checkAudioRoute]) {
            [sm checkSessionProperties];
        }
        
    } else if (inID == kAudioSessionProperty_CurrentHardwareOutputVolume) {
        
        if (inData && inDataSize == 4) {

            sm.outputVolume = *(float *)inData;
        }
    }
}

static void sessionInterruptionListener(void *inClientData, UInt32 inInterruption) {
    HhAudioManagerImpl *sm = (__bridge HhAudioManagerImpl *)inClientData;
    
    if (inInterruption == kAudioSessionBeginInterruption) {
        
//        LoggerAudio(2, @"Begin interuption");
        sm.playAfterSessionEndInterruption = sm.playing;
        [sm pause];
                
    } else if (inInterruption == kAudioSessionEndInterruption) {
        
//        LoggerAudio(2, @"End interuption");
        if (sm.playAfterSessionEndInterruption) {
            sm.playAfterSessionEndInterruption = NO;
            [sm play];
        }
    }
}

static OSStatus renderCallback (void                        *inRefCon,
                                AudioUnitRenderActionFlags    * ioActionFlags,
                                const AudioTimeStamp         * inTimeStamp,
                                UInt32                        inOutputBusNumber,
                                UInt32                        inNumberFrames,
                                AudioBufferList                * ioData)
{
    HhAudioManagerImpl *sm = (__bridge HhAudioManagerImpl *)inRefCon;
    return [sm renderFrames:inNumberFrames ioData:ioData];
}


static BOOL checkError(OSStatus error, const char *operation) {
    if (error == noErr)
        return NO;
    
    char str[20] = {0};
    *(UInt32 *)(str + 1) = CFSwapInt32HostToBig(error);
    if (isprint(str[1]) && isprint(str[2]) && isprint(str[3]) && isprint(str[4])) {
        str[0] = str[5] = '\'';
        str[6] = '\0';
    } else
        sprintf(str, "%d", (int)error);
    
    return YES;
}
