//
//  HHVideoModel.h
//  HHVideoPlayer-OC
//
//  Created by 尹东博 on 2023/4/19.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

typedef enum {
    HhMovieFrameTypeNone = 0,
    HhMovieFrameTypeAudio = 1,
    HhMovieFrameTypeVideo = 2,
} HhBaseFrameType;

typedef enum {
    HhVideoFrameFormatRGB,
    HhVideoFrameFormatYUV,
} HhVideoFrameFormat;


NS_ASSUME_NONNULL_BEGIN

@interface HHVideoModel : NSObject

@end
 
@interface HHBaseFrame : NSObject
@property (nonatomic, assign) HhBaseFrameType type;
@property (nonatomic, assign) CGFloat position;
@property (nonatomic, assign) CGFloat duration;
@end


#pragma mark - 音频帧
@interface HHAudioFrame : HHBaseFrame
@property (nonatomic, strong) NSData *samples;
@end

#pragma mark - 视频帧
@interface HHVideoFrame : HHBaseFrame
@property (nonatomic, assign) HhVideoFrameFormat format;
@property (nonatomic, assign) NSInteger width;
@property (nonatomic, assign) NSInteger height;
@end


#pragma mark - 视频帧绘制类型
@interface HHVideoFrameYUV: HHVideoFrame
@property (nonatomic, strong) NSData *luma;
@property (nonatomic, strong) NSData *chromaB;
@property (nonatomic, strong) NSData *chromaR;
@end

@interface HHVideoFrameRGB : HHVideoFrame
@property (nonatomic, assign) NSInteger linesize;
@property (nonatomic, strong) NSData *rgb;
@end
NS_ASSUME_NONNULL_END
