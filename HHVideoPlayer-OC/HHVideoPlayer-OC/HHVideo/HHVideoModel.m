//
//  HHVideoModel.m
//  HHVideoPlayer-OC
//
//  Created by 尹东博 on 2023/4/19.
//

#import "HHVideoModel.h"

@implementation HHVideoModel
@end


@implementation HHBaseFrame
@end


@implementation HHAudioFrame
- (HhBaseFrameType)type {
    return HhMovieFrameTypeAudio;
}
@end
@implementation HHVideoFrame

- (HhBaseFrameType)type {
    return HhMovieFrameTypeVideo;
}
@end


@implementation HHVideoFrameYUV
@end
@implementation HHVideoFrameRGB
@end
