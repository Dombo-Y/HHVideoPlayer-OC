//
//  HHVideoDecoder.h
//  HHVideoPlayer-OC
//
//  Created by 尹东博 on 2023/4/19.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <UIKit/UIKit.h>


typedef enum : NSUInteger {
    HHVideoFrameFormatRGB,
    HHVideoFrameFormatYUV,
} HHVideoFrameFormat;


typedef BOOL(^HhVideoDecoderInterruptCallback)();



NS_ASSUME_NONNULL_BEGIN

@interface HHVideoDecoder : NSObject

@property (nonatomic, strong,readonly) NSString *path;
@property (nonatomic, readonly) BOOL isEOF;
@property (nonatomic, readonly) BOOL  isNetwork; 
@property (nonatomic, readonly) CGFloat fps;
@property (nonatomic, strong) HhVideoDecoderInterruptCallback interruptCallback;
@property (readonly, nonatomic) BOOL validVideo;
@property (readonly, nonatomic) BOOL validAudio;

@property (readonly, nonatomic) NSUInteger frameWidth;
@property (readonly, nonatomic) NSUInteger frameHeight;

@property (readwrite,nonatomic) CGFloat position;
@property (readonly, nonatomic) CGFloat duration;

+ (id)videoDecoderWithContentPath:(NSString *)path;

- (BOOL)openFile:(NSString *)path;
- (void)closeFile;
- (BOOL)setupVideoFrameFormat:(HHVideoFrameFormat)format;
- (NSArray *)decodeFrames:(CGFloat)minDUration;
@end

NS_ASSUME_NONNULL_END
